import SwiftUI
import PlamoTranslateCore
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
/// 1. 長文（段落ごとに翻訳）は Kit の段落対応（`OutputAlignment`）で、原文の段落と訳文の段落の Y を組にして対応づける。
///    翻訳途中は訳し終えた段落だけを対応づけ、その先では相手を「翻訳済みの部分の終わり」に留める。
/// 2. 段落対応が無い（短文・原文を編集した後など）ときは、空行で区切った段落の数が同じなら段落、
///    行数が同じなら行で対応づけ、どちらも違えば全体に対する割合で合わせる。
/// 3. 翻訳済みなら、基準側の最後の 1 画面分で相手を末尾へ少しずつ寄せる（両方同時に最後に着く）。
@MainActor
final class ScrollSyncController: ObservableObject {
    enum Side: Hashable {
        case source, target
        var other: Side { self == .source ? .target : .source }
    }

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
    /// 連動の基準にする側。ユーザーがスクロールした側。
    /// 原文を編集したとき・訳文が空になったとき・翻訳を始めたときは原文に戻す。
    private(set) var leader: Side = .source
    /// 翻訳中。文字列の変化による合わせ直しは常に原文を基準にする（訳文側のユーザー操作では原文も動かす）
    private var isTranslating = false
    /// Kit の段落対応（長文の翻訳結果）。表示中の文字列と一致する間だけ使う
    private var alignment: OutputAlignment?

    /// 文字列が変わるたびに増やす番号（キャッシュの無効化用）
    private var revisions: [Side: Int] = [:]
    /// 段落・行の開始位置のキャッシュ（文字列・幅・文字サイズが変わったら作り直す）
    private var caches: [Side: TextGeometryCache] = [:]
    /// 対応づける Y の組のキャッシュ（スクロールのたびに計算しない）
    private var unitsCache: UnitsCache?
    /// こちらで最後に設定したスクロール位置（その位置への変化の通知をユーザー操作とみなさない）
    private var programmaticOffsets: [Side: CGFloat] = [:]

    private var lastContentSync = Date.distantPast
    private var contentSyncScheduled = false

    /// 原文・訳文で対応する Y（どちらも単調増加で同じ要素数）
    private struct PairedUnits {
        var source: [CGFloat]
        var target: [CGFloat]
        /// 翻訳途中（末尾の合わせ込みをしない・未翻訳部分では相手を留める）
        var isPartial: Bool
    }

