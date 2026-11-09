import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformTextView = UITextView
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
typealias PlatformTextView = NSTextView
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif

/// 原文と訳文のスクロールを連動させる。
///
/// 片方をスクロールすると、もう片方を「同じ段落の同じ位置」へスクロールする。
/// 段落（空行区切り）の数が両方で同じなら段落単位で対応づけ（長い文書は段落ごとに翻訳するので通常一致する）、
/// 行数が同じなら行単位、どちらも違えば全体に対する割合で合わせる。
@MainActor
final class ScrollSyncController: ObservableObject {
    enum Side { case source, target }

    /// 連動のオン／オフ（設定 `scrollSync.v1`）
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }
    static let enabledKey = "scrollSync.v1"

    private weak var source: PlatformTextView?
    private weak var target: PlatformTextView?
    private var isSyncing = false
    /// 最後にユーザーが動かした側（訳文が伸びたときにどちらに合わせるか）
    private var leader: Side = .source

    func register(_ view: PlatformTextView, as side: Side) {
        switch side {
        case .source: source = view
        case .target: target = view
        }
    }

    /// ユーザー操作でスクロールされた
    func didScroll(_ side: Side) {
        guard !isSyncing, isEnabled else { return }
        leader = side
        sync(from: side)
    }

    /// 文字列やレイアウトが変わった（訳文のストリーミング・文字サイズ変更など）。直前に動かした側に合わせ直す
    func contentDidChange() {
        guard !isSyncing, isEnabled else { return }
        sync(from: leader)
    }

    private func sync(from side: Side) {
        guard let from = (side == .source ? source : target),
              let to = (side == .source ? target : source) else { return }
        isSyncing = true
        defer { isSyncing = false }
        let y = ScrollMapping.mappedOffset(from: from, to: to)
        TextViewGeometry.setScrollOffset(y, of: to)
    }
}

/// 2 つのテキストビュー間でスクロール位置を対応づける
@MainActor
enum ScrollMapping {
    static func mappedOffset(from a: PlatformTextView, to b: PlatformTextView) -> CGFloat {
        let aOffset = TextViewGeometry.scrollOffset(of: a)
        let aMax = TextViewGeometry.maxScrollOffset(of: a)
        let bMax = TextViewGeometry.maxScrollOffset(of: b)
        guard bMax > 0 else { return 0 }
        // 端は端に合わせる（最後まで読んだら両方とも最後）
        if aOffset <= 0.5 { return 0 }
        if aOffset >= aMax - 1 { return bMax }

        let aText = TextViewGeometry.string(of: a)
        let bText = TextViewGeometry.string(of: b)
        for unitsOf in [TextUnits.paragraphStarts, TextUnits.lineStarts] {
            let aStarts = unitsOf(aText), bStarts = unitsOf(bText)
            guard aStarts.count > 1, aStarts.count == bStarts.count else { continue }
            let aYs = aStarts.map { TextViewGeometry.yOffset(ofCharacterAt: $0, in: a) } + [TextViewGeometry.contentHeight(of: a)]
            let bYs = bStarts.map { TextViewGeometry.yOffset(ofCharacterAt: $0, in: b) } + [TextViewGeometry.contentHeight(of: b)]
            // a の表示上端がどの単位の何割の位置か
            let i = max(0, (aYs.lastIndex { $0 <= aOffset } ?? 0))
            let unit = min(i, aStarts.count - 1)
            let span = max(aYs[unit + 1] - aYs[unit], 1)
            let fraction = min(max((aOffset - aYs[unit]) / span, 0), 1)
            let y = bYs[unit] + fraction * (bYs[unit + 1] - bYs[unit])
            return min(max(y, 0), bMax)
        }
        // 対応づけられない場合は全体に対する割合
        return aMax > 0 ? (aOffset / aMax) * bMax : 0
    }
}

