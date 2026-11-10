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
    enum Side: Hashable { case source, target }

    /// 連動のオン／オフ（設定 `scrollSync.v1`）
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }
    static let enabledKey = "scrollSync.v1"
    /// 文字列の変化（訳文のストリーミングなど）に合わせ直す間隔の下限（最大 10 回/秒）
    static let contentSyncInterval: TimeInterval = 0.1

    private weak var source: PlatformTextView?
    private weak var target: PlatformTextView?
    /// こちらでスクロール位置を変えている最中（その通知をユーザー操作とみなさない）
    private(set) var isSyncing = false
    /// 最後にユーザーがスクロールした側（訳文が伸びたときにどちらに合わせるか）。
    /// プログラムからのスクロールや文字列の変化では変えない。
    private var leader: Side = .source

    /// 文字列が変わるたびに増やす番号（キャッシュの無効化用）
    private var revisions: [Side: Int] = [:]
    /// 段落・行の開始位置と、その Y 座標のキャッシュ（文字列・幅・文字サイズが変わったら作り直す）
    private var caches: [Side: TextGeometryCache] = [:]

    private var lastContentSync = Date.distantPast
    private var contentSyncScheduled = false

    func register(_ view: PlatformTextView, as side: Side) {
        switch side {
        case .source: source = view
        case .target: target = view
        }
        textDidChange(side)
    }

    private func view(_ side: Side) -> PlatformTextView? {
        side == .source ? source : target
    }

    /// ユーザー操作でスクロールされた（プログラムからのスクロール・リサイズ・文字列の置き換えでは呼ばない）
    func didScroll(_ side: Side) {
        guard !isSyncing, isEnabled else { return }
        leader = side
        sync(from: side)
    }

    /// 文字列が変わった（入力・置き換え）。その側のキャッシュを捨てる
    func textDidChange(_ side: Side) {
        revisions[side, default: 0] += 1
        caches[side] = nil
    }

    /// 文字列やレイアウトが変わった（訳文のストリーミング・文字サイズ変更など）。
    /// 直前にユーザーがスクロールした側に合わせ直す。ストリーミング中は最大 10 回/秒にまとめる。
    func contentDidChange(_ side: Side) {
        textDidChange(side)
        guard isEnabled, !contentSyncScheduled else { return }
        contentSyncScheduled = true
        let wait = max(0, Self.contentSyncInterval - Date().timeIntervalSince(lastContentSync))
        // 次の周回以降（レイアウトが済んでから）に行う
        Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self else { return }
            self.contentSyncScheduled = false
            self.lastContentSync = Date()
            guard !self.isSyncing, self.isEnabled else { return }
            self.sync(from: self.leader)
        }
    }

    private func sync(from side: Side) {
        let otherSide: Side = side == .source ? .target : .source
        guard let from = view(side), let to = view(otherSide) else { return }
        let aOffset = TextViewGeometry.scrollOffset(of: from)
        let aMax = TextViewGeometry.maxScrollOffset(of: from)
        let bMax = TextViewGeometry.maxScrollOffset(of: to)
        // 先頭・末尾・スクロールできない場合は単位の対応づけ（レイアウト計算）を省く
        let needsUnits = aMax > 0 && bMax > 0 && aOffset > 0.5 && aOffset < aMax - 1
        let units = needsUnits ? unitOffsets(from: side, from, to: otherSide, to) : nil
        guard let y = ScrollMapping.mappedOffset(aOffset: aOffset, aMax: aMax, bMax: bMax, units: units) else { return }
        guard abs(y - TextViewGeometry.scrollOffset(of: to)) >= 0.5 else { return }
        isSyncing = true
        defer { isSyncing = false }
        TextViewGeometry.setScrollOffset(y, of: to)
    }

    /// 段落数が同じなら段落、行数が同じなら行の先頭 Y（末尾に本文の高さを足したもの）の組。どちらも違えば nil
    private func unitOffsets(from aSide: Side, _ a: PlatformTextView,
                             to bSide: Side, _ b: PlatformTextView) -> (a: [CGFloat], b: [CGFloat])? {
        let ga = geometry(aSide, a), gb = geometry(bSide, b)
        if ga.paragraphStarts.count > 1, ga.paragraphStarts.count == gb.paragraphStarts.count {
            return (yOffsets(aSide, a, kind: .paragraph), yOffsets(bSide, b, kind: .paragraph))
        }
        if ga.lineStarts.count > 1, ga.lineStarts.count == gb.lineStarts.count {
            return (yOffsets(aSide, a, kind: .line), yOffsets(bSide, b, kind: .line))
        }
        return nil
    }

    private func key(_ side: Side, _ v: PlatformTextView) -> TextGeometryCache.Key {
        TextGeometryCache.Key(revision: revisions[side, default: 0],
                              length: TextViewGeometry.textLength(of: v),
                              width: TextViewGeometry.layoutWidth(of: v),
                              fontSize: TextViewGeometry.fontSize(of: v))
    }

    private func geometry(_ side: Side, _ v: PlatformTextView) -> TextGeometryCache {
        let k = key(side, v)
        if let c = caches[side], c.key == k { return c }
        let text = TextViewGeometry.string(of: v)
        let c = TextGeometryCache(key: k, paragraphStarts: TextUnits.paragraphStarts(text),
                                  lineStarts: TextUnits.lineStarts(text))
        caches[side] = c
        return c
    }

    private func yOffsets(_ side: Side, _ v: PlatformTextView, kind: TextGeometryCache.Kind) -> [CGFloat] {
        let c = geometry(side, v)
        if let ys = c.yOffsets[kind] { return ys }
        let starts = kind == .paragraph ? c.paragraphStarts : c.lineStarts
        let ys = starts.map { TextViewGeometry.yOffset(ofCharacterAt: $0, in: v) } + [TextViewGeometry.contentHeight(of: v)]
        caches[side]?.yOffsets[kind] = ys
        return ys
    }
}

