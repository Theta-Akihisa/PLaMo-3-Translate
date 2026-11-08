import { endpointOf, loadSettings, type Settings } from '../core/settings';
import { cleanOutput, Pfml3Error } from '../core/pfml3';
import { promptFor } from '../core/util';
import { getModel, getModelFile, WASM_SIZES, type SizeId } from '../core/catalog';
import {
  PORT_ENGINE_PREFIX,
  PORT_TRANSLATE,
  type ClientToSw,
  type AppModelsResult,
  type AppSelectResult,
  type EngineStatus,
  type ModelSpec,
  type OffscreenToSw,
  type RuntimeMessage,
  type SwToClient,
  type SwToOffscreen,
  type TranslateRequest,
} from '../core/protocol';
import {
  APP_LAUNCH_URL,
  checkHealth,
  listAppModels,
  modelLabelOf,
  selectAppModel,
  serverComplete,
  type HealthResult,
} from '../engine/local-server';

// ---------------------------------------------------------------- queue
// エンジンは 1 つなのでジョブは直列化する。

interface Job {
  id: string;
  req: TranslateRequest;
  ctl: AbortController;
  send: (m: SwToClient) => void;
  started: boolean;
}

const pending: Job[] = [];
let running = false;

function enqueue(job: Job): void {
  pending.push(job);
  if (running || pending.length > 1) job.send({ op: 'phase', id: job.id, phase: 'queued' });
  void pump();
}

function cancelJob(id: string, jobs: Job[]): void {
  const job = jobs.find((j) => j.id === id);
  if (!job) return;
  job.ctl.abort();
  const i = pending.indexOf(job);
  if (i >= 0) {
    pending.splice(i, 1);
    job.send({ op: 'error', id, message: 'キャンセルしました', cancelled: true });
  }
}

async function pump(): Promise<void> {
  if (running) return;
  running = true;
  try {
    while (pending.length) {
      const job = pending.shift()!;
      if (job.ctl.signal.aborted) {
        job.send({ op: 'error', id: job.id, message: 'キャンセルしました', cancelled: true });
        continue;
      }
      job.started = true;
      const t0 = Date.now();
      try {
        const s = await loadSettings();
        const prompt = promptFor(job.req, s);
        job.send({ op: 'phase', id: job.id, phase: 'preparing' });
        let first = true;
        const onText = (acc: string) => {
          if (first) {
            first = false;
            job.send({ op: 'phase', id: job.id, phase: 'generating' });
          }
          job.send({ op: 'chunk', id: job.id, text: cleanOutput(acc) });
        };
        const raw =
          s.backend === 'app' || s.backend === 'server'
            ? await serverComplete({
                kind: s.backend,
                endpoint: endpointOf(s),
                prompt,
                maxTokens: s.maxTokens,
                signal: job.ctl.signal,
                onText,
              })
            : await wasmComplete(s, prompt, job.ctl.signal, onText);
        job.send({ op: 'done', id: job.id, text: cleanOutput(raw), ms: Date.now() - t0 });
      } catch (e) {
        const err = e as Error;
        const cancelled = job.ctl.signal.aborted || err?.name === 'AbortError';
        job.send({
          op: 'error',
          id: job.id,
          cancelled,
          message: cancelled
            ? 'キャンセルしました'
            : err instanceof Pfml3Error
              ? `入力エラー: ${err.message}`
              : err?.message || String(e),
        });
      }
    }
  } finally {
    running = false;
  }
}

// ---------------------------------------------------------------- wasm (offscreen)

let creatingOffscreen: Promise<void> | null = null;

async function hasOffscreen(): Promise<boolean> {
  const ctxs = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT' as chrome.runtime.ContextType] });
  return ctxs.length > 0;
}

async function ensureOffscreen(): Promise<void> {
  if (await hasOffscreen()) return;
  if (!creatingOffscreen) {
    creatingOffscreen = chrome.offscreen
      .createDocument({
        url: 'offscreen.html',
        reasons: ['WORKERS' as chrome.offscreen.Reason],
        justification: 'WebAssembly (wllama) で翻訳モデルを実行するため',
      })
      .finally(() => {
        creatingOffscreen = null;
      });
  }
  await creatingOffscreen;
}

