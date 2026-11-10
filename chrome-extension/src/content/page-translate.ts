import {
  translateStream,
  TranslateCancelled,
  TranslateError,
  type TranslateHandle,
  type TranslateResult,
} from '../core/client';
import { looksLikeLang, letterCount } from '../core/lang-detect';
import { loadSettings, type Settings } from '../core/settings';
import { TRUNCATED_WARNING, type PageState } from '../core/protocol';
import type { HistoryItem } from '../core/pfml3';
import { isOwnNode, ProgressBar } from './ui';

const SKIP_TAGS = new Set([
  'SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'TEXTAREA', 'INPUT', 'SELECT', 'OPTION', 'SVG', 'MATH', 'KBD',
  'SAMP', 'VAR', 'IFRAME', 'CANVAS', 'VIDEO', 'AUDIO', 'OBJECT', 'BUTTON', 'TEMPLATE', 'HEAD', 'META', 'LINK',
]);
/** 「whole」方式で丸ごと置き換えてよい単純な装飾インライン要素 */
const SIMPLE_INLINE = new Set(['B', 'I', 'EM', 'STRONG', 'SPAN', 'SMALL', 'SUB', 'SUP', 'MARK', 'U', 'S', 'ABBR', 'CITE', 'Q', 'FONT', 'TIME', 'DFN']);
const MAX_UNITS = 2000;
const MAX_UNIT_CHARS = 2500;

interface Unit {
  text: string;
  top: number;
  bottom: number;
  order: number;
  apply: (translated: string) => void;
  restore: () => void;
  done: boolean;
  /** 翻訳できずに飛ばした理由 */
  skipped?: 'input' | 'truncated' | 'error';
  translation?: string;
}

function isSkipped(e: Element): boolean {
  if (SKIP_TAGS.has(e.tagName.toUpperCase())) return true;
  if (isOwnNode(e)) return true;
  const he = e as HTMLElement;
  if (he.isContentEditable) return true;
  if (e.getAttribute('translate') === 'no' || e.classList.contains('notranslate')) return true;
  if (e.getAttribute('aria-hidden') === 'true' && !e.textContent) return true;
  return false;
}

function isHidden(e: Element): boolean {
  const anyE = e as Element & { checkVisibility?: (o?: object) => boolean };
  if (typeof anyE.checkVisibility === 'function') {
    return !anyE.checkVisibility({ checkOpacity: false, checkVisibilityCSS: true });
  }
  const cs = getComputedStyle(e);
  return cs.display === 'none' || cs.visibility === 'hidden';
}

function isInlineEl(e: Element): boolean {
  const d = getComputedStyle(e).display;
  return d.startsWith('inline') || d === 'contents' || d === 'ruby' || d === 'ruby-text';
}

function rectOf(nodes: Node[]): { top: number; bottom: number } {
  try {
    const r = document.createRange();
    r.setStartBefore(nodes[0]);
    r.setEndAfter(nodes[nodes.length - 1]);
    const b = r.getBoundingClientRect();
    return { top: b.top, bottom: b.bottom };
  } catch {
    return { top: 0, bottom: 0 };
  }
}

function normalize(t: string): string {
  return t.replace(/\s+/g, ' ').trim();
}

function pad(orig: string, translated: string): string {
  const lead = /^\s*/.exec(orig)![0];
  const trail = /\s*$/.exec(orig)![0];
  return lead + translated + trail;
}

