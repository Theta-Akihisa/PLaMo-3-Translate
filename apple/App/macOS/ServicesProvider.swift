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

    /// パネルを閉じてメインウィンドウを前面に出す。ウィンドウが閉じられていれば開き直す
    func openMainWindow() {
        close()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else if let url = URL(string: "plamotranslate://open") {
            // メインウィンドウが無い場合は URL スキーム経由で WindowGroup に新しいウィンドウを作らせる
            NSWorkspace.shared.open(url)
        }
    }

    func show(source: String, nearMouse: Bool = false) {
        panel?.close()
        let host = NSHostingController(rootView: ServiceResultView(source: source).environmentObject(AppModel.shared))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.contentViewController = host
        p.title = "PLaMoで翻訳"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        if nearMouse {
            let m = NSEvent.mouseLocation
            var origin = NSPoint(x: m.x + 12, y: m.y - 332)
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main {
                let f = screen.visibleFrame
                origin.x = min(max(origin.x, f.minX), f.maxX - 460)
                origin.y = min(max(origin.y, f.minY), f.maxY - 320)
            }
            p.setFrameOrigin(origin)
        } else {
            p.center()
        }
        shownAt = Date()
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }
}

struct ServiceResultView: View {
    @EnvironmentObject var model: AppModel
    let source: String
    @State private var output = ""
    @State private var error: String?
    @State private var busy = true
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("原文").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(source).translationTextFont().textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 90)
            Divider()
            HStack {
                Text("訳文").font(.caption).foregroundStyle(.secondary)
                if busy { ProgressView().controlSize(.mini) }
            }
            ScrollView {
                VStack(alignment: .leading) {
                    if let error { Text(error).foregroundStyle(.red) }
                    Text(output).translationTextFont().textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("メインウィンドウで開く") {
                    model.translate(externalText: source)
                    ResultPanelController.shared.openMainWindow()
                }
                Spacer()
                Button("コピー") { Clipboard.copy(output) }.disabled(output.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 260)
        .onAppear {
            task = Task {
                do {
                    output = try await model.performTranslation(text: source) { output = $0 }
                } catch is CancellationError {
                } catch {
                    self.error = error.localizedDescription
                }
                busy = false
            }
        }
        .onDisappear { task?.cancel() }
    }
}