/// 段落・行の開始位置（UTF-16 オフセット）
enum TextUnits {
    /// 空行で区切られた段落の開始位置
    static func paragraphStarts(_ s: String) -> [Int] {
        let ns = s as NSString
        guard ns.length > 0 else { return [] }
        var starts = [firstNonWhitespace(ns, from: 0)]
        let re = try! NSRegularExpression(pattern: "\\n[ \\t\\u3000]*\\n\\s*")
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let end = m.range.location + m.range.length
            if end < ns.length { starts.append(end) }
        }
        return starts
    }

    /// 空でない行の開始位置
    static func lineStarts(_ s: String) -> [Int] {
        let ns = s as NSString
        var starts: [Int] = []
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { starts.append(line.location) }
            location = line.location + max(line.length, 1)
        }
        return starts
    }

    private static func firstNonWhitespace(_ ns: NSString, from i: Int) -> Int {
        let r = ns.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted,
                                    range: NSRange(location: i, length: ns.length - i))
        return r.location == NSNotFound ? 0 : r.location
    }
}

/// TextKit 1 を使ったテキストビューの座標計算（iOS / macOS 共通の窓口）
@MainActor
enum TextViewGeometry {
    #if canImport(UIKit)
    static func string(of v: UITextView) -> String { v.text ?? "" }
    static func scrollOffset(of v: UITextView) -> CGFloat { v.contentOffset.y + v.adjustedContentInset.top }
    static func maxScrollOffset(of v: UITextView) -> CGFloat {
        max(0, v.contentSize.height + v.adjustedContentInset.top + v.adjustedContentInset.bottom - v.bounds.height)
    }
    static func setScrollOffset(_ y: CGFloat, of v: UITextView) {
        v.setContentOffset(CGPoint(x: v.contentOffset.x, y: y - v.adjustedContentInset.top), animated: false)
    }
    static func contentHeight(of v: UITextView) -> CGFloat { v.contentSize.height }
    static func yOffset(ofCharacterAt index: Int, in v: UITextView) -> CGFloat {
        lineTop(ofCharacterAt: index, layoutManager: v.layoutManager, textLength: v.textStorage.length) + v.textContainerInset.top
    }
    #else
    static func string(of v: NSTextView) -> String { v.string }
    static func scrollOffset(of v: NSTextView) -> CGFloat { v.enclosingScrollView?.contentView.bounds.origin.y ?? 0 }
    static func maxScrollOffset(of v: NSTextView) -> CGFloat {
        guard let sv = v.enclosingScrollView else { return 0 }
        return max(0, v.frame.height - sv.contentView.bounds.height)
    }
    static func setScrollOffset(_ y: CGFloat, of v: NSTextView) {
        guard let sv = v.enclosingScrollView else { return }
        sv.contentView.scroll(to: NSPoint(x: sv.contentView.bounds.origin.x, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }
    static func contentHeight(of v: NSTextView) -> CGFloat { v.frame.height }
    static func yOffset(ofCharacterAt index: Int, in v: NSTextView) -> CGFloat {
        guard let lm = v.layoutManager, let storage = v.textStorage else { return 0 }
        return lineTop(ofCharacterAt: index, layoutManager: lm, textLength: storage.length) + v.textContainerOrigin.y
    }
    #endif

    private static func lineTop(ofCharacterAt index: Int, layoutManager lm: NSLayoutManager, textLength: Int) -> CGFloat {
        guard textLength > 0 else { return 0 }
        let glyph = lm.glyphIndexForCharacter(at: min(max(index, 0), textLength - 1))
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }
}

// MARK: - テキストビュー（原文: 編集可 / 訳文: 選択のみ）

#if canImport(UIKit)
struct SyncedTextView: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var fontSize: CGFloat
    var side: ScrollSyncController.Side
    var controller: ScrollSyncController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView(usingTextLayoutManager: false)   // TextKit 1（座標計算に NSLayoutManager を使う）
        v.delegate = context.coordinator
        v.backgroundColor = .clear
        v.isEditable = isEditable
        v.isSelectable = true
        v.alwaysBounceVertical = true
        v.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        v.adjustsFontForContentSizeCategory = false   // 倍率は SwiftUI 側（Dynamic Type × ユーザー倍率）で計算済み
        // ファイルのドロップは SwiftUI 側（原文ペイン）で受ける
        v.interactions.removeAll { $0 is UIDropInteraction }
        v.font = .systemFont(ofSize: fontSize)
        v.textColor = .label
        v.text = text
        controller.register(v, as: side)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        var changed = false
        if v.text != text { v.text = text; changed = true }
        if v.font?.pointSize != fontSize { v.font = .systemFont(ofSize: fontSize); changed = true }
        v.isEditable = isEditable
        if changed {
            let controller = controller
            Task { @MainActor in controller.contentDidChange() }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SyncedTextView
        init(_ parent: SyncedTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            MainActor.assumeIsolated { parent.controller.didScroll(parent.side) }
        }
    }
}
#else
struct SyncedTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var fontSize: CGFloat
    var side: ScrollSyncController.Side
    var controller: ScrollSyncController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let v = NSTextView(usingTextLayoutManager: false)   // TextKit 1（座標計算に NSLayoutManager を使う）
        v.delegate = context.coordinator
        v.drawsBackground = false
        v.isEditable = isEditable
        v.isSelectable = true
        v.isRichText = false
        v.allowsUndo = true
        v.importsGraphics = false
        v.isAutomaticQuoteSubstitutionEnabled = false
        v.isAutomaticDashSubstitutionEnabled = false
        v.textContainerInset = NSSize(width: 12, height: 12)
        v.isVerticallyResizable = true
        v.isHorizontallyResizable = false
        v.autoresizingMask = [.width]
        v.minSize = NSSize(width: 0, height: 0)
        v.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        v.textContainer?.widthTracksTextView = true
        v.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        v.font = .systemFont(ofSize: fontSize)
        v.textColor = .labelColor
        v.string = text
        // ファイルのドロップは SwiftUI 側（原文ペイン）で受ける。テキスト ビューがファイルパスを挿入しないようにする
        v.unregisterDraggedTypes()
        scroll.documentView = v

        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scroll.contentView)
        controller.register(v, as: side)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let v = scroll.documentView as? NSTextView else { return }
        var changed = false
        if v.string != text {
            let selection = v.selectedRanges
            v.string = text
            if isEditable, let r = selection.first?.rangeValue, r.location + r.length <= (text as NSString).length {
                v.selectedRanges = selection
            }
            changed = true
        }
        if v.font?.pointSize != fontSize { v.font = .systemFont(ofSize: fontSize); changed = true }
        v.isEditable = isEditable
        if changed {
            let controller = controller
            Task { @MainActor in controller.contentDidChange() }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyncedTextView
        private var observer: NSObjectProtocol?

        init(_ parent: SyncedTextView) { self.parent = parent }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func observe(_ clip: NSClipView) {
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.parent.controller.didScroll(self.parent.side)
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let v = notification.object as? NSTextView else { return }
            parent.text = v.string
        }
    }
}
#endif

/// 連動のオン／オフ（訳文ツールバー・設定画面）
struct ScrollSyncToggle: View {
    @AppStorage(ScrollSyncController.enabledKey) private var enabled = true

    var body: some View {
        Button { enabled.toggle() } label: {
            Label(enabled ? "スクロール連動: オン" : "スクロール連動: オフ",
                  systemImage: enabled ? "link" : "link.badge.plus")
        }
        .help(enabled ? "原文と訳文のスクロールを連動中（クリックでオフ）" : "原文と訳文のスクロールを連動させる")
    }
}

/// 設定画面: スクロール連動
struct ScrollSyncSettingsSection: View {
    @AppStorage(ScrollSyncController.enabledKey) private var enabled = true

    var body: some View {
        Section {
            Toggle("原文と訳文のスクロールを連動", isOn: $enabled)
        } footer: {
            Text("片方をスクロールすると、もう片方も対応する段落の位置までスクロールします。訳文ツールバーの 🔗 ボタンでも切り替えられます。")
        }
    }
}
