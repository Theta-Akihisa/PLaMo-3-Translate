import { translateStream, type TranslateHandle, TranslateCancelled } from '../core/client';
import { looksLikeLang, letterCount } from '../core/lang-detect';
import { loadSettings } from '../core/settings';
import type { PageState } from '../core/protocol';
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

export class PageTranslator {
  private units: Unit[] = [];
  private seen = new WeakSet<Node>();
  private mode: PageState['mode'] = 'idle';
  private done = 0;
  private error: string | undefined;
  private cancelled = false;
  private current: TranslateHandle | null = null;
  private bar: ProgressBar | null = null;
  private applied: Unit[] = [];

  getState(): PageState {
    return { mode: this.mode, done: this.done, total: this.units.length, error: this.error };
  }

  private emit(): void {
    const state = this.getState();
    chrome.runtime.sendMessage({ type: 'page-state', state }).catch(() => {});
    if (this.bar && (this.mode === 'translating' || this.mode === 'translated')) {
      this.bar.update(this.mode, this.done, this.units.length, this.error ? `エラー: ${this.error.slice(0, 40)}` : undefined);
    }
  }

  async start(): Promise<void> {
    if (this.mode === 'translating') return;
    const s = await loadSettings();
    this.cancelled = false;
    this.error = undefined;
    this.seen = new WeakSet();
    this.units = collectUnits(s.targetLang, this.seen);
    this.done = 0;
    this.applied = [];
    if (!this.units.length) {
      this.mode = 'idle';
      this.error = '翻訳対象のテキストが見つかりませんでした';
      this.emit();
      return;
    }
    this.mode = 'translating';
    this.bar?.remove();
    this.bar = new ProgressBar({ onStop: () => this.cancel(), onRestore: () => this.restore() });
    this.emit();

    // 表示領域内を先に、その後は画面に近い順
    const vh = window.innerHeight;
    const rank = (u: Unit) => {
      if (u.bottom > 0 && u.top < vh) return [0, u.top];
      if (u.top >= vh) return [1, u.top - vh];
      return [2, -u.bottom];
    };
    const queue = [...this.units].sort((a, b) => {
      const ra = rank(a);
      const rb = rank(b);
      return ra[0] - rb[0] || ra[1] - rb[1] || a.order - b.order;
    });

    const nHist = s.historyParagraphs;
    for (const u of queue) {
      if (this.cancelled) break;
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
      try {
        this.current = translateStream({ text: u.text, history });
        const r = await this.current.promise;
        if (this.cancelled) break;
        if (r.text) {
          u.apply(r.text);
          u.translation = r.text;
          this.applied.push(u);
        }
        u.done = true;
        this.done++;
        this.emit();
      } catch (e) {
        if (e instanceof TranslateCancelled || this.cancelled) break;
        this.error = (e as Error).message;
        break;
      } finally {
        this.current = null;
      }
    }
    this.mode = this.applied.length ? 'translated' : 'idle';
    if (!this.applied.length && !this.error) this.bar?.remove();
    this.emit();
    if (this.mode === 'idle') {
      this.bar?.remove();
      this.bar = null;
    }
  }

  cancel(): void {
    this.cancelled = true;
    this.current?.cancel();
  }

  restore(): void {
    this.cancel();
    for (const u of [...this.applied].reverse()) u.restore();
    this.applied = [];
    this.mode = 'idle';
    this.done = 0;
    this.error = undefined;
    this.bar?.remove();
    this.bar = null;
    this.emit();
  }

  async toggle(): Promise<void> {
    if (this.mode === 'idle') await this.start();
    else if (this.mode === 'translating') this.cancel();
    else this.restore();
  }
}