    private struct UnitsCache {
        var source: TextGeometryCache.Key
        var target: TextGeometryCache.Key
        var units: PairedUnits?
    }

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
        programmaticOffsets[side] = nil
        sync(from: side)
    }

    /// ユーザーが文字列を編集した（原文の入力）。原文を編集したら原文を基準にする
    /// （訳文をスクロールした後に原文を直しても、訳文のリセットで原文が先頭へ飛ばないように）
    func userDidEdit(_ side: Side) {
        textDidChange(side)
        if side == .source { leader = .source }
    }

    /// 文字列が変わった（入力・置き換え）。その側のキャッシュを捨てる
    func textDidChange(_ side: Side) {
        revisions[side, default: 0] += 1
        caches[side] = nil
        unitsCache = nil
    }

    /// 文字列やレイアウトが変わった（訳文のストリーミング・文字サイズ変更など）。
    /// 基準の側に合わせ直す（翻訳中は原文）。ストリーミング中は最大 10 回/秒にまとめる。
    func contentDidChange(_ side: Side) {
        textDidChange(side)
        // 訳文が空になった（新しい翻訳・クリア）: 原文を基準に戻す
        if side == .target, let v = target, TextViewGeometry.textLength(of: v) == 0 { leader = .source }
        scheduleContentSync()
    }

    /// Kit の段落対応（長文の翻訳）。短文・訳文のリセット・原文の編集では nil
    func setAlignment(_ newValue: OutputAlignment?) {
        guard newValue != alignment else { return }
        alignment = newValue
        unitsCache = nil
        scheduleContentSync()
    }

    /// 翻訳の開始・終了
    func setTranslating(_ translating: Bool) {
        guard translating != isTranslating else { return }
        isTranslating = translating
        if translating { leader = .source }
        unitsCache = nil
        scheduleContentSync()   // 終わったら末尾の合わせ込みを有効にして合わせ直す
    }

    /// こちらで設定したスクロール位置か（遅れて届いた通知をユーザー操作とみなさない）
    func isProgrammaticOffset(_ y: CGFloat, on side: Side) -> Bool {
        guard let p = programmaticOffsets[side] else { return false }
        return abs(p - y) < 0.5
    }

    private func scheduleContentSync() {
        guard isEnabled, !contentSyncScheduled else { return }
        contentSyncScheduled = true
        let wait = max(0, Self.contentSyncInterval - Date().timeIntervalSince(lastContentSync))
        // 次の周回以降（レイアウト・もう片方のペインの更新が済んでから）に行う
        Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self else { return }
            self.contentSyncScheduled = false
            self.lastContentSync = Date()
            guard !self.isSyncing, self.isEnabled else { return }
            self.sync(from: self.isTranslating ? .source : self.leader)
        }
    }

    private func sync(from side: Side) {
        let otherSide = side.other
        guard let from = view(side), let to = view(otherSide) else { return }
        isSyncing = true
        defer { isSyncing = false }
        // レイアウトが途中だと本文の高さ・スクロールできる範囲が実際より短く、相手が途中で止まる・ずれる。
        // 未レイアウトの部分だけレイアウトしてから測る（済んでいれば何もしない）。
        TextViewGeometry.ensureLayout(of: from)
        TextViewGeometry.ensureLayout(of: to)
        let aMax = TextViewGeometry.maxScrollOffset(of: from)
        let bMax = TextViewGeometry.maxScrollOffset(of: to)
        guard aMax > 0, bMax > 0 else { return }
        var units: (a: [CGFloat], b: [CGFloat])?
        var isPartial = false
        if let u = pairedUnits() {
            units = side == .source ? (u.source, u.target) : (u.target, u.source)
            isPartial = u.isPartial
        }
        guard let y = ScrollMapping.mappedOffset(aOffset: TextViewGeometry.scrollOffset(of: from), aMax: aMax, bMax: bMax,
                                                aViewport: TextViewGeometry.viewportHeight(of: from),
                                                units: units, endBlending: !isPartial && !isTranslating)
        else { return }
        guard abs(y - TextViewGeometry.scrollOffset(of: to)) >= 0.5 else { return }
        programmaticOffsets[otherSide] = TextViewGeometry.setScrollOffset(y, of: to)
    }

    /// 対応づける Y の組（段落対応 → 段落 → 行の順に試す）。文字列・幅・文字サイズが同じ間は使い回す
    private func pairedUnits() -> PairedUnits? {
        guard let s = source, let t = target else { return nil }
        let sk = key(.source, s), tk = key(.target, t)
        if let c = unitsCache, c.source == sk, c.target == tk { return c.units }
        let units = alignedUnits(s, t) ?? heuristicUnits(s, t)
        unitsCache = UnitsCache(source: sk, target: tk, units: units)
        return units
    }

    /// Kit の段落対応から（表示中の文字列が対応の元の文字列と同じときだけ）
    private func alignedUnits(_ s: PlatformTextView, _ t: PlatformTextView) -> PairedUnits? {
        guard let a = alignment,
              TextViewGeometry.textLength(of: s) == a.sourceLength,
              TextViewGeometry.textLength(of: t) == a.targetLength,
              TextViewGeometry.textEquals(a.source, in: s),
              TextViewGeometry.textEquals(a.target, in: t),
              let plan = AlignmentUnits.plan(a.segments, source: a.source, targetLength: a.targetLength)
        else { return nil }
        let ys = ScrollMapping.monotone(a: plan.boundaries.map { TextViewGeometry.y(of: $0.source, in: s) },
                                        b: plan.boundaries.map { TextViewGeometry.y(of: $0.target, in: t) })
        return PairedUnits(source: ys.a, target: ys.b, isPartial: plan.isPartial)
    }

    /// 段落数が同じなら段落、行数が同じなら行の先頭 Y の組（先頭に 0、末尾に本文の高さ）。どちらも違えば nil
    private func heuristicUnits(_ s: PlatformTextView, _ t: PlatformTextView) -> PairedUnits? {
        var gs = geometry(.source, s), gt = geometry(.target, t)
        let ss: [Int], ts: [Int]
        if gs.paragraphStarts.count > 1, gs.paragraphStarts.count == gt.paragraphStarts.count {
            ss = gs.paragraphStarts; ts = gt.paragraphStarts
        } else {
            let sl = gs.lines(), tl = gt.lines()
            caches[.source] = gs
            caches[.target] = gt
            guard sl.count > 1, sl.count == tl.count else { return nil }
            ss = sl; ts = tl
        }
        let ys = ScrollMapping.monotone(
            a: [CGFloat(0)] + ss.map { TextViewGeometry.y(of: .top($0), in: s) } + [TextViewGeometry.contentHeight(of: s)],
            b: [CGFloat(0)] + ts.map { TextViewGeometry.y(of: .top($0), in: t) } + [TextViewGeometry.contentHeight(of: t)])
        return PairedUnits(source: ys.a, target: ys.b, isPartial: false)
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
        let c = TextGeometryCache(key: k, text: TextViewGeometry.string(of: v))
        caches[side] = c
        return c
    }
}

