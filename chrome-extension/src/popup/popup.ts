import { TARGET_LANGUAGES, LANGUAGES, formatBytes } from '../core/catalog';
import { loadSettings, saveSettings, type Settings } from '../core/settings';
import { translateStream, getEngineStatus, TranslateCancelled, type TranslateHandle } from '../core/client';
import { detectLanguage, smartTarget, langJa } from '../core/detect';
import type { EngineStatus, PageState, RuntimeMessage } from '../core/protocol';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const sourceSel = $<HTMLSelectElement>('sourceLang');
const targetSel = $<HTMLSelectElement>('targetLang');
const input = $<HTMLTextAreaElement>('input');
const output = $('output');
const meta = $('meta');
const translateBtn = $<HTMLButtonElement>('translate');
const stopBtn = $<HTMLButtonElement>('stop');
const copyBtn = $<HTMLButtonElement>('copy');
const countEl = $('count');
const clearBtn = $<HTMLButtonElement>('clear');
const formRow = $('formRow');
const statusRow = $('statusRow');
const statusText = $('statusText');
const progressWrap = $('progressWrap');
const progressBar = $('progressBar');
const pageBtn = $<HTMLButtonElement>('pageTranslate');
const pageRestoreBtn = $<HTMLButtonElement>('pageRestore');
const pageStateEl = $('pageState');

let settings: Settings;
let handle: TranslateHandle | null = null;
let lastResult = '';

function fillSelect(sel: HTMLSelectElement, items: { code: string; ja: string }[], withAuto: boolean) {
  sel.textContent = '';
  if (withAuto) sel.add(new Option('言語を検出', 'auto'));
  for (const l of items) sel.add(new Option(`${l.ja} (${l.code})`, l.code));
}

function formValue(): Settings['form'] {
  const r = document.querySelector<HTMLInputElement>('input[name="form"]:checked');
  return (r?.value as Settings['form']) ?? 'none';
}

function updateFormRow() {
  formRow.hidden = targetSel.value !== 'ja';
}

function setOutput(text: string, kind: 'empty' | 'ok' | 'err' = 'ok') {
  output.textContent = text;
  output.className = 'output' + (kind === 'ok' ? '' : ` ${kind}`);
  copyBtn.disabled = kind !== 'ok' || !text;
}

function renderStatus(st: EngineStatus) {
  statusRow.dataset.state = st.state;
  const backend = st.backend === 'wasm' ? 'ブラウザ内 (WASM)' : 'ローカルサーバー';
  let text = `${backend}`;
  if (st.modelLabel) text += ` · ${st.modelLabel}`;
  if (st.state === 'downloading' && st.total) {
    const pct = Math.floor(((st.loaded ?? 0) / st.total) * 100);
    text += ` — ダウンロード中 ${pct}% (${formatBytes(st.loaded ?? 0)} / ${formatBytes(st.total)})`;
    progressWrap.hidden = false;
    progressBar.style.width = `${pct}%`;
  } else {
    progressWrap.hidden = true;
    if (st.state === 'loading') text += ' — モデルを読み込み中…';
    else if (st.state === 'ready') text += ' — 準備完了';
    else if (st.message) text += ` — ${st.message}`;
  }
  statusText.textContent = text;
  statusText.title = st.message ?? '';
}

async function refreshStatus() {
  try {
    renderStatus(await getEngineStatus());
  } catch (e) {
    statusRow.dataset.state = 'error';
    statusText.textContent = '状態を取得できません';
  }
}

function setBusy(busy: boolean) {
  stopBtn.hidden = !busy;
}

let debounce: ReturnType<typeof setTimeout> | undefined;
let runSeq = 0;
const autoOpt = () => sourceSel.options[0];

function onInputChanged() {
  countEl.textContent = `${input.value.length.toLocaleString()} 文字`;
  clearBtn.hidden = !input.value;
  clearTimeout(debounce);
  handle?.cancel();
  if (!input.value.trim()) {
    autoOpt().text = '言語を検出';
    setOutput('翻訳結果がここに表示されます', 'empty');
    meta.textContent = '';
    lastResult = '';
    setBusy(false);
    return;
  }
  if (settings.liveTranslate) debounce = setTimeout(() => void doTranslate(), 500);
}

async function persistLangs() {
  settings = await saveSettings({ sourceLang: sourceSel.value, targetLang: targetSel.value, form: formValue() });
}

async function doTranslate() {
  const text = input.value;
  clearTimeout(debounce);
  if (!text.trim()) {
    setOutput('テキストを入力してください', 'empty');
    return;
  }
  const seq = ++runSeq;
  handle?.cancel();
  setBusy(true);
  meta.textContent = '言語を検出中…';

  let source = sourceSel.value;
  let target = targetSel.value;
  if (source === 'auto') {
    const det = await detectLanguage(text);
    if (seq !== runSeq) return;
    autoOpt().text = det.guess ? `${langJa(det.guess)}（検出）` : '言語を検出';
    // 信頼できる検出結果のときだけモデルに翻訳元を渡す
    source = det.code ?? 'auto';
    const nt = smartTarget(det.code, target);
    if (nt !== target) {
      target = nt;
      targetSel.value = nt;
      updateFormRow();
    }
  }
  meta.textContent = '';
  setOutput('準備中…', 'empty');
  const t0 = Date.now();
  const h = translateStream(
    { text, sourceLang: source, targetLang: target, form: target === 'ja' ? formValue() : 'none' },
    {
      onPhase: (p) => {
        if (p === 'queued') meta.textContent = '順番待ち…';
        else if (p === 'preparing') meta.textContent = '準備中 (初回はモデル読み込みに時間がかかります)';
        else meta.textContent = '翻訳中…';
      },
      onChunk: (t) => {
        if (seq !== runSeq) return;
        if (t) setOutput(t);
        lastResult = t;
      },
    },
  );
  handle = h;
  try {
    const r = await h.promise;
    if (seq !== runSeq) return;
    lastResult = r.text;
    setOutput(r.text || '(翻訳結果が空でした)', r.text ? 'ok' : 'empty');
    meta.textContent = `${((Date.now() - t0) / 1000).toFixed(1)} 秒`;
  } catch (e) {
    if (seq !== runSeq) return;
    if (e instanceof TranslateCancelled) {
      meta.textContent = '停止しました';
    } else {
      setOutput((e as Error).message, 'err');
      meta.textContent = '';
    }
  } finally {
    if (seq === runSeq) {
      handle = null;
      setBusy(false);
      void refreshStatus();
    }
  }
}

