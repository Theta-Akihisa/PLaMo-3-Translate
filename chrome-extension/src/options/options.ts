import { CacheManager } from '@wllama/wllama';
import {
  MODELS, LANGUAGES, TARGET_LANGUAGES, WASM_SIZES, getModel, formatBytes, type SizeId,
} from '../core/catalog';
import { DEFAULT_SETTINGS, loadSettings, saveSettings, type Settings } from '../core/settings';
import type { AppModel, AppModelsResult, AppSelectResult, EngineStatus, RuntimeMessage } from '../core/protocol';
import { statusSummary } from '../core/status-view';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
let s: Settings;
let savedTimer: ReturnType<typeof setTimeout> | undefined;

async function save(patch: Partial<Settings>) {
  s = await saveSettings(patch);
  $('saved').textContent = '保存しました';
  clearTimeout(savedTimer);
  savedTimer = setTimeout(() => ($('saved').textContent = ''), 1500);
  syncVisibility();
}

function fill(sel: HTMLSelectElement, items: { value: string; text: string }[]) {
  sel.textContent = '';
  for (const i of items) sel.add(new Option(i.text, i.value));
}

function syncVisibility() {
  $('appBox').hidden = s.backend !== 'app';
  $('serverBox').hidden = s.backend !== 'server';
  $('wasmBox').hidden = s.backend !== 'wasm';
  if (s.backend === 'wasm') ($('advBackend') as HTMLDetailsElement).open = true;
  $('appModelsBox').hidden = s.backend !== 'app';
  $('localModelsBox').hidden = s.backend === 'app';
  $('serverSizeHint').hidden = s.backend !== 'server';
  const note = $('wasmNote');
  note.textContent =
    '現在同梱の wllama 3.8.1 (llama.cpp) は PLaMo 3 のトークナイザに未対応のため、モデルの読み込みに失敗します。' +
    'wllama が対応するまでは macOS アプリを使用してください。';
  const m = getModel(s.modelSize);
  $('sizeNote').textContent =
    `${m.description} / 必要メモリの目安 ${m.minRamGB}GB 以上。` +
    (WASM_SIZES.includes(s.modelSize)
      ? ''
      : ' 8B はブラウザ内 (WASM) では実行できません (WebAssembly のメモリ上限と ArrayBuffer 2GB 制限のため)。');
  const q = $<HTMLSelectElement>('quant');
  fill(q, m.files.map((f) => ({ value: f.quant, text: `${f.quant} (${formatBytes(f.sizeBytes)})` })));
  q.value = m.files.some((f) => f.quant === s.quant) ? s.quant : m.defaultQuant;
}

function renderGlossary() {
  const box = $('glossary');
  box.textContent = '';
  s.glossary.forEach((g, i) => {
    const row = document.createElement('div');
    row.className = 'gl-row';
    const a = document.createElement('input');
    a.placeholder = '原語';
    a.value = g.source;
    const b = document.createElement('input');
    b.placeholder = '訳語';
    b.value = g.target;
    const del = document.createElement('button');
    del.textContent = '削除';
    const commit = () => {
      const next = s.glossary.map((x, j) => (j === i ? { source: a.value, target: b.value } : x));
      void save({ glossary: next });
    };
    a.addEventListener('change', commit);
    b.addEventListener('change', commit);
    del.addEventListener('click', async () => {
      await save({ glossary: s.glossary.filter((_, j) => j !== i) });
      renderGlossary();
    });
    row.append(a, b, del);
    box.append(row);
  });
}

async function renderCache() {
  const box = $('cacheList');
  box.textContent = '';
  try {
    const list = await new CacheManager().list();
    if (!list.length) {
      box.innerHTML = '<div class="empty">ダウンロード済みのモデルはありません</div>';
      return;
    }
    for (const e of list) {
      const row = document.createElement('div');
      row.className = 'item';
      const name = document.createElement('span');
      name.textContent = e.metadata?.originalURL?.split('/').pop() ?? e.name;
      const size = document.createElement('span');
      size.textContent = formatBytes(e.size);
      const del = document.createElement('button');
      del.textContent = '削除';
      del.addEventListener('click', async () => {
        await new CacheManager().delete(e.name);
        void renderCache();
      });
      row.append(name, size, del);
      box.append(row);
    }
  } catch (err) {
    box.textContent = `キャッシュを読み取れません: ${(err as Error).message}`;
  }
}

