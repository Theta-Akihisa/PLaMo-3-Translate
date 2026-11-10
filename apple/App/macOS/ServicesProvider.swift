import AppKit
import SwiftUI

/// Services メニュー「PLaMoで翻訳」。Info.plist の NSServices (NSMessage = translateSelection) と対応する。
final class ServicesProvider: NSObject {
    @objc func translateSelection(_ pboard: NSPasteboard, userData: String,
                                  error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "翻訳するテキストが選択されていません" as NSString
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ResultPanelController.shared.show(source: text)
            }
        }
    }
}

@MainActor
final class ResultPanelController {
    static let shared = ResultPanelController()
    private var panel: NSPanel?
    private var keyWindowObserver: NSObjectProtocol?
    /// 表示直後はアプリのアクティブ化で前のウィンドウが一瞬キーになることがあるので無視する
    private var shownAt = Date.distantPast

    private init() {
        // メインウィンドウへ移った（クリック・Dock・「メインウィンドウで開く」）らクイック翻訳パネルを閉じる
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                ResultPanelController.shared.windowDidBecomeKey(window)
            }
        }
    }

    private func windowDidBecomeKey(_ window: NSWindow) {
        guard let panel, panel.isVisible, window !== panel,
              Date().timeIntervalSince(shownAt) > 0.6 else { return }
        // メインウィンドウ（パネル・メニューバーのポップアップ以外）が前面になったときだけ閉じる
        if !(window is NSPanel), window.canBecomeMain {
            close()
        }
    }

    func close() {
        panel?.close()   // ServiceResultView の onDisappear で進行中の翻訳も止まる
        panel = nil
    }

    /// パネルを閉じてメインウィンドウを前面に出す。ウィンドウが閉じられていれば SwiftUI の openWindow で開き直す
    func openMainWindow() {
        close()
        MainWindow.show()
    }

    /// ユーザーがパネルの大きさを手で変えたら、以降は自動で広げない
    private var userResized = false
    private var isProgrammaticResize = false
    private var resizeObserver: NSObjectProtocol?

    func show(source: String, nearMouse: Bool = false) {
        panel?.close()
        let mouse = NSEvent.mouseLocation
        let screen = (nearMouse ? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) : nil)
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let layout = QuickPanelSizing.layout(source: source, output: nil, visibleFrame: visible)

        let view = ServiceResultView(source: source,
                                     sourceIdealHeight: layout.sourceHeight,
                                     targetIdealHeight: layout.targetHeight)
            .environmentObject(AppModel.shared)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []   // パネルの大きさはこちらで決める（SwiftUI の理想サイズに縮めさせない）
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: layout.windowSize),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.contentViewController = host
        p.setContentSize(layout.windowSize)
        p.contentMinSize = QuickPanelSizing.minSize
        p.title = "PLaMoで翻訳"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        if nearMouse {
            // マウスの右下に出し、画面からはみ出さないようにする
            let size = p.frame.size
            var origin = NSPoint(x: mouse.x + 12, y: mouse.y - 12 - size.height)
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
            p.setFrameOrigin(origin)
        } else {
            p.center()
        }

        userResized = false
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: p, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let c = ResultPanelController.shared
                if !c.isProgrammaticResize { c.userResized = true }
            }
        }

        shownAt = Date()
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    /// 訳文が見込みより長くなったら、上端を固定したまま画面の 8 割まで下に広げる（ユーザーが手で変えた後は何もしない）
    func fitToContent(source: String, output: String) {
        guard let panel, panel.isVisible, !userResized else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let current = panel.contentRect(forFrameRect: panel.frame).size
        let wanted = QuickPanelSizing.layout(source: source, output: output, visibleFrame: visible,
                                             fixedWidth: current.width).windowSize
        guard wanted.height > current.height + 8 else { return }
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: CGSize(width: current.width, height: wanted.height)))
        frame.origin.x = panel.frame.minX
        frame.origin.y = max(visible.minY, panel.frame.maxY - frame.height)
        isProgrammaticResize = true
        panel.setFrame(frame, display: true, animate: false)
        isProgrammaticResize = false
    }
}

/// クイック翻訳パネルの大きさを文章量から決める
@MainActor
enum QuickPanelSizing {
    static let minSize = CGSize(width: 380, height: 240)
    /// 見出し・ボタン・余白など、本文以外の高さ
    static let chromeHeight: CGFloat = 132
    /// 本文の左右の余白（padding + スクロールバー）
    static let horizontalInset: CGFloat = 44

