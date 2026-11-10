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

    /// 一時ファイル（ダウンロード・インポート途中）の接頭辞。モデルディレクトリ内に作る
    private static let stagingPrefixes = [".download-", ".import-"]

    /// Application Support/PlamoTranslate/Models
    public nonisolated static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PlamoTranslate", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private var resumeDirectory: URL { Self.modelsDirectory.appendingPathComponent(".partial", isDirectory: true) }

    /// 再開データは SHA-256 をキーにする（同名でも中身の違うファイルの続きを取りに行かないように）。
    private func resumeURL(for file: ModelFile) -> URL {
        resumeDirectory.appendingPathComponent(file.sha256.lowercased() + ".resume")
    }

    /// 旧形式（ファイル名キー）の再開データ。読まずに削除する。
    private func legacyResumeURL(for file: ModelFile) -> URL {
        resumeDirectory.appendingPathComponent(file.file + ".resume")
    }

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
        // 前回の異常終了などで残った一時ファイルを掃除する
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where Self.stagingPrefixes.contains(where: { name.hasPrefix($0) }) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
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
    /// `cancelDownload` または呼び出し元タスクのキャンセルで中止できる（`downloads` からは消え、エラーは throw される）。
    public func download(_ file: ModelFile) async throws {
        guard jobs[file.file] == nil else { throw ModelStoreError.alreadyDownloading }
        if isInstalled(file) { return }

        let resumeFile = resumeURL(for: file)
        try? fm.removeItem(at: legacyResumeURL(for: file))
        let resumeData = try? Data(contentsOf: resumeFile)
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
        var staged: URL?   // 配置前の一時ファイル。失敗時に必ず消す

        do {
            let tmp = try await job.start(stagingDirectory: dir)
            staged = tmp
            try? fm.removeItem(at: resumeFile)
            if job.wasCancelled { throw CancellationError() }
            try Task.checkCancellation()

            downloads[name] = .verifying
            let expectedSize = file.sizeBytes, expectedHash = file.sha256
            let verifier = Task.detached(priority: .utility) {
                try Self.verify(tmp, expectedSize: expectedSize, expectedHash: expectedHash, name: name)
            }
            job.onCancel { verifier.cancel() }   // 検証中の cancelDownload でも止める
            try await withTaskCancellationHandler {
                try await verifier.value
            } onCancel: {
                verifier.cancel()
            }
            if job.wasCancelled { throw CancellationError() }
            try Task.checkCancellation()

            // 原子的に配置（既存があれば置換）
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
            staged = nil
            jobs[name] = nil
            downloads[name] = nil
            refresh()
        } catch {
            if let staged { try? fm.removeItem(at: staged) }
            jobs[name] = nil
            if let data = job.resumeData {
                try? data.write(to: resumeFile)
            } else {
                try? fm.removeItem(at: resumeFile)   // 使えない（使い終えた）再開データを残さない
            }
            // 中止の操作があっても、実際のエラーが中止由来でなければ失敗として表示する
            if Self.isCancellation(error) && (job.wasCancelled || Task.isCancelled) {
                downloads[name] = nil
            } else {
                downloads[name] = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// サイズと SHA-256 を検証する（タスクのキャンセルで中断）。
    private nonisolated static func verify(_ url: URL, expectedSize: Int64, expectedHash: String, name: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == expectedSize else {
            throw ModelStoreError.sizeMismatch(expected: expectedSize, actual: actualSize)
        }
        let hash = try sha256Hex(of: url)
        guard hash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
            throw ModelStoreError.checksumMismatch(name)
        }
    }

    /// ダウンロードを中止する（再開データは保存され、次回 `download` で続きから再開を試みる）。
    public func cancelDownload(_ file: ModelFile) {
        jobs[file.file]?.cancel()
    }

    public func delete(_ file: ModelFile) throws {
        try? fm.removeItem(at: resumeURL(for: file))
        try? fm.removeItem(at: legacyResumeURL(for: file))
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
            let magic: Data?
            do {
                magic = try fh.read(upToCount: 4)
                try? fh.close()
            } catch {
                try? fh.close()
                throw error
            }
            guard magic == Data("GGUF".utf8) else { throw ModelStoreError.invalidGGUF }
            let tmp = dir.appendingPathComponent(".import-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: url, to: tmp)
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: dest)
                }
            } catch {
                try? fm.removeItem(at: tmp)   // コピー途中・置換失敗の一時ファイルを残さない
                throw error
            }
        }.value
        refresh()
        return dest
    }

    // MARK: - SHA-256

    /// 4MiB ずつ読み込むストリーミング SHA-256（GB 級ファイルでもメモリを食わない）。
    /// 実行中のタスクがキャンセルされると `CancellationError` を投げる。
    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
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

    // 以下は lock で保護する
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var stagingDirectory: URL?
    private var movedFile: URL?
    private var moveError: Error?
    private var _resumeData: Data?
    private var _cancelled = false
    private var cancelHandlers: [@Sendable () -> Void] = []
    private var lastReport = Date.distantPast

    var resumeData: Data? { lock.lock(); defer { lock.unlock() }; return _resumeData }
    /// `cancel()`（ユーザー操作または呼び出し元タスクのキャンセル）が呼ばれたか
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    init(url: URL, resumeData: Data?, onProgress: @escaping @Sendable (Double) -> Void) {
        self.url = url
        self.initialResumeData = resumeData
        self.onProgress = onProgress
    }

    /// ダウンロードして、モデルディレクトリ内の一時ファイル（`.download-*`）の URL を返す。
    /// 呼び出し元タスクのキャンセルでも中止する（再開データを残す）。
    func start(stagingDirectory: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                lock.lock()
                self.stagingDirectory = stagingDirectory
                continuation = c
                let cfg = URLSessionConfiguration.default
                cfg.timeoutIntervalForRequest = 60
                cfg.waitsForConnectivity = true
                let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
                session = s
                let t: URLSessionDownloadTask
                if let d = initialResumeData { t = s.downloadTask(withResumeData: d) } else { t = s.downloadTask(with: url) }
                task = t
                // task の設定前に cancel() されていた場合、その cancel() は task を取り消せていない
                let cancelledEarly = _cancelled
                lock.unlock()
                t.resume()
                if cancelledEarly { cancelProducingResumeData(t) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        let t = task
        let handlers = cancelHandlers
        cancelHandlers.removeAll()
        lock.unlock()
        for h in handlers { h() }
        if let t { cancelProducingResumeData(t) }
    }

    /// cancel() 時に呼ぶ処理を登録する（既に cancel 済みなら即座に呼ぶ）。
    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if _cancelled {
            lock.unlock()
            handler()
            return
        }
        cancelHandlers.append(handler)
        lock.unlock()
    }

    private func cancelProducingResumeData(_ t: URLSessionDownloadTask) {
        t.cancel(byProducingResumeData: { [weak self] data in
            guard let self, let data else { return }
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
        lock.lock()
        let dir = stagingDirectory ?? FileManager.default.temporaryDirectory
        lock.unlock()
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
        movedFile = nil
        if let error, _resumeData == nil,
           let d = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            _resumeData = d
        }
        lock.unlock()
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            finish(.failure(error))
            return
        }
        if let mErr { finish(.failure(mErr)); return }
        if let file { finish(.success(file)) } else { finish(.failure(URLError(.unknown))) }
    }
}
#endif
