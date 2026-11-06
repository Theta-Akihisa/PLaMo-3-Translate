/** ページ内 UI (Shadow DOM)。ページの CSS が漏れ込まないよう、すべて shadow 内に描画する。 */

const CSS = `
.sel-icon { position: fixed; z-index: 2147483647; width: 26px; height: 26px; display: none; place-items: center; padding: 0;
  border-radius: 8px; border: 1px solid #d5dae2; background: #fff; color: #2f6fed; font: 700 14px/1 system-ui, sans-serif;
  box-shadow: 0 2px 8px rgba(0,0,0,.22); cursor: pointer; }
.sel-icon:hover { background: #eef3ff; }
button.primary { background:#2f6fed; color:#fff; border-color:transparent; }
button.primary:hover { background:#2459c4; }
select { font: inherit; font-size: 12px; border:1px solid #cbd1d9; border-radius:7px; background:#f6f7f9; color:inherit; padding: 2px 4px; max-width: 150px; }

:host { all: initial; }
* { box-sizing: border-box; }
.panel {
  position: fixed; z-index: 2147483647; width: min(420px, calc(100vw - 24px));
  max-height: min(60vh, 480px); display: flex; flex-direction: column;
  background: #ffffff; color: #1d1d1f; border: 1px solid #d0d4da; border-radius: 12px;
  box-shadow: 0 8px 28px rgba(0,0,0,.22); font: 14px/1.6 -apple-system, "Hiragino Sans", "Noto Sans JP", "Yu Gothic UI", system-ui, sans-serif;
}
.head { display:flex; align-items:center; gap:8px; padding: 8px 10px 6px 12px; border-bottom: 1px solid #eceff3; font-size: 12px; color:#5b6472; }
.head .title { font-weight: 700; color:#1d1d1f; }
.head .lang { margin-left: 2px; }
.head .sp { flex:1; }
.body { padding: 10px 12px; overflow:auto; white-space: pre-wrap; word-break: break-word; min-height: 2.4em; }
.body.err { color:#b3261e; }
.body.dim { color:#6b7280; }
.foot { display:flex; align-items:center; gap:8px; padding: 6px 10px 8px; border-top: 1px solid #eceff3; font-size:12px; color:#6b7280; }
.foot .sp { flex:1; }
button { font: inherit; font-size: 12px; cursor:pointer; border:1px solid #cbd1d9; background:#f6f7f9; color:#1d1d1f; border-radius:7px; padding: 3px 10px; }
button:hover { background:#eaecf0; }
button.x { border:none; background:transparent; font-size:16px; line-height:1; padding:2px 6px; }
.bar { position: fixed; z-index: 2147483646; right: 16px; bottom: 16px; display:flex; align-items:center; gap:10px;
  background:#1d1d1f; color:#fff; padding: 8px 12px; border-radius: 999px; font: 13px/1.4 -apple-system, "Hiragino Sans", "Noto Sans JP", system-ui, sans-serif;
  box-shadow: 0 4px 16px rgba(0,0,0,.3); }
.bar button { background:#3a3a3d; color:#fff; border-color:#55555a; }
.bar button:hover { background:#4a4a4f; }
.bar .prog { min-width: 5em; font-variant-numeric: tabular-nums; }
@media (prefers-color-scheme: dark) {
  .sel-icon { background:#2b2e33; border-color:#454950; color:#8fb0ff; } .sel-icon:hover { background:#363a40; }
  select { background:#2b2e33; border-color:#454950; }
  .panel { background:#1f2124; color:#ececf0; border-color:#3a3d42; }
  .head { border-color:#32353a; color:#9aa3b0; } .head .title { color:#ececf0; }
  .foot { border-color:#32353a; color:#9aa3b0; }
  button { background:#2b2e33; color:#ececf0; border-color:#454950; } button:hover { background:#363a40; }
  .body.dim { color:#9aa3b0; } .body.err { color:#ff8a80; }
  .bar { background:#f1f1f4; color:#1d1d1f; } .bar button { background:#e0e0e6; color:#1d1d1f; border-color:#c6c6cf; }
}
`;

let root: ShadowRoot | null = null;

export function getRoot(): ShadowRoot {
  if (root) return root;
  const host = document.createElement('div');
  host.setAttribute('data-plamo-translate', '');
  host.style.cssText = 'all: initial; position: static;';
  root = host.attachShadow({ mode: 'open' });
  const st = document.createElement('style');
  st.textContent = CSS;
  root.appendChild(st);
  (document.documentElement || document.body).appendChild(host);
  hostEl = host;
  return root;
}

let hostEl: HTMLElement | null = null;
export function isOwnNode(n: Node | null): boolean {
  return !!hostEl && !!n && (n === hostEl || hostEl.contains(n));
}

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  cls?: string,
  text?: string,
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

export interface PanelHandlers {
  onClose: () => void;
  onCopy: () => Promise<boolean> | boolean;
  onReplace?: () => void;
  onChange: (target: string, form: string) => void;
}

export class Panel {
  private box = el('div', 'panel');
  private body = el('div', 'body dim', '準備中…');
  private foot = el('span', '', '');
  private copyBtn = el('button', '', 'コピー');
  private replaceBtn = el('button', 'primary', '置き換え');
  private targetSel = el('select');
  private formSel = el('select');
  private closed = false;
  private keyHandler: (e: KeyboardEvent) => void;