// ---------------------------------------------------------------- macOS アプリ (はじめに / 状態 / モデル)

type TestResult = { ok: boolean; message: string; status?: EngineStatus };
let appStatus: EngineStatus | null = null;
let launching = false;

function setStep(id: string, state: 'pending' | 'current' | 'done') {
  $(id).dataset.step = state;
}

function renderApp(st: EngineStatus) {
  appStatus = st;
  const v = statusSummary(st);
  for (const [box, text] of [
    ['welcomeStatus', 'welcomeStatusText'],
    ['appStatus', 'appStatusText'],
  ] as const) {
    $(box).dataset.state = st.state;
    $(text).textContent = v.text;
    $(text).title = [st.message, st.endpoint].filter(Boolean).join('\n');
  }
  $('appStatusHint').textContent = v.hint ?? '';
  const launchBtn = $<HTMLButtonElement>('appLaunch');
  launchBtn.hidden = !v.canLaunch;
  for (const b of [launchBtn, $<HTMLButtonElement>('welcomeLaunch')]) {
    b.disabled = !!st.launching;
    b.textContent = st.launching ? '起動を待っています…' : 'アプリを起動';
  }
  $('welcomeLaunch').hidden = !v.canLaunch;
  const reached = st.state === 'ready' || st.state === 'loading' || st.state === 'no_model';
  setStep('step1', reached ? 'done' : 'current');
  setStep('step2', st.state === 'ready' || st.state === 'loading' ? 'done' : reached ? 'current' : 'pending');
  setStep('step3', st.state === 'ready' ? 'done' : st.state === 'loading' ? 'current' : 'pending');
  if (reached) void loadAppModels();
  else renderModels(null);
}

let modelsKey = '';
function renderModels(models: AppModel[] | null, message?: string) {
  const box = $('appModelList');
  const key = JSON.stringify(models) + (message ?? '');
  if (key === modelsKey) return;
  modelsKey = key;
  box.textContent = '';
  if (!models || !models.length) {
    const d = document.createElement('div');
    d.className = 'empty';
    d.textContent = message ?? 'macOS アプリに接続するとモデルの一覧が表示されます';
    box.append(d);
    return;
  }
  for (const m of models) {
    const row = document.createElement('div');
    row.className = 'm';
    row.dataset.size = m.size;
    row.dataset.installed = String(m.installed);
    const label = document.createElement('label');
    const r = document.createElement('input');
    r.type = 'radio';
    r.name = 'appModel';
    r.value = m.id;
    r.checked = m.active;
    r.disabled = !m.installed;
    r.addEventListener('change', () => r.checked && void selectAppModel(m.id));
    const name = document.createElement('b');
    name.textContent = m.label;
    const cat = MODELS.find((x) => x.size === m.size);
    const info = document.createElement('small');
    info.textContent = [m.quant, m.sizeBytes ? formatBytes(m.sizeBytes) : '', cat ? `${cat.description}` : '']
      .filter(Boolean)
      .join(' · ');
    label.append(r, name, info);
    const badge = document.createElement('span');
    badge.className = 'badge' + (m.active ? ' active' : '');
    badge.textContent = m.active ? (m.installed ? '使用中' : '選択中 (未ダウンロード)') : m.installed ? 'ダウンロード済み' : '未ダウンロード';
    row.append(label, badge);
    if (!m.installed) {
      const dl = document.createElement('button');
      dl.className = 'download';
      dl.textContent = 'アプリでダウンロード';
      dl.title = 'macOS アプリを開きます。「モデル」画面でダウンロードしてください';
      dl.addEventListener('click', () => void launchApp());
      row.append(dl);
    }
    box.append(row);
  }
}

