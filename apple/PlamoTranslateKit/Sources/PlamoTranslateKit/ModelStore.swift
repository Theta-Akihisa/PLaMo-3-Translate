#if canImport(llama)
import Foundation
import CryptoKit
import PlamoTranslateCore

public enum ModelStoreError: LocalizedError {
    case insufficientDiskSpace(required: Int64, available: Int64)
    case checksumMismatch(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case httpStatus(Int)
    case invalidGGUF
    case alreadyDownloading

    public var errorDescription: String? {
        let f = ByteCountFormatter()
        switch self {
        case .insufficientDiskSpace(let r, let a):
            return "空き容量が不足しています（必要 \(f.string(fromByteCount: r))、空き \(f.string(fromByteCount: a))）。"
        case .checksumMismatch(let n): return "\(n) のチェックサムが一致しません。ダウンロードをやり直してください。"
        case .sizeMismatch(let e, let a):
            return "ダウンロードしたファイルのサイズが想定と異なります（想定 \(e) バイト、実際 \(a) バイト）。配布元のファイルが更新された可能性があります。アプリを最新版にしてください。"
        case .httpStatus(let c): return "ダウンロードに失敗しました（HTTP \(c)）。"
        case .invalidGGUF: return "GGUF ファイルではありません。"
        case .alreadyDownloading: return "すでにダウンロード中です。"
        }
    }
}

public enum DownloadStatus: Equatable, Sendable {
    case downloading(progress: Double)   // 0...1
    case verifying
    case failed(String)
}

/// モデル（GGUF）のダウンロード・検証・保管。
@MainActor
public final class ModelStore: ObservableObject {
    /// ファイル名ごとのダウンロード状況（完了すると消える）
    @Published public private(set) var downloads: [String: DownloadStatus] = [:]
    /// 保存済み .gguf ファイル名
    @Published public private(set) var installedFiles: Set<String> = []

    private var jobs: [String: DownloadJob] = [:]
    private let fm = FileManager.default

    /// Application Support/PlamoTranslate/Models
    public nonisolated static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PlamoTranslate", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private var resumeDirectory: URL { Self.modelsDirectory.appendingPathComponent(".partial", isDirectory: true) }

    public init() {
        prepareDirectory()
        refresh()
    }

    private func prepareDirectory() {
        var dir = Self.modelsDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? dir.setResourceValues(v)
    }

    public func refresh() {
        let names = (try? fm.contentsOfDirectory(atPath: Self.modelsDirectory.path)) ?? []
        installedFiles = Set(names.filter { $0.hasSuffix(".gguf") })
    }

    public func localURL(for file: ModelFile) -> URL {
        Self.modelsDirectory.appendingPathComponent(file.file)
    }

    public func isInstalled(_ file: ModelFile) -> Bool {
        let path = localURL(for: file).path
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        return size == file.sizeBytes
    }

    public func isDownloading(_ file: ModelFile) -> Bool { jobs[file.file] != nil }

    // MARK: - Download