  constructor(
    private h: PanelHandlers,
    anchor: { x: number; y: number; w: number; h: number },
    opts: { target: string; form: string; langs: { code: string; ja: string }[] },
  ) {
    const head = el('div', 'head');
    for (const l of opts.langs) this.targetSel.add(new Option(l.ja, l.code));
    this.targetSel.value = opts.target;
    this.targetSel.setAttribute('aria-label', '翻訳先の言語');
    for (const [v, t] of [['none', '文体: 自動'], ['plain', '常体'], ['polite', '敬体']]) this.formSel.add(new Option(t, v));
    this.formSel.value = opts.form;
    this.formSel.setAttribute('aria-label', '文体');
    const fire = () => this.h.onChange(this.targetSel.value, this.formSel.value);
    this.targetSel.addEventListener('change', () => {
      this.formSel.style.display = this.targetSel.value === 'ja' ? '' : 'none';
      fire();
    });
    this.formSel.addEventListener('change', fire);
    this.formSel.style.display = opts.target === 'ja' ? '' : 'none';
    const x = el('button', 'x', '×');
    x.title = '閉じる (Esc)';
    x.addEventListener('click', () => this.close());
    head.append(el('span', 'title', 'PLaMo'), this.targetSel, this.formSel, el('span', 'sp'), x);
    const foot = el('div', 'foot');
    this.copyBtn.addEventListener('click', async () => {
      const ok = await this.h.onCopy();
      this.copyBtn.textContent = ok ? 'コピーしました' : 'コピー失敗';
      setTimeout(() => (this.copyBtn.textContent = 'コピー'), 1500);
    });
    foot.append(this.foot, el('span', 'sp'));
    if (this.h.onReplace) {
      this.replaceBtn.addEventListener('click', () => {
        this.h.onReplace?.();
        this.close();
      });
      foot.append(this.replaceBtn);
    }
    foot.append(this.copyBtn);
    this.box.append(head, this.body, foot);
    getRoot().appendChild(this.box);
    this.place(anchor);
    this.keyHandler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') this.close();
    };
    document.addEventListener('keydown', this.keyHandler, true);
  }

  private place(a: { x: number; y: number; w: number; h: number }): void {
    const margin = 8;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const width = Math.min(420, vw - 24);
    const left = Math.min(Math.max(12, a.x), vw - width - 12);
    let top = a.y + a.h + margin;
    const approxH = 200;
    if (top + approxH > vh && a.y - approxH - margin > 0) top = a.y - approxH - margin;
    top = Math.min(Math.max(12, top), Math.max(12, vh - 140));
    this.box.style.left = `${left}px`;
    this.box.style.top = `${top}px`;
  }

  contains(n: Node | null): boolean {
    return !!n && this.box.contains(n);
  }
  setStatus(t: string): void {
    this.foot.textContent = t;
  }
  setText(t: string): void {
    this.body.className = 'body';
    this.body.textContent = t;
  }
  setPlaceholder(t: string): void {
    this.body.className = 'body dim';
    this.body.textContent = t;
  }
  setError(t: string): void {
    this.body.className = 'body err';
    this.body.textContent = t;
  }
  setTarget(code: string): void {
    this.targetSel.value = code;
    this.formSel.style.display = code === 'ja' ? '' : 'none';
  }
  close(): void {
    if (this.closed) return;
    this.closed = true;
    document.removeEventListener('keydown', this.keyHandler, true);
    this.box.remove();
    this.h.onClose();
  }
}

/** 選択テキストの横に出る小さな翻訳アイコン (DeepL 風) */
export class SelectionIcon {
  private btn = el('button', 'sel-icon');
  constructor(onClick: () => void) {
    this.btn.title = 'PLaMoで翻訳';
    this.btn.setAttribute('aria-label', 'PLaMoで翻訳');
    this.btn.textContent = 'P';
    this.btn.style.display = 'none';
    // 選択を壊さない
    this.btn.addEventListener('mousedown', (e) => e.preventDefault());
    this.btn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      onClick();
    });
    getRoot().appendChild(this.btn);
  }
  show(x: number, y: number): void {
    const left = Math.min(Math.max(4, x), window.innerWidth - 32);
    const top = Math.min(Math.max(4, y), window.innerHeight - 32);
    this.btn.style.left = `${left}px`;
    this.btn.style.top = `${top}px`;
    this.btn.style.display = 'grid';
  }
  hide(): void {
    this.btn.style.display = 'none';
  }
  contains(n: Node | null): boolean {
    return !!n && this.btn === n;
  }
}

export class ProgressBar {
  private bar = el('div', 'bar');
  private prog = el('span', 'prog', '');
  private stop = el('button', '', '翻訳を停止');
  private restore = el('button', '', '原文に戻す');
  constructor(handlers: { onStop: () => void; onRestore: () => void }) {
    this.stop.addEventListener('click', handlers.onStop);
    this.restore.addEventListener('click', handlers.onRestore);
    this.bar.append(el('span', '', 'PLaMo'), this.prog, this.stop, this.restore);
    getRoot().appendChild(this.bar);
  }
  update(mode: 'translating' | 'translated', done: number, total: number, note?: string): void {
    this.prog.textContent = note ?? (mode === 'translating' ? `翻訳中 ${done}/${total}` : `翻訳済み ${done}/${total}`);
    this.stop.style.display = mode === 'translating' ? '' : 'none';
  }
  remove(): void {
    this.bar.remove();
  }
}