    struct Layout {
        var windowSize: CGSize
        var sourceHeight: CGFloat
        var targetHeight: CGFloat
    }

    static var font: NSFont { .systemFont(ofSize: TextScale.basePointSize * CGFloat(TextScale.current)) }

    /// - Parameters:
    ///   - output: 訳文（まだ無ければ原文と同じくらいの長さと見込む）
    ///   - fixedWidth: 表示中のパネルの幅（広げるときは幅を変えない）
    static func layout(source: String, output: String?, visibleFrame: NSRect, fixedWidth: CGFloat? = nil) -> Layout {
        let maxWidth = max(minSize.width, min(720, visibleFrame.width * 0.6))
        let maxHeight = max(minSize.height, visibleFrame.height * 0.8)
        let width = fixedWidth ?? preferredWidth(for: source, maxWidth: maxWidth)
        let textWidth = max(width - horizontalInset, 100)

        let src = textHeight(source, width: textWidth)
        let out = output.map { textHeight($0, width: textWidth) } ?? src
        var srcH = max(src, 40), outH = max(out, 60)
        let available = maxHeight - chromeHeight
        if srcH + outH > available {
            // 画面に収まらない分は両方を比率で縮める（各ペインはスクロールできる）
            let ratio = available / (srcH + outH)
            srcH = max(40, srcH * ratio)
            outH = max(60, outH * ratio)
        }
        let height = min(max(chromeHeight + srcH + outH, minSize.height), maxHeight)
        return Layout(windowSize: CGSize(width: width, height: height), sourceHeight: srcH, targetHeight: outH)
    }

    /// 短い文は狭く、長い文は広く（1 行で収まるならその幅、長い文章は最大幅）
    static func preferredWidth(for text: String, maxWidth: CGFloat) -> CGFloat {
        let oneLine = (text as NSString).size(withAttributes: [.font: font]).width   // 改行があれば最も長い行の幅
        return min(max(ceil(oneLine) + horizontalInset, minSize.width), maxWidth)
    }

    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return ceil(rect.height) + 10
    }
}

/// クイック翻訳（⌘C×2・サービスメニュー）のパネル。原文と訳文の間の境界線をドラッグして配分を変えられる
struct ServiceResultView: View {
    @EnvironmentObject var model: AppModel
    let source: String
    var sourceIdealHeight: CGFloat = 90
    var targetIdealHeight: CGFloat = 120
    @State private var output = ""
    @State private var error: String?
    /// 訳文が長さの上限で途中で切れたときの警告（途中までの訳文は表示したまま）
    @State private var warning: String?
    @State private var busy = true
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // VSplitView: 原文と訳文の間の線をドラッグして高さを調整できる
            VSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("原文").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(source).translationTextFont().textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(minHeight: 56, idealHeight: sourceIdealHeight + 34, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("訳文").font(.caption).foregroundStyle(.secondary)
                        if busy { ProgressView().controlSize(.mini) }
                    }
                    ScrollView {
                        VStack(alignment: .leading) {
                            if let error { Text(error).foregroundStyle(.red) }
                            if let warning { Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                            Text(output).translationTextFont().textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .frame(minHeight: 72, idealHeight: targetIdealHeight + 34, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("メインウィンドウで開く") {
                    model.translate(externalText: source, from: "クイック翻訳パネル")
                    ResultPanelController.shared.openMainWindow()
                }
                Spacer()
                Button("コピー") { Clipboard.copy(output) }.disabled(output.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: QuickPanelSizing.minSize.width, minHeight: QuickPanelSizing.minSize.height)
        .onAppear {
            task = Task {
                do {
                    let result = try await model.performTranslation(text: source) { output = $0 }
                    output = result.text
                    warning = result.warning
                } catch is CancellationError {
                } catch {
                    self.error = error.localizedDescription
                }
                busy = false
            }
        }
        .onChange(of: output) { _, newValue in
            // SwiftUI の更新中にウィンドウの大きさを変えると再入レイアウトになるので、次の周回で行う
            let source = source
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ResultPanelController.shared.fitToContent(source: source, output: newValue)
                }
            }
        }
        .onDisappear { task?.cancel() }
    }
}
