import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 翻訳テキスト（原文・訳文）の文字サイズ倍率。`@AppStorage(TextScale.key)` で全画面が共有する。
///
/// - macOS: 表示メニューの「文字を大きく / 小さく / 標準サイズ」（⌘+ / ⌘− / ⌘0）
/// - iOS / iPadOS: ハードウェアキーボードの ⌘+ / ⌘− / ⌘0、ピンチ操作、訳文ツールバーの「文字サイズ」メニュー
/// - 両方: 設定画面のスライダー
enum TextScale {
    static let key = "textScale.v1"
    static let defaultValue: Double = 1.0

    /// 段階（Safari のページ拡大に近い刻み）
    static let steps: [Double] = [0.75, 0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0, 2.5, 3.0]
    static var range: ClosedRange<Double> { steps.first! ... steps.last! }

    /// 倍率 1.0 のときの翻訳テキストのポイントサイズ
    #if os(macOS)
    static let basePointSize: CGFloat = 17
    #else
    static let basePointSize: CGFloat = 20   // .title3 相当。Dynamic Type で更に拡縮される
    #endif

    static func larger(than v: Double) -> Double {
        steps.first { $0 > v + 0.001 } ?? steps.last!
    }

    static func smaller(than v: Double) -> Double {
        steps.last { $0 < v - 0.001 } ?? steps.first!
    }

    static func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    static func percentText(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    // MARK: - UserDefaults 経由の操作（メニュー・キー操作から使う）

    static var current: Double {
        get {
            let v = UserDefaults.standard.object(forKey: key) as? Double ?? defaultValue
            return clamp(v)
        }
        set { UserDefaults.standard.set(clamp(newValue), forKey: key) }
    }

    static func increase() { current = larger(than: current) }
    static func decrease() { current = smaller(than: current) }
    static func reset() { current = defaultValue }
}

/// 翻訳テキスト用フォント。Dynamic Type（iOS）× ユーザー倍率でサイズを決める。
struct TranslationTextFont: ViewModifier {
    @AppStorage(TextScale.key) private var scale = TextScale.defaultValue
    @ScaledMetric(relativeTo: .title3) private var base: CGFloat = TextScale.basePointSize

    func body(content: Content) -> some View {
        content.font(.system(size: base * TextScale.clamp(scale)))
    }
}

extension View {
    /// 原文・訳文などの翻訳テキストに、ユーザーが調整した文字サイズを適用する
    func translationTextFont() -> some View { modifier(TranslationTextFont()) }

    /// ピンチで文字サイズを変える（iOS / iPadOS。macOS ではトラックパッドのピンチ）
    func pinchToScaleText() -> some View { modifier(PinchToScaleText()) }
}

private struct PinchToScaleText: ViewModifier {
    @AppStorage(TextScale.key) private var scale = TextScale.defaultValue
    @State private var startScale: Double?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = startScale ?? scale
                    if startScale == nil { startScale = start }
                    scale = TextScale.clamp(start * value.magnification)
                }
                .onEnded { _ in
                    // 指を離したら一番近い段階にそろえる
                    scale = TextScale.steps.min { abs($0 - scale) < abs($1 - scale) } ?? TextScale.defaultValue
                    startScale = nil
                }
        )
    }
}

/// メニュー（macOS の「表示」メニュー / iPadOS のキーボードショートカット）
/// UserDefaults へ直接書き込み、各 View の `@AppStorage(TextScale.key)` が変更を受け取る。
struct TextSizeCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Section {
                Button("文字を大きく") { TextScale.increase() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("文字を小さく") { TextScale.decrease() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("標準の文字サイズ") { TextScale.reset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

/// 訳文ツールバーなどに置く「文字サイズ」メニュー
struct TextSizeMenu: View {
    @AppStorage(TextScale.key) private var scale = TextScale.defaultValue

    var body: some View {
        Menu {
            Button { scale = TextScale.larger(than: scale) } label: { Label("文字を大きく", systemImage: "plus.magnifyingglass") }
                .disabled(scale >= TextScale.range.upperBound)
            Button { scale = TextScale.smaller(than: scale) } label: { Label("文字を小さく", systemImage: "minus.magnifyingglass") }
                .disabled(scale <= TextScale.range.lowerBound)
            Button { scale = TextScale.defaultValue } label: { Label("標準サイズ", systemImage: "arrow.counterclockwise") }
        } label: {
            Label("文字サイズ（\(TextScale.percentText(scale))）", systemImage: "textformat.size")
        }
        .help("文字サイズ（⌘+ / ⌘− / ⌘0）")
    }
}

/// 設定画面のスライダー
struct TextSizeSettingsSection: View {
    @AppStorage(TextScale.key) private var scale = TextScale.defaultValue

    var body: some View {
        Section {
            HStack {
                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                Slider(value: $scale, in: TextScale.range, step: 0.05)
                Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
            }
            HStack {
                Text("サンプル: The meeting has been rescheduled. 会議は変更されました。")
                    .translationTextFont()
                    .lineLimit(3)
                Spacer()
            }
            HStack {
                Text(TextScale.percentText(scale)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("標準に戻す") { scale = TextScale.defaultValue }
                    .disabled(abs(scale - TextScale.defaultValue) < 0.001)
            }
        } header: {
            Text("文字サイズ")
        } footer: {
            #if os(macOS)
            Text("⌘+ で大きく、⌘− で小さく、⌘0 で標準に戻します（表示メニューからも操作できます）。")
            #else
            Text("原文・訳文の上でピンチしても変更できます。外部キーボードでは ⌘+ / ⌘− / ⌘0 が使えます。")
            #endif
        }
    }
}

/// ファイル メニュー:「ファイルを開く…」（⌘O）。PDF・テキスト・RTF を原文として読み込む。
struct OpenFileCommands: Commands {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("ファイルを開く…") {
                #if os(macOS)
                // メインウィンドウが閉じていても開けるように、先にウィンドウを出す
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    openWindow(id: "main")
                }
                NSApp.activate(ignoringOtherApps: true)
                #endif
                AppModel.shared.showFileImporter = true
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}