async function loadAppModels() {
  const r = (await chrome.runtime.sendMessage({ type: 'appModels' } satisfies RuntimeMessage)) as AppModelsResult;
  renderModels(r.ok ? r.models : null, r.ok ? undefined : r.message);
}

let selectMsgTimer: ReturnType<typeof setTimeout> | undefined;
async function selectAppModel(id: string) {
  const out = $('appModelResult');
  out.className = 'result';
  out.textContent = 'モデルを切り替え中…';
  const r = (await chrome.runtime.sendMessage({ type: 'appSelectModel', id } satisfies RuntimeMessage)) as AppSelectResult;
  out.className = `result ${r.ok ? 'ok' : 'err'}`;
  out.textContent = r.ok ? `切り替えました（${r.status?.modelLabel ?? id}）` : r.message;
  clearTimeout(selectMsgTimer);
  selectMsgTimer = setTimeout(() => (out.textContent = ''), 4000);
  modelsKey = '';
  if (r.status) renderApp(r.status);
  else void pollApp();
}

async function testApp(endpoint?: string): Promise<TestResult> {
  return (await chrome.runtime.sendMessage({ type: 'testConnection', backend: 'app', endpoint } satisfies RuntimeMessage)) as TestResult;
}

async function pollApp() {
  if (launching) return;
  const r = await testApp();
  if (r.status && !launching) renderApp(r.status);
}

async function launchApp() {
  launching = true;
  if (appStatus) renderApp({ ...appStatus, launching: true });
  try {
    const st = (await chrome.runtime.sendMessage({ type: 'launchApp' } satisfies RuntimeMessage)) as EngineStatus;
    launching = false;
    renderApp(st);
  } finally {
    launching = false;
  }
}

