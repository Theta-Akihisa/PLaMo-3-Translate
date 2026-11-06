import { translateStream, type TranslateHandle, TranslateCancelled } from '../core/client';
import { loadSettings } from '../core/settings';
import { langLabel } from '../core/catalog';
import type { RuntimeMessage } from '../core/protocol';
import { Panel } from './ui';
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
    return a.value.slice(a.selectionStart, a.selectionEnd);
  }
  return '';
}

async function translateSelection(textArg?: string): Promise<void> {
  const text = (textArg && textArg.trim() ? textArg : currentSelectionText()).trim();
  if (!text) return;
  current?.cancel();
  panel?.close();
  const s = await loadSettings();
  let latest = '';
  const p = new Panel(
    {
      onClose: () => {
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
    },
    selectionAnchor(),
  );
  panel = p;
  p.setLang(langLabel(s.targetLang));
  p.setPlaceholder('準備中…');
  const h = translateStream(
    { text },
    {
      onPhase: (ph) => {
        if (ph === 'queued') p.setStatus('順番待ち…');
        else if (ph === 'preparing') p.setStatus('準備中 (初回はモデルの読み込みに時間がかかります)');
        else p.setStatus('翻訳中…');
      },
      onChunk: (t) => {
        latest = t;
        if (t) p.setText(t);
      },
    },
  );
  current = h;
  try {
    const r = await h.promise;
    latest = r.text;
    p.setText(r.text || '(翻訳結果が空でした)');
    p.setStatus(`完了 (${(r.ms / 1000).toFixed(1)} 秒)`);
  } catch (e) {
    if (e instanceof TranslateCancelled) return;
    p.setError((e as Error).message);
    p.setStatus('');
  } finally {
    if (current === h) current = null;
  }
}

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