function modelSpec(s: Settings): ModelSpec {
  const size: SizeId = s.modelSize;
  if (!WASM_SIZES.includes(size)) {
    throw new Error(
      `${getModel(size).label} モデルはブラウザ内 (WASM) では実行できません (メモリ/ArrayBuffer 2GB の制限)。macOS アプリを使用してください`,
    );
  }
  const f = getModelFile(size, s.quant);
  return {
    size,
    quant: f.quant,
    url: s.modelUrlOverride.trim() || f.url,
    sizeBytes: f.sizeBytes,
    label: `${getModel(size).label} ${f.quant}`,
  };
}

let jobCounter = 0;

async function withOffscreenPort<T>(
  signal: AbortSignal,
  handler: (port: chrome.runtime.Port, finish: (v: T) => void, fail: (e: Error) => void) => void,
): Promise<T> {
  await ensureOffscreen();
  const port = chrome.runtime.connect({ name: PORT_ENGINE_PREFIX + ++jobCounter });
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const finish = (v: T) => {
      if (settled) return;
      settled = true;
      try {
        port.disconnect();
      } catch {
        /* ignore */
      }
      resolve(v);
    };
    const fail = (e: Error) => {
      if (settled) return;
      settled = true;
      try {
        port.disconnect();
      } catch {
        /* ignore */
      }
      reject(e);
    };
    port.onDisconnect.addListener(() => fail(new Error('エンジンとの接続が切れました')));
    signal.addEventListener('abort', () => {
      try {
        port.postMessage({ op: 'cancel' } satisfies SwToOffscreen);
      } catch {
        /* ignore */
      }
      const e = new Error('cancelled');
      e.name = 'AbortError';
      fail(e);
    });
    handler(port, finish, fail);
  });
}

async function wasmComplete(
  s: Settings,
  prompt: string,
  signal: AbortSignal,
  onText: (acc: string) => void,
): Promise<string> {
  const model = modelSpec(s);
  return withOffscreenPort<string>(signal, (port, finish, fail) => {
    port.onMessage.addListener((m: OffscreenToSw) => {
      if (m.op === 'chunk') onText(m.text);
      else if (m.op === 'done') finish(m.text);
      else if (m.op === 'error') fail(new Error(m.message));
    });
    port.postMessage({
      op: 'run',
      prompt,
      maxTokens: s.maxTokens,
      model,
      threads: s.wasmThreads,
    } satisfies SwToOffscreen);
  });
}

async function wasmPrepare(s: Settings): Promise<void> {
  const model = modelSpec(s);
  await withOffscreenPort<void>(new AbortController().signal, (port, finish, fail) => {
    port.onMessage.addListener((m: OffscreenToSw) => {
      if (m.op === 'done') finish();
      else if (m.op === 'error') fail(new Error(m.message));
    });
    port.postMessage({ op: 'prepare', model, threads: s.wasmThreads } satisfies SwToOffscreen);
  });
}

// ---------------------------------------------------------------- app / server status

const EVER_KEY = 'appEverConnected';

async function everConnected(): Promise<boolean> {
  return !!(await chrome.storage.local.get(EVER_KEY))[EVER_KEY];
}

function healthToStatus(s: Settings, h: HealthResult, ever: boolean): EngineStatus {
  const backend = s.backend === 'server' ? 'server' : 'app';
  const endpoint = endpointOf(s);
  const state: EngineStatus['state'] =
    h.state === 'ok'
      ? 'ready'
      : h.state === 'loading'
        ? 'loading'
        : h.state === 'no_model'
          ? 'no_model'
          : h.state === 'unreachable'
            ? 'not_running'
            : 'error';
  const modelLabel =
    backend === 'app' ? modelLabelOf(h.model) || undefined : `${getModel(s.modelSize).label} (${endpoint})`;
  return { backend, state, message: h.message, modelLabel, endpoint, everConnected: ever, appVersion: h.version };
}