async function activeTabId(): Promise<number | undefined> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab?.id;
}

async function sendPage(action: 'start' | 'restore' | 'cancel' | 'toggle' | 'state'): Promise<PageState | null> {
  const id = await activeTabId();
  if (id === undefined) return null;
  try {
    return (await chrome.tabs.sendMessage(id, { type: 'page-translate', action } satisfies RuntimeMessage)) as PageState;
  } catch {
    return null;
  }
}

function renderPage(st: PageState | null) {
  if (!st) {
    pageStateEl.textContent = 'このページでは使えません';
    pageBtn.disabled = true;
    pageRestoreBtn.hidden = true;
    return;
  }
  pageBtn.disabled = false;
  if (st.mode === 'translating') {
    pageBtn.textContent = '停止';
    pageStateEl.textContent = `${st.done}/${st.total}`;
    pageRestoreBtn.hidden = false;
  } else if (st.mode === 'translated') {
    pageBtn.textContent = 'もう一度翻訳';
    pageStateEl.textContent = `翻訳済み ${st.done}/${st.total}`;
    pageRestoreBtn.hidden = false;
  } else {
    pageBtn.textContent = 'このページを翻訳';
    pageStateEl.textContent = st.error ?? '';
    pageRestoreBtn.hidden = true;
  }
}

async function init() {
  settings = await loadSettings();
  fillSelect(sourceSel, LANGUAGES, true);
  fillSelect(targetSel, TARGET_LANGUAGES, false);
  sourceSel.value = settings.sourceLang;
  targetSel.value = settings.targetLang;
  const r = document.querySelector<HTMLInputElement>(`input[name="form"][value="${settings.form}"]`);
  if (r) r.checked = true;
  updateFormRow();

  targetSel.addEventListener('change', () => {
    updateFormRow();
    void persistLangs();
  });
  sourceSel.addEventListener('change', () => void persistLangs());
  document.querySelectorAll('input[name="form"]').forEach((e) => e.addEventListener('change', () => void persistLangs()));

  $('swap').addEventListener('click', () => {
    const s = sourceSel.value;
    const t = targetSel.value;
    // 自動検出のときは、現在の翻訳先を翻訳元にして翻訳先を英語/日本語にする
    const newTarget = s === 'auto' ? (t === 'ja' ? 'en' : 'ja') : s;
    if (![...targetSel.options].some((o) => o.value === newTarget)) return;
    sourceSel.value = [...sourceSel.options].some((o) => o.value === t) ? t : 'auto';
    targetSel.value = newTarget;
    if (lastResult) {
      input.value = lastResult;
      lastResult = '';
      onInputChanged();
    }
    updateFormRow();
    void persistLangs();
  });

  translateBtn.addEventListener('click', () => void doTranslate());
  stopBtn.addEventListener('click', () => {
    runSeq++;
    clearTimeout(debounce);
    handle?.cancel();
    setBusy(false);
    meta.textContent = '停止しました';
  });
  input.addEventListener('input', onInputChanged);
  clearBtn.addEventListener('click', () => {
    input.value = '';
    onInputChanged();
    input.focus();
  });
  const rerun = () => {
    if (input.value.trim() && settings.liveTranslate) void doTranslate();
  };
  targetSel.addEventListener('change', rerun);
  sourceSel.addEventListener('change', rerun);
  document.querySelectorAll('input[name="form"]').forEach((e) => e.addEventListener('change', rerun));
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      void doTranslate();
    }
  });
  copyBtn.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(lastResult);
      copyBtn.textContent = 'コピーしました';
    } catch {
      copyBtn.textContent = 'コピー失敗';
    }
    setTimeout(() => (copyBtn.textContent = 'コピー'), 1500);
  });
  $('openOptions').addEventListener('click', () => {
    chrome.runtime.openOptionsPage();
    window.close();
  });

  pageBtn.addEventListener('click', async () => {
    const cur = await sendPage('state');
    if (cur?.mode === 'translating') renderPage(await sendPage('cancel'));
    else {
      if (cur?.mode === 'translated') await sendPage('restore');
      renderPage(await sendPage('start'));
    }
  });
  pageRestoreBtn.addEventListener('click', async () => renderPage(await sendPage('restore')));
  chrome.runtime.onMessage.addListener((msg: RuntimeMessage) => {
    if (msg.type === 'engine-status' && msg.status.backend === settings.backend) renderStatus(msg.status);
    else if (msg.type === 'page-state') renderPage(msg.state);
  });

  // ページで選択中のテキストがあれば入力欄に入れる
  try {
    const id = await activeTabId();
    if (id !== undefined) {
      const sel = (await chrome.tabs.sendMessage(id, { type: 'get-selection' } satisfies RuntimeMessage)) as string;
      if (sel && sel.trim()) {
        input.value = sel.trim();
        onInputChanged();
      }
    }
  } catch {
    /* content script なし */
  }
  input.focus();
  onInputChanged();
  renderPage(await sendPage('state'));
  void refreshStatus();
}

void init();