/** 翻訳対象の段落 (ユニット) を文書順に集める。 */
export function collectUnits(targetLang: string, seen: WeakSet<Node>): Unit[] {
  const units: Unit[] = [];
  let order = 0;

  const push = (u: Omit<Unit, 'order' | 'done'>) => {
    if (units.length >= MAX_UNITS) return;
    units.push({ ...u, order: order++, done: false });
  };

  const accept = (text: string): boolean => {
    if (letterCount(text) < 2) return false;
    return !looksLikeLang(text, targetLang);
  };

  const flushRun = (run: Node[]) => {
    if (!run.length) return;
    const hasSeen = run.some((n) => seen.has(n));
    if (hasSeen) return;
    const hasText = run.some((n) => (n.textContent ?? '').trim());
    if (!hasText) return;
    const simple = run.every(
      (n) =>
        n.nodeType === Node.TEXT_NODE ||
        (n.nodeType === Node.ELEMENT_NODE &&
          SIMPLE_INLINE.has((n as Element).tagName.toUpperCase()) &&
          !(n as Element).querySelector('a,code,kbd,img,button,input,svg,br,pre,textarea,select,[translate=no],.notranslate,[contenteditable]')),
    );
    if (simple) {
      const orig = run.map((n) => n.textContent ?? '').join('');
      const text = normalize(orig);
      if (!accept(text) || text.length > MAX_UNIT_CHARS) return;
      run.forEach((n) => seen.add(n));
      const nodes = [...run];
      const { top, bottom } = rectOf(nodes);
      let inserted: Text | null = null;
      push({
        text,
        top,
        bottom,
        apply: (tr) => {
          if (!nodes[0].parentNode) return;
          inserted = document.createTextNode(pad(orig, tr));
          nodes[0].parentNode.insertBefore(inserted, nodes[0]);
          nodes.forEach((n) => n.parentNode?.removeChild(n));
        },
        restore: () => {
          if (!inserted || !inserted.parentNode) return;
          const parent = inserted.parentNode;
          nodes.forEach((n) => parent.insertBefore(n, inserted));
          parent.removeChild(inserted);
          inserted = null;
        },
      });
      return;
    }
    // 方式 2: テキストノード単位 (リンク・コード等の構造を保つ)
    const walk = (n: Node) => {
      if (n.nodeType === Node.TEXT_NODE) {
        const orig = n.nodeValue ?? '';
        const text = normalize(orig);
        if (!accept(text) || text.length > MAX_UNIT_CHARS) return;
        seen.add(n);
        const { top, bottom } = rectOf([n]);
        push({
          text,
          top,
          bottom,
          apply: (tr) => {
            n.nodeValue = pad(orig, tr);
          },
          restore: () => {
            n.nodeValue = orig;
          },
        });
      } else if (n.nodeType === Node.ELEMENT_NODE) {
        const e = n as Element;
        if (isSkipped(e) || isHidden(e)) return;
        e.childNodes.forEach(walk);
      }
    };
    run.forEach((n) => {
      seen.add(n);
      walk(n);
    });
  };

  const visit = (e: Element) => {
    if (units.length >= MAX_UNITS) return;
    let run: Node[] = [];
    const children = Array.from(e.childNodes);
    for (const c of children) {
      if (c.nodeType === Node.TEXT_NODE) {
        run.push(c);
      } else if (c.nodeType === Node.ELEMENT_NODE) {
        const ce = c as Element;
        if (isSkipped(ce) || isHidden(ce)) {
          // スキップ対象で run を区切る (code 等は翻訳しない)
          if (!SKIP_TAGS.has(ce.tagName.toUpperCase()) || isHidden(ce)) {
            flushRun(run);
            run = [];
          } else {
            run.push(ce); // code 等はインラインに埋め込む (翻訳はしない)
          }
          continue;
        }
        if (isInlineEl(ce)) run.push(ce);
        else {
          flushRun(run);
          run = [];
          visit(ce);
        }
      }
    }
    flushRun(run);
  };

  if (document.body) visit(document.body);
  return units;
}

/** 個別のエラー (入力エラー・途中で切れた訳文以外) がこの数だけ続いたら中止する */
const MAX_CONSECUTIVE_FAILURES = 3;
/** 「翻訳対象のテキストが見つかりませんでした」を表示しておく時間 */
const EMPTY_NOTICE_MS = 8000;

type SkipReason = 'input' | 'truncated' | 'error';
const SKIP_LABEL: Record<SkipReason, string> = {
  input: '入力エラー',
  truncated: '長さの上限で途中で切れた',
  error: 'エラー',
};

/** 1 回のページ翻訳の実行。restore / 新しい実行で置き換えられたら古い実行は黙って終わる */
interface Run {
  cancelled: boolean;
}

export class PageTranslator {
  private units: Unit[] = [];
  private seen = new WeakSet<Node>();
  private mode: PageState['mode'] = 'idle';
  private done = 0;
  private error: string | undefined;
  /** エラーで中止したとき、再試行で続きを翻訳できるか */
  private retryable = false;
  private notice: string | undefined;
  private noticeTimer: ReturnType<typeof setTimeout> | undefined;
  private run: Run | null = null;
  private current: TranslateHandle | null = null;
  private bar: ProgressBar | null = null;
  private applied: Unit[] = [];
  private skips: Record<SkipReason, number> = { input: 0, truncated: 0, error: 0 };
  private lastSkipMessage: string | undefined;