/// 1 つのテキストビューの段落・行の位置（文字列・幅・文字サイズが同じ間は使い回す）
struct TextGeometryCache {
    enum Kind: Hashable { case paragraph, line }

    struct Key: Equatable {
        var revision: Int
        var length: Int
        var width: CGFloat
        var fontSize: CGFloat
    }

    var key: Key
    var paragraphStarts: [Int]
    var lineStarts: [Int]
    /// 各単位の先頭の Y 座標 + 末尾に本文の高さ（必要になったときに計算する）
    var yOffsets: [Kind: [CGFloat]] = [:]
}

/// 2 つのテキストビュー間でスクロール位置を対応づける（純粋な計算）
enum ScrollMapping {
    /// - Parameters:
    ///   - aOffset: 動かした側の表示上端
    ///   - aMax / bMax: それぞれのスクロールできる最大値
    ///   - units: 対応づける単位（段落・行）の先頭 Y。末尾に本文の高さを足したもので、要素数が同じ。nil なら全体の割合で合わせる
    /// - Returns: もう片方のスクロール位置。nil なら動かさない（動かした側がスクロールできない）
    static func mappedOffset(aOffset: CGFloat, aMax: CGFloat, bMax: CGFloat,
                             units: (a: [CGFloat], b: [CGFloat])?) -> CGFloat? {
        // 動かした側がスクロールできない（短い）なら、もう片方はそのままにする
        guard aMax > 0 else { return nil }
        guard bMax > 0 else { return nil }
        // 端は端に合わせる（最後まで読んだら両方とも最後）
        if aOffset <= 0.5 { return 0 }
        if aOffset >= aMax - 1 { return bMax }

        if let units, units.a.count > 2, units.a.count == units.b.count {
            let aYs = units.a, bYs = units.b
            let count = aYs.count - 1   // 単位の数
            // a の表示上端を含む単位（aYs[i] <= aOffset となる最後の i）を二分探索
            var lo = 0, hi = count - 1, unit = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if aYs[mid] <= aOffset { unit = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            let span = max(aYs[unit + 1] - aYs[unit], 1)
            let fraction = min(max((aOffset - aYs[unit]) / span, 0), 1)
            let y = bYs[unit] + fraction * (bYs[unit + 1] - bYs[unit])
            return min(max(y, 0), bMax)
        }
        // 対応づけられない場合は全体に対する割合
        return (aOffset / aMax) * bMax
    }
}

/// 段落・行の開始位置（UTF-16 オフセット）
enum TextUnits {
    private static let paragraphBreak = try! NSRegularExpression(pattern: "\\n[ \\t\\u3000]*\\n\\s*")