async function init() {
  s = await loadSettings();
  fill($('modelSize') as HTMLSelectElement, MODELS.map((m) => ({ value: m.size, text: `${m.label}${m.default ? ' (既定)' : ''}` })));
  fill($('targetLang') as HTMLSelectElement, TARGET_LANGUAGES.map((l) => ({ value: l.code, text: `${l.ja} (${l.code})` })));
  fill($('sourceLang') as HTMLSelectElement, [{ value: 'auto', text: '言語を検出' }, ...LANGUAGES.map((l) => ({ value: l.code, text: `${l.ja} (${l.code})` }))]);

  document.querySelectorAll<HTMLInputElement>('input[name="backend"]').forEach((r) => {
    r.checked = r.value === s.backend;
    r.addEventListener('change', () => r.checked && void save({ backend: r.value as Settings['backend'] }));
  });
  const bind = <K extends keyof Settings>(id: string, key: K, conv: (v: string) => Settings[K]) => {
    const e = $<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>(id);
    e.value = String(s[key]);
    e.addEventListener('change', () => void save({ [key]: conv(e.value) } as Partial<Settings>));
  };
  bind('modelSize', 'modelSize', (v) => v as SizeId);
  $('modelSize').addEventListener('change', () => {
    const m = getModel(($('modelSize') as HTMLSelectElement).value as SizeId);
    void save({ quant: m.defaultQuant });
  });
  bind('endpoint', 'endpoint', (v) => v.trim());
  bind('appEndpoint', 'appEndpoint', (v) => v.trim());
  $('appEndpoint').addEventListener('change', () => void pollApp());
  bind('targetLang', 'targetLang', (v) => v);
  bind('sourceLang', 'sourceLang', (v) => v);
  bind('form', 'form', (v) => v as Settings['form']);
  bind('maxTokens', 'maxTokens', (v) => Math.max(16, Math.min(8192, Number(v) || DEFAULT_SETTINGS.maxTokens)));
  bind('context', 'context', (v) => v);
  bind('modelUrlOverride', 'modelUrlOverride', (v) => v.trim());
  bind('wasmThreads', 'wasmThreads', (v) => Math.max(0, Number(v) || 0));
  bind('historyParagraphs', 'historyParagraphs', (v) => Number(v));
  $('quant').addEventListener('change', () => void save({ quant: ($('quant') as HTMLSelectElement).value }));
  for (const k of ['showSelectionIcon', 'liveTranslate'] as const) {
    const c = $<HTMLInputElement>(k);
    c.checked = s[k];
    c.addEventListener('change', () => void save({ [k]: c.checked } as Partial<Settings>));
  }

  $('addTerm').addEventListener('click', async () => {
    await save({ glossary: [...s.glossary, { source: '', target: '' }] });
    renderGlossary();
  });

  $('testConn').addEventListener('click', async () => {
    const out = $('connResult');
    out.className = 'result';
    out.textContent = '接続中…';
    const ep = ($('endpoint') as HTMLInputElement).value;
    const r = (await chrome.runtime.sendMessage({ type: 'testConnection', backend: 'server', endpoint: ep } satisfies RuntimeMessage)) as TestResult;
    out.className = `result ${r.ok ? 'ok' : 'err'}`;
    out.textContent = r.message;
  });
  const appTest = async (outId: string) => {
    const out = $(outId);
    out.className = out.className.includes('inline') ? 'result inline' : 'result';
    out.textContent = '接続中…';
    const r = await testApp(($('appEndpoint') as HTMLInputElement).value);
    out.className = `${out.className} ${r.ok ? 'ok' : 'err'}`;
    out.textContent = r.message;
    if (r.status) renderApp(r.status);
  };
  $('appTestConn').addEventListener('click', () => void appTest('appConnResult'));
  $('welcomeTest').addEventListener('click', () => void appTest('welcomeResult'));
  $('appLaunch').addEventListener('click', () => void launchApp());
  $('welcomeLaunch').addEventListener('click', () => void launchApp());
  chrome.runtime.onMessage.addListener((m: RuntimeMessage) => {
    if (m.type === 'engine-status' && m.status.backend === 'app') renderApp(m.status);
  });

  $('prepare').addEventListener('click', async () => {
    const out = $('prepResult');
    out.className = 'result inline';
    out.textContent = '準備中…';
    const r = (await chrome.runtime.sendMessage({ type: 'prepare' } satisfies RuntimeMessage)) as { ok: boolean; message: string };
    out.className = `result inline ${r.ok ? 'ok' : 'err'}`;
    out.textContent = r.message;
    $('prepProgress').hidden = true;
    void renderCache();
  });
  chrome.runtime.onMessage.addListener((m: RuntimeMessage) => {
    if (m.type !== 'engine-status') return;
    const st: EngineStatus = m.status;
    const bar = $('prepProgress');
    if (st.state === 'downloading' && st.total) {
      bar.hidden = false;
      const pct = ((st.loaded ?? 0) / st.total) * 100;
      (bar.firstElementChild as HTMLElement).style.width = `${pct}%`;
      $('prepResult').textContent = `ダウンロード中 ${pct.toFixed(0)}% (${formatBytes(st.loaded ?? 0)} / ${formatBytes(st.total)})`;
    }
  });
  $('refreshCache').addEventListener('click', () => void renderCache());
  $('clearCache').addEventListener('click', async () => {
    if (!confirm('ダウンロード済みのモデルをすべて削除しますか？')) return;
    await new CacheManager().clear();
    void renderCache();
  });
  $('resetAll').addEventListener('click', async () => {
    if (!confirm('設定を初期化しますか？')) return;
    await chrome.storage.local.remove('settings');
    location.reload();
  });

  syncVisibility();
  renderGlossary();
  void renderCache();

  // はじめに: 初回インストール時 (#welcome) と、まだ一度も macOS アプリに接続できていないときは開いておく
  const welcome = $('welcome') as HTMLDetailsElement;
  const first = location.hash === '#welcome';
  const ever = !!(await chrome.storage.local.get('appEverConnected')).appEverConnected;
  welcome.open = first || !ever;
  if (first) {
    welcome.classList.add('first');
    welcome.scrollIntoView();
  }
  await pollApp();
  setInterval(() => {
    if (document.visibilityState === 'visible') void pollApp();
  }, 3000);
}

void init();