  private get skipped(): number {
    return this.skips.input + this.skips.truncated + this.skips.error;
  }

  getState(): PageState {
    return {
      mode: this.mode,
      done: this.done,
      total: this.units.length,
      ...(this.skipped ? { skipped: this.skipped } : {}),
      error: this.error ?? this.notice,
    };
  }

  private emit(): void {
    const state = this.getState();
    chrome.runtime.sendMessage({ type: 'page-state', state }).catch(() => {});
    this.renderBar();
  }

  private ensureBar(): ProgressBar {
    if (!this.bar) {
      this.bar = new ProgressBar({
        onStop: () => this.cancel(),
        onRestore: () => this.restore(),
        onRetry: () => void this.retry(),
        onClose: () => this.closeBar(),
      });
    }
    return this.bar;
  }

  private closeBar(): void {
    clearTimeout(this.noticeTimer);
    this.bar?.remove();
    this.bar = null;
  }

  private renderBar(): void {
    if (!this.bar) return;
    const total = this.units.length;
    const skipNote = this.skipped ? `（${this.skipped} 段落をスキップ）` : '';
    const skipTitle = this.skipped
      ? (Object.keys(this.skips) as SkipReason[])
          .filter((k) => this.skips[k])
          .map((k) => `${SKIP_LABEL[k]}: ${this.skips[k]} 段落`)
          .concat(this.lastSkipMessage ? [`最後のエラー: ${this.lastSkipMessage}`] : [])
          .join('\n')
      : '';
    const canRestore = this.applied.length > 0;
    if (this.mode === 'translating') {
      this.bar.render({ text: `翻訳中 ${this.done}/${total}${skipNote}`, title: skipTitle, stop: true, restore: canRestore });
    } else if (this.error) {
      this.bar.render({
        text: `エラー: ${this.error}`,
        title: [this.error, skipTitle].filter(Boolean).join('\n'),
        error: true,
        retry: this.retryable,
        restore: canRestore,
        close: true,
      });
    } else if (this.notice) {
      this.bar.render({ text: this.notice, close: true });
    } else {
      this.bar.render({ text: `翻訳済み ${this.done}/${total}${skipNote}`, title: skipTitle, restore: canRestore, close: true });
    }
  }

  /** 新しい実行を始める (古い実行は置き換えられて黙って終わる) */
  private beginRun(): Run {
    if (this.run) this.run.cancelled = true;
    const run: Run = { cancelled: false };
    this.run = run;
    this.mode = 'translating';
    this.error = undefined;
    this.retryable = false;
    this.notice = undefined;
    clearTimeout(this.noticeTimer);
    return run;
  }

  async start(): Promise<void> {
    if (this.mode === 'translating') return;
    // 翻訳済みの部分があれば一度原文に戻してからやり直す (戻せなくなるのを防ぐ)
    if (this.applied.length) this.restore();
    const run = this.beginRun();
    this.units = [];
    this.done = 0;
    this.applied = [];
    this.skips = { input: 0, truncated: 0, error: 0 };
    this.lastSkipMessage = undefined;
    this.closeBar();
    let s: Settings;
    try {
      s = await loadSettings();
    } catch (e) {
      if (run !== this.run) return;
      return this.finish(run, (e as Error).message);
    }
    if (run !== this.run) return;
    this.seen = new WeakSet();
    this.units = collectUnits(s.targetLang, this.seen);
    if (!this.units.length) {
      this.run = null;
      this.mode = 'idle';
      this.notice = '翻訳対象のテキストが見つかりませんでした';
      this.ensureBar();
      this.emit();
      this.noticeTimer = setTimeout(() => {
        if (this.notice && this.mode === 'idle') this.closeBar();
      }, EMPTY_NOTICE_MS);
      return;
    }
    this.ensureBar();
    await this.translateUnits(run, s, this.units);
  }

  /** エラーで中止したあと、まだ翻訳していない段落 (と個別のエラーで飛ばした段落) を翻訳する */
  async retry(): Promise<void> {
    if (this.mode === 'translating') return;
    const run = this.beginRun();
    this.skips.error = 0;
    let s: Settings;
    try {
      s = await loadSettings();
    } catch (e) {
      if (run !== this.run) return;
      return this.finish(run, (e as Error).message);
    }
    if (run !== this.run) return;
    for (const u of this.units) if (u.skipped === 'error') u.skipped = undefined;
    const rest = this.units.filter((u) => !u.done && !u.skipped);
    this.ensureBar();
    await this.translateUnits(run, s, rest);
  }