    /// 空行で区切られた段落の開始位置
    static func paragraphStarts(_ s: String) -> [Int] {
        let ns = s as NSString
        guard ns.length > 0 else { return [] }
        var starts = [firstNonWhitespace(ns, from: 0)]
        for m in paragraphBreak.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
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
    static func textLength(of v: UITextView) -> Int { v.textStorage.length }
    static func layoutWidth(of v: UITextView) -> CGFloat { v.textContainer.size.width }
    static func fontSize(of v: UITextView) -> CGFloat { v.font?.pointSize ?? 0 }
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
    static func textLength(of v: NSTextView) -> Int { v.textStorage?.length ?? 0 }
    static func layoutWidth(of v: NSTextView) -> CGFloat { v.textContainer?.size.width ?? 0 }
    static func fontSize(of v: NSTextView) -> CGFloat { v.font?.pointSize ?? 0 }
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
        // 日本語入力の変換中（未確定文字あり）は書き換えない（変換が壊れる）
        if v.text != text, v.markedTextRange == nil {
            v.text = text
            // プログラムからの置き換え後に古い取り消し履歴を適用すると範囲がずれるので消す
            v.undoManager?.removeAllActions()
            changed = true
        }
        if v.font?.pointSize != fontSize { v.font = .systemFont(ofSize: fontSize); changed = true }
        v.isEditable = isEditable
        if changed { controller.contentDidChange(side) }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SyncedTextView
        init(_ parent: SyncedTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            MainActor.assumeIsolated { parent.controller.textDidChange(parent.side) }
            // 変換中の未確定文字はモデルに渡さない（確定したときにもう一度呼ばれる）
            guard textView.markedTextRange == nil else { return }
            parent.text = textView.text
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // 指で動かしている・慣性で動いているときだけユーザー操作とみなす
            // （setContentOffset・文字列の変化・キーボードによる自動スクロールは除く）
            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
            MainActor.assumeIsolated { parent.controller.didScroll(parent.side) }
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
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
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let v = scroll.documentView as? NSTextView else { return }
        var changed = false
        // 日本語入力の変換中（未確定文字あり）は書き換えない（変換が壊れる）
        if v.string != text, !v.hasMarkedText() {
            let selection = v.selectedRanges
            coordinator.performProgrammaticChange {
                v.string = text
                if isEditable, let r = selection.first?.rangeValue, r.location + r.length <= (text as NSString).length {
                    v.selectedRanges = selection
                }
            }
            // プログラムからの置き換え後に古い取り消し履歴を適用すると範囲がずれるので消す
            coordinator.undoManager.removeAllActions()
            changed = true
        }
        if v.font?.pointSize != fontSize {
            coordinator.performProgrammaticChange { v.font = .systemFont(ofSize: fontSize) }
            changed = true
        }
        v.isEditable = isEditable
        if changed { controller.contentDidChange(side) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyncedTextView
        /// このテキストビュー専用の取り消し履歴（ウィンドウ共有のものを消さずに済むように）
        let undoManager = UndoManager()
        private var observer: NSObjectProtocol?
        /// プログラムからの変更中（その間のスクロール位置の変化はユーザー操作ではない）
        private var programmaticDepth = 0
        private var lastOrigin: CGFloat = 0
        private var lastClipSize: CGSize = .zero
        private var lastDocumentHeight: CGFloat = 0

        init(_ parent: SyncedTextView) { self.parent = parent }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func performProgrammaticChange(_ change: () -> Void) {
            programmaticDepth += 1
            defer { programmaticDepth -= 1 }
            change()
        }

        @MainActor
        func observe(_ clip: NSClipView) {
            record(clip)
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let clip = note.object as? NSClipView else { return }
                    self.clipBoundsDidChange(clip)
                }
            }
        }

        @MainActor
        private func record(_ clip: NSClipView) {
            lastOrigin = clip.bounds.origin.y
            lastClipSize = clip.bounds.size
            lastDocumentHeight = clip.documentView?.frame.height ?? 0
        }

        /// 表示位置が変わった。ユーザーのスクロールのときだけ連動させる
        @MainActor
        private func clipBoundsDidChange(_ clip: NSClipView) {
            let origin = clip.bounds.origin.y
            let size = clip.bounds.size
            let documentHeight = clip.documentView?.frame.height ?? 0
            defer { record(clip) }
            // 縦の位置が変わっていない（横方向・大きさだけの変化）
            guard origin != lastOrigin else { return }
            // こちらで動かした（連動・文字列の置き換え・文字サイズ変更）
            guard programmaticDepth == 0, !parent.controller.isSyncing else { return }
            // ウィンドウの大きさ・文字列の長さが変わったことによる位置の補正
            guard size == lastClipSize, documentHeight == lastDocumentHeight else { return }
            parent.controller.didScroll(parent.side)
        }

        func textDidChange(_ notification: Notification) {
            guard let v = notification.object as? NSTextView else { return }
            MainActor.assumeIsolated { parent.controller.textDidChange(parent.side) }
            // 変換中の未確定文字はモデルに渡さない（確定したときにもう一度呼ばれる）
            guard !v.hasMarkedText() else { return }
            parent.text = v.string
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
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
