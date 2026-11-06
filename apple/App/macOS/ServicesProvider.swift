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

    func show(source: String) {
        panel?.close()
        let host = NSHostingController(rootView: ServiceResultView(source: source).environmentObject(AppModel.shared))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.contentViewController = host
        p.title = "PLaMoで翻訳"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
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
            ScrollView { Text(source).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 90)
            Divider()
            HStack {
                Text("訳文").font(.caption).foregroundStyle(.secondary)
                if busy { ProgressView().controlSize(.mini) }
            }
            ScrollView {
                VStack(alignment: .leading) {
                    if let error { Text(error).foregroundStyle(.red) }
                    Text(output).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
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
