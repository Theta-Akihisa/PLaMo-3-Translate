import { translateStream, type TranslateHandle, TranslateCancelled } from '../core/client';
import { loadSettings, onSettingsChanged } from '../core/settings';
import { TARGET_LANGUAGES } from '../core/catalog';
import { detectLanguage, smartTarget } from '../core/detect';
import type { RuntimeMessage } from '../core/protocol';
import { Panel, SelectionIcon, isOwnNode } from './ui';
import { PageTranslator } from './page-translate';

let panel: Panel | null = null;
let current: TranslateHandle | null = null;
let lastPointer = { x: 40, y: 40 };
const page = new PageTranslator();

document.addEventListener(
  'mouseup',
  (e) => {
    lastPointer = { x: e.clientX, y: e.clientY };
  },
  true,
);
document.addEventListener(
  'contextmenu',
  (e) => {
    lastPointer = { x: e.clientX, y: e.clientY };
  },
  true,
);

function selectionAnchor(): { x: number; y: number; w: number; h: number } {
  const sel = window.getSelection();
  if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
    const r = sel.getRangeAt(0).getBoundingClientRect();
    if (r.width > 0 || r.height > 0) return { x: r.left, y: r.top, w: r.width, h: r.height };
  }
  return { x: lastPointer.x, y: lastPointer.y, w: 0, h: 0 };
}

function currentSelectionText(): string {
  const sel = window.getSelection()?.toString() ?? '';
  if (sel.trim()) return sel;
  const a = document.activeElement as HTMLInputElement | HTMLTextAreaElement | null;
  if (a && typeof a.selectionStart === 'number' && a.selectionStart !== a.selectionEnd) {
    return a.value.slice(a.selectionStart, a.selectionEnd ?? undefined);
  }
  return '';
}

type Replacer = (text: string) => void;

function makeReplacer(): Replacer | undefined {
  const a = document.activeElement as HTMLInputElement | HTMLTextAreaElement | null;
  if (a && (a.tagName === 'TEXTAREA' || a.tagName === 'INPUT') && typeof a.selectionStart === 'number' && a.selectionStart !== a.selectionEnd && !a.readOnly && !a.disabled) {
    const start = a.selectionStart;
    const end = a.selectionEnd as number;
    return (text) => {
      a.focus();
      a.setRangeText(text, start, end, 'select');
      a.dispatchEvent(new Event('input', { bubbles: true }));
    };
  }
  const sel = window.getSelection();
  if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
    const node = sel.anchorNode instanceof Element ? sel.anchorNode : sel.anchorNode?.parentElement;
    if (node && (node as HTMLElement).isContentEditable) {
      const range = sel.getRangeAt(0).cloneRange();
      return (text) => {
        const s2 = window.getSelection();
        s2?.removeAllRanges();
        s2?.addRange(range);
        document.execCommand('insertText', false, text);
      };
    }
  }
  return undefined;
}