  private skip(u: Unit, reason: SkipReason, message: string): void {
    u.skipped = reason;
    this.skips[reason]++;
    this.lastSkipMessage = message;
  }

  private async translateUnits(run: Run, s: Settings, list: Unit[]): Promise<void> {
    this.emit();
    // 表示領域内を先に、その後は画面に近い順
    const vh = window.innerHeight;
    const rank = (u: Unit) => {
      if (u.bottom > 0 && u.top < vh) return [0, u.top];
      if (u.top >= vh) return [1, u.top - vh];
      return [2, -u.bottom];
    };
    const queue = [...list].sort((a, b) => {
      const ra = rank(a);
      const rb = rank(b);
      return ra[0] - rb[0] || ra[1] - rb[1] || a.order - b.order;
    });

    const nHist = s.historyParagraphs;
    let failures = 0;
    let fatal: string | undefined;
    for (const u of queue) {
      if (run.cancelled) break;
      const history: HistoryItem[] = [];
      if (nHist > 0) {
        for (let i = u.order - 1; i >= 0 && history.length < nHist; i--) {
          const p = this.units[i];
          if (p.done && p.translation) history.unshift({ source: p.text, translation: p.translation });
          else break;
        }
        const total = history.reduce((a, h) => a + h.source.length + h.translation.length, 0);
        if (total > 1500) history.length = 0;
      }
      const h = translateStream({ text: u.text, history });
      this.current = h;
      let r: TranslateResult;
      try {
        r = await h.promise;
      } catch (e) {
        if (run !== this.run) return; // 原文に戻された / 新しい実行に置き換えられた
        if (e instanceof TranslateCancelled || run.cancelled) break;
        const kind = e instanceof TranslateError ? e.kind : 'other';
        const msg = (e as Error).message;
        // 接続できない・どのリクエストも失敗する → 中止
        if (kind === 'unreachable' || kind === 'fatal') {
          fatal = msg;
          break;
        }
        // その段落だけの問題 → 飛ばして続ける。個別のエラーが続くなら中止
        this.skip(u, kind === 'input' ? 'input' : 'error', msg);
        if (kind !== 'input' && ++failures >= MAX_CONSECUTIVE_FAILURES) {
          fatal = `${msg}（${failures} 段落続けて失敗したため中止しました）`;
          break;
        }
        this.emit();
        continue;
      } finally {
        if (this.current === h) this.current = null;
      }
      if (run !== this.run) return;
      if (run.cancelled) break;
      failures = 0;
      if (r.truncated) {
        // 途中までの訳文はページに適用せず、history にも使わない
        this.skip(u, 'truncated', TRUNCATED_WARNING);
        this.emit();
        continue;
      }
      if (r.text) {
        u.apply(r.text);
        u.translation = r.text;
        this.applied.push(u);
      }
      u.done = true;
      this.done++;
      this.emit();
    }
    this.finish(run, fatal);
  }

  private finish(run: Run, error?: string): void {
    if (run !== this.run) return;
    this.run = null;
    this.current = null;
    this.mode = this.applied.length ? 'translated' : 'idle';
    this.error = error;
    this.retryable = !!error && this.units.some((u) => !u.done && u.skipped !== 'input' && u.skipped !== 'truncated');
    if (error) this.ensureBar();
    if (!error && !this.applied.length && !this.skipped) {
      // 何も翻訳しないまま停止した
      this.closeBar();
    }
    this.emit();
  }

  cancel(): void {
    if (this.run) this.run.cancelled = true;
    this.current?.cancel();
  }

  restore(): void {
    if (this.run) this.run.cancelled = true;
    this.run = null;
    this.current?.cancel();
    this.current = null;
    for (const u of [...this.applied].reverse()) u.restore();
    for (const u of this.units) {
      u.done = false;
      u.skipped = undefined;
      u.translation = undefined;
    }
    this.applied = [];
    this.mode = 'idle';
    this.done = 0;
    this.skips = { input: 0, truncated: 0, error: 0 };
    this.lastSkipMessage = undefined;
    this.error = undefined;
    this.retryable = false;
    this.notice = undefined;
    this.closeBar();
    this.emit();
  }

  async toggle(): Promise<void> {
    if (this.mode === 'translating') this.cancel();
    else if (this.mode === 'translated') this.restore();
    else await this.start();
  }
}