    private func availableCapacity() -> Int64? {
        let v = try? Self.modelsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    /// ダウンロード → SHA-256 検証 → 原子的に配置。失敗時は throw（`downloads` にも反映）。
    public func download(_ file: ModelFile) async throws {
        guard jobs[file.file] == nil else { throw ModelStoreError.alreadyDownloading }
        if isInstalled(file) { return }

        let resumeURL = resumeDirectory.appendingPathComponent(file.file + ".resume")
        let resumeData = try? Data(contentsOf: resumeURL)
        // 再開データがあれば部分ダウンロード分は差し引かない（安全側で全量を要求）
        let required = file.sizeBytes + 256 * 1024 * 1024
        if let avail = availableCapacity(), avail < required {
            let e = ModelStoreError.insufficientDiskSpace(required: required, available: avail)
            downloads[file.file] = .failed(e.localizedDescription)
            throw e
        }

        let name = file.file
        let job = DownloadJob(url: file.url, resumeData: resumeData) { [weak self] p in
            Task { @MainActor in
                guard let self, self.jobs[name] != nil else { return }
                self.downloads[name] = .downloading(progress: p)
            }
        }
        jobs[name] = job
        downloads[name] = .downloading(progress: 0)
        let dest = localURL(for: file)
        let dir = Self.modelsDirectory

        do {
            let tmp = try await job.start(stagingDirectory: dir)
            try? fm.removeItem(at: resumeURL)
            downloads[name] = .verifying
            let expectedSize = file.sizeBytes, expectedHash = file.sha256
            try await Task.detached(priority: .utility) {
                let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
                let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                guard actualSize == expectedSize else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw ModelStoreError.sizeMismatch(expected: expectedSize, actual: actualSize)
                }
                let hash = try Self.sha256Hex(of: tmp)
                guard hash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw ModelStoreError.checksumMismatch(name)
                }
            }.value
            // 原子的に配置（既存があれば置換）
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
            jobs[name] = nil
            downloads[name] = nil
            refresh()
        } catch {
            jobs[name] = nil
            if let data = job.resumeData {
                try? data.write(to: resumeURL)
            } else {
                try? fm.removeItem(at: resumeURL)   // 壊れた再開データを残さない
            }
            if job.wasCancelledByUser {
                downloads[name] = nil
            } else {
                downloads[name] = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    /// ダウンロードを中止する（再開データは保存され、次回 `download` で続きから再開を試みる）。
    public func cancelDownload(_ file: ModelFile) {
        jobs[file.file]?.cancel()
    }

    public func delete(_ file: ModelFile) throws {
        try? fm.removeItem(at: resumeDirectory.appendingPathComponent(file.file + ".resume"))
        if fm.fileExists(atPath: localURL(for: file).path) {
            try fm.removeItem(at: localURL(for: file))
        }
        refresh()
    }

    /// 任意の保存済みファイル名を削除（インポートしたファイル用）。
    public func deleteFile(named name: String) throws {
        let url = Self.modelsDirectory.appendingPathComponent(name)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        refresh()
    }

    // MARK: - Import

    /// 既に持っている GGUF をモデルディレクトリへコピーする（macOS のファイル選択など）。
    /// 先頭が "GGUF" であることのみ確認する。保存先 URL を返す。
    @discardableResult
    public func importLocalFile(url: URL) async throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = Self.modelsDirectory.appendingPathComponent(url.lastPathComponent)
        let dir = Self.modelsDirectory
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let fh = try FileHandle(forReadingFrom: url)
            let magic = try fh.read(upToCount: 4)
            try fh.close()
            guard magic == Data("GGUF".utf8) else { throw ModelStoreError.invalidGGUF }
            let tmp = dir.appendingPathComponent(".import-\(UUID().uuidString)")
            try fm.copyItem(at: url, to: tmp)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        }.value
        refresh()
        return dest
    }

    // MARK: - SHA-256

    /// 4MiB ずつ読み込むストリーミング SHA-256（GB 級ファイルでもメモリを食わない）。
    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = try autoreleasepool { try fh.read(upToCount: 4 * 1024 * 1024) }
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - URLSession download job

private final class DownloadJob: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let initialResumeData: Data?
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var stagingDirectory: URL?
    private var movedFile: URL?
    private var moveError: Error?
    private var _resumeData: Data?
    private var _cancelled = false
    private var lastReport = Date.distantPast

    var resumeData: Data? { lock.lock(); defer { lock.unlock() }; return _resumeData }
    var wasCancelledByUser: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    init(url: URL, resumeData: Data?, onProgress: @escaping @Sendable (Double) -> Void) {
        self.url = url
        self.initialResumeData = resumeData
        self.onProgress = onProgress
    }

    func start(stagingDirectory: URL) async throws -> URL {
        self.stagingDirectory = stagingDirectory
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            lock.lock()
            continuation = c
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 60
            cfg.waitsForConnectivity = true
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session = s
            let t: URLSessionDownloadTask
            if let d = initialResumeData { t = s.downloadTask(withResumeData: d) } else { t = s.downloadTask(with: url) }
            task = t
            lock.unlock()
            t.resume()
        }
    }

    func cancel() {
        lock.lock(); _cancelled = true; let t = task; lock.unlock()
        t?.cancel(byProducingResumeData: { [weak self] data in
            guard let self else { return }
            self.lock.lock(); self._resumeData = data; self.lock.unlock()
        })
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        let s = session
        session = nil
        lock.unlock()
        s?.finishTasksAndInvalidate()
        c?.resume(with: result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastReport) > 0.2
        if due { lastReport = now }
        lock.unlock()
        if due { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // このコールバックを抜けると location が消えるので、ここで同期的に移動する。
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.lock(); moveError = ModelStoreError.httpStatus(http.statusCode); lock.unlock()
            return
        }
        let dir = stagingDirectory ?? FileManager.default.temporaryDirectory
        let staged = dir.appendingPathComponent(".download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            lock.lock(); movedFile = staged; lock.unlock()
        } catch {
            lock.lock(); moveError = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let file = movedFile, mErr = moveError
        if let error, _resumeData == nil,
           let d = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            _resumeData = d
        }
        lock.unlock()
        if let error { finish(.failure(error)); return }
        if let mErr { finish(.failure(mErr)); return }
        if let file { finish(.success(file)) } else { finish(.failure(URLError(.unknown))) }
    }
}
#endif