async function httpStatus(s: Settings, timeoutMs = 2500): Promise<EngineStatus> {
  const kind = s.backend === 'server' ? 'server' : 'app';
  const h = await checkHealth(kind, endpointOf(s), timeoutMs);
  let ever = kind === 'app' ? await everConnected() : true;
  if (kind === 'app' && !ever && (h.state === 'ok' || h.state === 'loading' || h.state === 'no_model')) {
    ever = true;
    await chrome.storage.local.set({ [EVER_KEY]: true });
  }
  return healthToStatus(s, h, ever);
}

function broadcastStatus(status: EngineStatus): void {
  chrome.runtime.sendMessage({ type: 'engine-status', status } satisfies RuntimeMessage).catch(() => {});
}

/** アクティブなタブで plamotranslate://open を開く (外部プロトコルなのでページ自体は遷移しない)。タブが無ければ新規タブ */
async function openAppUrl(): Promise<void> {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (tab?.id !== undefined) await chrome.tabs.update(tab.id, { url: APP_LAUNCH_URL });
  else await chrome.tabs.create({ url: APP_LAUNCH_URL });
}

const LAUNCH_POLL_MS = 15000;
let launching: Promise<EngineStatus> | null = null;

/** macOS アプリを起動し、/health を最大 15 秒ポーリングする。途中経過は engine-status で通知 */
function launchApp(): Promise<EngineStatus> {
  if (launching) return launching;
  launching = (async () => {
    await openAppUrl();
    const deadline = Date.now() + LAUNCH_POLL_MS;
    let st: EngineStatus;
    for (;;) {
      const s = await loadSettings();
      st = await httpStatus({ ...s, backend: 'app' }, 1500);
      if (st.state !== 'not_running') break;
      if (Date.now() >= deadline) break;
      broadcastStatus({ ...st, launching: true, message: 'macOS アプリの起動を待っています…' });
      await new Promise((r) => setTimeout(r, 1000));
    }
    if (st.state === 'not_running') {
      st = {
        ...st,
        message:
          'macOS アプリを起動できませんでした。「PLaMo Translate」がインストールされているか確認し、手動で起動してください',
      };
    }
    broadcastStatus(st);
    return st;
  })().finally(() => {
    launching = null;
  });
  return launching;
}

async function appModels(): Promise<AppModelsResult> {
  const s = await loadSettings();
  try {
    return { ok: true, models: await listAppModels(s.appEndpoint) };
  } catch (e) {
    return { ok: false, models: [], message: (e as Error).message };
  }
}

async function appSelect(id: string): Promise<AppSelectResult> {
  const s = await loadSettings();
  try {
    const h = await selectAppModel(s.appEndpoint, id);
    const status = healthToStatus({ ...s, backend: 'app' }, h, true);
    broadcastStatus(status);
    return { ok: true, message: h.message, status };
  } catch (e) {
    return { ok: false, message: (e as Error).message };
  }
}

async function getStatus(): Promise<EngineStatus> {
  const s = await loadSettings();
  if (s.backend === 'app' || s.backend === 'server') return httpStatus(s);
  let label = '';
  try {
    label = modelSpec(s).label;
  } catch (e) {
    return { backend: 'wasm', state: 'error', message: (e as Error).message };
  }
  if (await hasOffscreen()) {
    try {
      const st = (await chrome.runtime.sendMessage({ type: 'offscreen-status' })) as EngineStatus | undefined;
      if (st) return { ...st, modelLabel: st.modelLabel ?? label };
    } catch {
      /* fallthrough */
    }
  }
  return {
    backend: 'wasm',
    state: 'idle',
    modelLabel: label,
    message: '初回の翻訳時にモデルをダウンロードして読み込みます',
  };
}