async function translateSelection(textArg?: string): Promise<void> {
  const text = (textArg && textArg.trim() ? textArg : currentSelectionText()).trim();
  if (!text) return;
  current?.cancel();
  panel?.close();
  icon?.hide();
  const s = await loadSettings();
  const replacer = makeReplacer();
  const anchor = selectionAnchor();
  let latest = '';
  let target = s.targetLang;
  let form = s.form;
  let seq = 0;
  let p: Panel;

  const run = async () => {
    const my = ++seq;
    current?.cancel();
    p.setPlaceholder('言語を検出中…');
    let source = s.sourceLang;
    let tgt = target;
    if (source === 'auto') {
      const det = await detectLanguage(text);
      if (my !== seq) return;
      source = det.code ?? 'auto';
      const nt = smartTarget(det.code, tgt);
      if (nt !== tgt && !userPickedTarget) {
        tgt = nt;
        target = nt;
        p.setTarget(nt);
      }
    }
    p.setPlaceholder('準備中…');
    const h = translateStream(
      { text, sourceLang: source, targetLang: tgt, form: tgt === 'ja' ? (form as 'plain' | 'polite' | 'none') : 'none' },
      {
        onPhase: (ph) => {
          if (my !== seq) return;
          if (ph === 'queued') p.setStatus('順番待ち…');
          else if (ph === 'preparing') p.setStatus('準備中 (初回はモデルの読み込みに時間がかかります)');
          else p.setStatus('翻訳中…');
        },
        onChunk: (t) => {
          if (my !== seq) return;
          latest = t;
          if (t) p.setText(t);
        },
      },
    );
    current = h;
    try {
      const r = await h.promise;
      if (my !== seq) return;
      latest = r.text;
      p.setText(r.text || '(翻訳結果が空でした)');
      p.setStatus(`完了 (${(r.ms / 1000).toFixed(1)} 秒)`);
    } catch (e) {
      if (e instanceof TranslateCancelled || my !== seq) return;
      p.setError((e as Error).message);
      p.setStatus('');
    } finally {
      if (current === h) current = null;
    }
  };

  let userPickedTarget = false;
  p = new Panel(
    {
      onClose: () => {
        seq++;
        current?.cancel();
        current = null;
        if (panel === p) panel = null;
      },
      onCopy: async () => {
        try {
          await navigator.clipboard.writeText(latest);
          return true;
        } catch {
          const ta = document.createElement('textarea');
          ta.value = latest;
          document.body.appendChild(ta);
          ta.select();
          const ok = document.execCommand('copy');
          ta.remove();
          return ok;
        }
      },
      onReplace: replacer ? () => latest && replacer(latest) : undefined,
      onChange: (t, f) => {
        userPickedTarget = true;
        target = t;
        form = f as typeof form;
        void run();
      },
    },
    anchor,
    { target, form, langs: TARGET_LANGUAGES },
  );
  panel = p;
  await run();
}

// ---------------------------------------------------------------- 選択アイコン (DeepL 風)

let icon: SelectionIcon | null = null;
let iconEnabled = true;
loadSettings().then((s) => (iconEnabled = s.showSelectionIcon));
onSettingsChanged((s) => {
  iconEnabled = s.showSelectionIcon;
  if (!iconEnabled) icon?.hide();
});

function updateIcon(e?: MouseEvent): void {
  if (!iconEnabled) return;
  if (e && isOwnNode(e.target as Node)) return;
  const text = currentSelectionText().trim();
  if (!text || !/\p{L}/u.test(text)) {
    icon?.hide();
    return;
  }
  if (!icon) icon = new SelectionIcon(() => void translateSelection());
  const a = selectionAnchor();
  const useRect = a.w > 0 || a.h > 0;
  icon.show(useRect ? a.x + a.w + 4 : (e?.clientX ?? a.x) + 8, useRect ? a.y + a.h + 4 : (e?.clientY ?? a.y) + 8);
}

document.addEventListener('mouseup', (e) => setTimeout(() => updateIcon(e), 10), true);
document.addEventListener('keyup', (e) => {
  if (e.shiftKey || e.key === 'Shift') updateIcon();
}, true);
document.addEventListener('mousedown', (e) => {
  if (!isOwnNode(e.target as Node)) icon?.hide();
}, true);
document.addEventListener('scroll', () => icon?.hide(), true);

chrome.runtime.onMessage.addListener((msg: RuntimeMessage, _sender, sendResponse) => {
  switch (msg?.type) {
    case 'get-selection':
      sendResponse(currentSelectionText());
      return false;
    case 'translate-selection':
      void translateSelection(msg.text);
      return false;
    case 'page-translate':
      if (msg.action === 'state') {
        sendResponse(page.getState());
        return false;
      }
      if (msg.action === 'start') void page.start();
      else if (msg.action === 'cancel') page.cancel();
      else if (msg.action === 'restore') page.restore();
      else if (msg.action === 'toggle') void page.toggle();
      sendResponse(page.getState());
      return false;
    default:
      return false;
  }
});