/// 1 つのテキストビューの段落・行の開始位置（文字列・幅・文字サイズが同じ間は使い回す）
struct TextGeometryCache {
    struct Key: Equatable {
        var revision: Int
        var length: Int
        var width: CGFloat
        var fontSize: CGFloat
    }

    var key: Key
    let text: String
    let paragraphStarts: [Int]
    /// 空でない行の開始位置（段落数が合わないときだけ求める）
    private var lineStarts: [Int]?

    init(key: Key, text: String) {
        self.key = key
        self.text = text
        self.paragraphStarts = TextUnits.paragraphStarts(text)
    }

    mutating func lines() -> [Int] {
        if let lineStarts { return lineStarts }
        let l = TextUnits.lineStarts(text)
        lineStarts = l
        return l
    }
}

/// TextKit 1 を使ったテキストビューの座標計算（iOS / macOS 共通の窓口）
@MainActor
enum TextViewGeometry {
    #if canImport(UIKit)
    static func string(of v: UITextView) -> String { v.text ?? "" }
    static func textLength(of v: UITextView) -> Int { v.textStorage.length }
    /// 表示中の文字列が `s` と同じか（UTF-16 単位で比べる）
    static func textEquals(_ s: String, in v: UITextView) -> Bool { v.textStorage.mutableString.isEqual(to: s) }
    static func layoutWidth(of v: UITextView) -> CGFloat { v.textContainer.size.width }
    static func fontSize(of v: UITextView) -> CGFloat { v.font?.pointSize ?? 0 }
    static func scrollOffset(of v: UITextView) -> CGFloat { v.contentOffset.y + v.adjustedContentInset.top }
    static func maxScrollOffset(of v: UITextView) -> CGFloat {
        max(0, v.contentSize.height + v.adjustedContentInset.top + v.adjustedContentInset.bottom - v.bounds.height)
    }
    static func viewportHeight(of v: UITextView) -> CGFloat {
        max(0, v.bounds.height - v.adjustedContentInset.top - v.adjustedContentInset.bottom)
    }
    /// - Returns: 実際に設定した位置
    @discardableResult
    static func setScrollOffset(_ y: CGFloat, of v: UITextView) -> CGFloat {
        let clamped = min(max(y, 0), maxScrollOffset(of: v))
        v.setContentOffset(CGPoint(x: v.contentOffset.x, y: clamped - v.adjustedContentInset.top), animated: false)
        return clamped
    }
    static func contentHeight(of v: UITextView) -> CGFloat { v.contentSize.height }
    static func ensureLayout(of v: UITextView) {
        // 済んでいれば何もしない（スクロールのたびに呼ぶので）。末尾だけ書き換えた場合はそこから先だけレイアウトされる
        guard v.layoutManager.firstUnlaidCharacterIndex() < v.textStorage.length else { return }
        v.layoutManager.ensureLayout(for: v.textContainer)
    }
    static func y(of edge: AlignmentUnits.Edge, in v: UITextView) -> CGFloat {
        let lm = v.layoutManager, n = v.textStorage.length, top = v.textContainerInset.top
        switch edge {
        case .origin: return 0
        case .top(let i): return lineTop(ofCharacterAt: i, layoutManager: lm, textLength: n) + top
        case .bottom(let i): return lineBottom(endingAt: i, layoutManager: lm, textLength: n) + top
        case .end: return contentHeight(of: v)
        }
    }
    #else
    static func string(of v: NSTextView) -> String { v.string }
    static func textLength(of v: NSTextView) -> Int { v.textStorage?.length ?? 0 }
    /// 表示中の文字列が `s` と同じか（UTF-16 単位で比べる）
    static func textEquals(_ s: String, in v: NSTextView) -> Bool { v.textStorage?.mutableString.isEqual(to: s) ?? false }
    static func layoutWidth(of v: NSTextView) -> CGFloat { v.textContainer?.size.width ?? 0 }
    static func fontSize(of v: NSTextView) -> CGFloat { v.font?.pointSize ?? 0 }
    static func scrollOffset(of v: NSTextView) -> CGFloat { v.enclosingScrollView?.contentView.bounds.origin.y ?? 0 }
    static func maxScrollOffset(of v: NSTextView) -> CGFloat {
        guard let sv = v.enclosingScrollView else { return 0 }
        return max(0, contentHeight(of: v) - sv.contentView.bounds.height)
    }
    static func viewportHeight(of v: NSTextView) -> CGFloat { v.enclosingScrollView?.contentView.bounds.height ?? 0 }
    static func ensureLayout(of v: NSTextView) {
        guard let lm = v.layoutManager, let tc = v.textContainer, let storage = v.textStorage else { return }
        // 済んでいれば何もしない（スクロールのたびに呼ぶので）。末尾だけ書き換えた場合はそこから先だけレイアウトされる
        guard lm.firstUnlaidCharacterIndex() < storage.length else { return }
        lm.ensureLayout(for: tc)
    }
    /// クリップビューが許す範囲に収めてからスクロールする。
    /// - Returns: 実際に設定した位置
    @discardableResult
    static func setScrollOffset(_ y: CGFloat, of v: NSTextView) -> CGFloat {
        guard let sv = v.enclosingScrollView else { return y }
        let clip = sv.contentView
        var rect = clip.bounds
        rect.origin.y = y
        let origin = clip.constrainBoundsRect(rect).origin
        clip.scroll(to: origin)
        sv.reflectScrolledClipView(clip)
        return origin.y
    }
    /// 本文の高さ。テキストビューの枠がまだレイアウトに追いついていない場合はレイアウト結果から求める
    static func contentHeight(of v: NSTextView) -> CGFloat {
        guard let lm = v.layoutManager, let tc = v.textContainer else { return v.frame.height }
        let used = lm.usedRect(for: tc).maxY + v.textContainerOrigin.y + v.textContainerInset.height
        return max(v.frame.height, used)
    }
    static func y(of edge: AlignmentUnits.Edge, in v: NSTextView) -> CGFloat {
        guard let lm = v.layoutManager, let storage = v.textStorage else { return 0 }
        let n = storage.length, top = v.textContainerOrigin.y
        switch edge {
        case .origin: return 0
        case .top(let i): return lineTop(ofCharacterAt: i, layoutManager: lm, textLength: n) + top
        case .bottom(let i): return lineBottom(endingAt: i, layoutManager: lm, textLength: n) + top
        case .end: return contentHeight(of: v)
        }
    }
    #endif