// ---------------------------------------------------------------- messaging

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== PORT_TRANSLATE) return;
  const jobs: Job[] = [];
  const send = (m: SwToClient) => {
    try {
      port.postMessage(m);
    } catch {
      /* closed */
    }
  };
  port.onMessage.addListener((m: ClientToSw) => {
    if (m.op === 'start') {
      const job: Job = { id: m.id, req: m.req, ctl: new AbortController(), send, started: false };
      jobs.push(job);
      enqueue(job);
    } else if (m.op === 'cancel') {
      cancelJob(m.id, jobs);
    }
  });
  port.onDisconnect.addListener(() => {
    for (const j of jobs) cancelJob(j.id, jobs);
  });
});

chrome.runtime.onMessage.addListener((msg: RuntimeMessage, _sender, sendResponse) => {
  switch (msg?.type) {
    case 'getStatus':
      getStatus().then(sendResponse);
      return true;
    case 'prepare':
      loadSettings()
        .then(async (s) => {
          if (s.backend === 'app' || s.backend === 'server') {
            const h = await checkHealth(s.backend, endpointOf(s));
            return { ok: h.ok, message: h.message };
          }
          await wasmPrepare(s);
          return { ok: true, message: 'モデルを読み込みました' };
        })
        .then(sendResponse, (e: Error) => sendResponse({ ok: false, message: e.message }));
      return true;
    case 'testConnection':
      loadSettings()
        .then(async (s) => {
          const backend = msg.backend === 'server' ? 'server' : msg.backend === 'app' ? 'app' : s.backend;
          const kind = backend === 'server' ? 'server' : 'app';
          const endpoint = msg.endpoint ?? (kind === 'app' ? s.appEndpoint : s.endpoint);
          const st = await httpStatus({ ...s, backend: kind, [kind === 'app' ? 'appEndpoint' : 'endpoint']: endpoint }, 4000);
          return { ok: st.state === 'ready', message: st.message, status: st };
        })
        .then(sendResponse);
      return true;
    case 'launchApp':
      launchApp().then(sendResponse);
      return true;
    case 'appModels':
      appModels().then(sendResponse);
      return true;
    case 'appSelectModel':
      appSelect(msg.id).then(sendResponse);
      return true;
    case 'openOptions':
      chrome.runtime.openOptionsPage();
      return false;
    default:
      return false;
  }
});

// ---------------------------------------------------------------- context menu / commands

const MENU_SELECTION = 'plamo-translate-selection';
const MENU_PAGE = 'plamo-translate-page';

chrome.runtime.onInstalled.addListener((details) => {
  // 旧バージョンからの更新時は設定をマイグレーション (loadSettings が変換・保存する)
  void loadSettings();
  if (details.reason === 'install') {
    // 初回: 「はじめに」(macOS アプリのセットアップ手順と接続テスト) を開く
    void chrome.tabs.create({ url: chrome.runtime.getURL('options.html#welcome') });
  }
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: MENU_SELECTION, title: 'PLaMoで翻訳', contexts: ['selection'] });
    chrome.contextMenus.create({ id: MENU_PAGE, title: 'このページをPLaMoで翻訳', contexts: ['page'] });
  });
});

async function sendToTab(tabId: number | undefined, msg: RuntimeMessage): Promise<void> {
  if (tabId === undefined) return;
  try {
    await chrome.tabs.sendMessage(tabId, msg);
  } catch {
    // content script が無いページ (chrome:// など) では何もできない
    await chrome.action.setBadgeText({ text: '!', tabId });
    await chrome.action.setBadgeBackgroundColor({ color: '#c0392b', tabId });
    setTimeout(() => chrome.action.setBadgeText({ text: '', tabId }).catch(() => {}), 2500);
  }
}

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === MENU_SELECTION) {
    void sendToTab(tab?.id, { type: 'translate-selection', text: info.selectionText });
  } else if (info.menuItemId === MENU_PAGE) {
    void sendToTab(tab?.id, { type: 'page-translate', action: 'toggle' });
  }
});

chrome.commands.onCommand.addListener(async (command, tab) => {
  const t = tab ?? (await chrome.tabs.query({ active: true, currentWindow: true }))[0];
  if (command === 'translate-selection') void sendToTab(t?.id, { type: 'translate-selection' });
  else if (command === 'translate-page') void sendToTab(t?.id, { type: 'page-translate', action: 'toggle' });
});