    /// 文字を含む行の上端（文字列の末尾以降なら本文の下端）
    private static func lineTop(ofCharacterAt index: Int, layoutManager lm: NSLayoutManager, textLength: Int) -> CGFloat {
        guard textLength > 0 else { return 0 }
        guard index < textLength else { return textBottom(layoutManager: lm, textLength: textLength) }
        let glyph = lm.glyphIndexForCharacter(at: max(index, 0))
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    /// `end` で終わる範囲の最後の文字を含む行の下端
    private static func lineBottom(endingAt end: Int, layoutManager lm: NSLayoutManager, textLength: Int) -> CGFloat {
        guard textLength > 0, end > 0 else { return 0 }
        let glyph = lm.glyphIndexForCharacter(at: min(end, textLength) - 1)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).maxY
    }

    /// 本文の下端（末尾が改行なら、その後の空の行の上端）
    private static func textBottom(layoutManager lm: NSLayoutManager, textLength: Int) -> CGFloat {
        let extra = lm.extraLineFragmentRect
        if extra.height > 0 { return extra.minY }
        let glyph = lm.glyphIndexForCharacter(at: textLength - 1)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).maxY
    }
}

/// テキストビューに書き込む文字の属性（全体の置き換え時に `font` / `textColor` で付くものと同じ）
enum SyncedTextAttributes {
    static func attributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        #if canImport(UIKit)
        return [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: UIColor.label]
        #else
        return [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor]
        #endif
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
        // 既定の部分レイアウトだと未表示部分の高さが推定値になり、連動先の位置がずれる
        v.layoutManager.allowsNonContiguousLayout = false
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
            let storage = v.textStorage
            if let edit = TextTailEdit.make(from: storage.string, to: text) {
                // 共通の先頭部分はそのまま、違う末尾だけ置き換える（ストリーミング中の訳文）。
                // 上のレイアウト・スクロール位置・選択範囲が保たれ、レイアウトし直すのは末尾だけ
                let selection = v.selectedRange
                let attributes = SyncedTextAttributes.attributes(fontSize: fontSize)
                storage.beginEditing()
                storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: attributes))
                storage.endEditing()
                if v.selectedRange != selection, NSMaxRange(selection) <= storage.length { v.selectedRange = selection }
            } else {
                v.text = text
            }
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
            MainActor.assumeIsolated { parent.controller.userDidEdit(parent.side) }
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
        let scroll = SyncScrollView()
        // ツールバー下に潜り込む場合の自動インセットを使わない（スクロール位置の計算をずらさない）
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
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
        context.coordinator.observe(scroll)
        controller.register(v, as: side)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let v = scroll.documentView as? NSTextView, let storage = v.textStorage else { return }
        var changed = false
        // 日本語入力の変換中（未確定文字あり）は書き換えない（変換が壊れる）
        if v.string != text, !v.hasMarkedText() {
            let selection = v.selectedRanges
            let edit = TextTailEdit.make(from: storage.string, to: text)
            let attributes = SyncedTextAttributes.attributes(fontSize: fontSize)
            let newText = text
            let restoreSelection = edit != nil || isEditable
            coordinator.performProgrammaticChange {
                if let edit {
                    // 共通の先頭部分はそのまま、違う末尾だけ置き換える（ストリーミング中の訳文）。
                    // 上のレイアウト・スクロール位置・選択範囲が保たれ、レイアウトし直すのは末尾だけ
                    storage.beginEditing()
                    storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: attributes))
                    storage.endEditing()
                } else {
                    v.string = newText
                }
                if restoreSelection, selection != v.selectedRanges,
                   selection.allSatisfy({ NSMaxRange($0.rangeValue) <= storage.length }) {
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
        private var observers: [NSObjectProtocol] = []
        /// プログラムからの変更中（その間のスクロール位置の変化はユーザー操作ではない）
        private var programmaticDepth = 0
        /// スクロールバーのつまみのドラッグ・トラックパッドなどのライブスクロール中
        private var isLiveScrolling = false
        private var lastOrigin: CGFloat = 0
        private var lastClipSize: CGSize = .zero
        private var lastDocumentHeight: CGFloat = 0
        /// この時間より前のイベントは「いまの操作」とみなさない（非同期の処理中も直前のイベントが残っているため）
        static let userEventWindow: TimeInterval = 0.5

        init(_ parent: SyncedTextView) { self.parent = parent }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        func performProgrammaticChange(_ change: () -> Void) {
            programmaticDepth += 1
            defer { programmaticDepth -= 1 }
            change()
        }

        @MainActor
        func observe(_ scroll: SyncScrollView) {
            let clip = scroll.contentView
            record(clip)
            // ホイール・トラックパッド（慣性を含む）でのスクロール。イベントごとに確実に連動させる
            scroll.onUserScroll = { [weak self] in self?.userDidScroll() }
            let center = NotificationCenter.default
            // queue: nil — 投稿したその場（メインスレッド）で同期的に受ける。
            // .main だと後回しになり、連動中かどうか・どのイベントの最中かを正しく判定できない
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let clip = note.object as? NSClipView else { return }
                    self.clipBoundsDidChange(clip)
                }
            })
            observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.isLiveScrolling = true }
            })
            observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.isLiveScrolling = false }
            })
            // スクロールバーのつまみのドラッグなど、ユーザー操作によるライブスクロール
            observers.append(center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.userDidScroll() }
            })
        }

        /// ユーザー操作で確実にスクロールされた（ホイール・トラックパッド・スクロールバー）
        @MainActor
        func userDidScroll() {
            guard programmaticDepth == 0, !parent.controller.isSyncing else { return }
            parent.controller.didScroll(parent.side)
        }

        @MainActor
        private func record(_ clip: NSClipView) {
            lastOrigin = clip.bounds.origin.y
            lastClipSize = clip.bounds.size
            lastDocumentHeight = clip.documentView?.frame.height ?? 0
        }

        /// 表示位置が変わった（キーボードでのスクロール・カーソル移動やドラッグでの選択に伴う自動スクロールなど）。
        /// ホイール・トラックパッド・スクロールバーは onUserScroll / didLiveScroll で受けるので、ここは補助。
        /// 後から起きる自動の補正（枠の大きさの変化・スクロールバーの出現・文字列の変化に伴う位置の補正）を
        /// ユーザー操作と見誤らないよう、ユーザーの入力の最中に起きたものだけを連動させる。
        @MainActor
        private func clipBoundsDidChange(_ clip: NSClipView) {
            let origin = clip.bounds.origin.y
            let size = clip.bounds.size
            let documentHeight = clip.documentView?.frame.height ?? 0
            defer { record(clip) }
            // 縦の位置が変わっていない（横方向・大きさだけの変化）
            guard origin != lastOrigin else { return }
            // こちらで動かした（連動・文字列の置き換え・文字サイズ変更）、またはこちらで設定した位置の通知
            guard programmaticDepth == 0, !parent.controller.isSyncing,
                  !parent.controller.isProgrammaticOffset(origin, on: parent.side) else { return }
            // ウィンドウの大きさが変わったことによる位置の補正
            guard size == lastClipSize else { return }
            // 文字列が短くなって末尾に合わせ直された（ユーザー操作ではない）
            guard documentHeight >= lastDocumentHeight else { return }
            guard isLiveScrolling || isUserInput(in: clip) else { return }
            parent.controller.didScroll(parent.side)
        }

        /// いま処理中のイベントが、このテキストビューへのキー入力・マウス操作か
        @MainActor
        private func isUserInput(in clip: NSClipView) -> Bool {
            guard let event = NSApp.currentEvent,
                  ProcessInfo.processInfo.systemUptime - event.timestamp < Self.userEventWindow else { return false }
            switch event.type {
            case .keyDown, .leftMouseDown, .leftMouseDragged:
                // キーボードでのスクロール・ドラッグでの選択は、このテキストビューが操作の対象のときだけ
                guard let textView = clip.documentView else { return false }
                return clip.window?.firstResponder === textView
            default:
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let v = notification.object as? NSTextView else { return }
            // ユーザーの入力（プログラムからの書き換えでは通知されない）
            MainActor.assumeIsolated { parent.controller.userDidEdit(parent.side) }
            // 変換中の未確定文字はモデルに渡さない（確定したときにもう一度呼ばれる）
            guard !v.hasMarkedText() else { return }
            parent.text = v.string
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }
    }
}

/// ホイール・トラックパッドのスクロールを（慣性スクロールも含めて）1 イベントずつ知らせる NSScrollView。
/// 境界の変化通知だけでは、長い文書でレイアウトが進んで高さが変わる最中のスクロールを見分けられないため。
/// 連動はキャッシュ済みの位置の対応と二分探索だけなので、イベントごとに呼んでも軽い。
final class SyncScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScroll?()
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
