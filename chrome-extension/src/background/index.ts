import { loadSettings, type Settings } from '../core/settings';
import { cleanOutput, Pfml3Error } from '../core/pfml3';
import { promptFor } from '../core/util';
import { getModel, getModelFile, WASM_SIZES, type SizeId } from '../core/catalog';
import {
  PORT_ENGINE_PREFIX,
  PORT_TRANSLATE,
  type ClientToSw,
  type EngineStatus,
  type ModelSpec,
  type OffscreenToSw,
  type RuntimeMessage,
  type SwToClient,
  type SwToOffscreen,
  type TranslateRequest,
} from '../core/protocol';
import { checkHealth, serverComplete } from '../engine/local-server';

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
          s.backend === 'server'
            ? await serverComplete({
                endpoint: s.endpoint,
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
      `${getModel(size).label} モデルはブラウザ内 (WASM) では実行できません (メモリ/ArrayBuffer 2GB の制限)。ローカルサーバーを使用してください`,
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

async function getStatus(): Promise<EngineStatus> {
  const s = await loadSettings();
  if (s.backend === 'server') {
    const h = await checkHealth(s.endpoint, 2500);
    return {
      backend: 'server',
      state: h.ok ? 'ready' : 'error',
      message: h.message,
      modelLabel: `${getModel(s.modelSize).label} (${s.endpoint})`,
    };
  }
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
          if (s.backend === 'server') {
            const h = await checkHealth(s.endpoint);
            return { ok: h.ok, message: h.message };
          }
          await wasmPrepare(s);
          return { ok: true, message: 'モデルを読み込みました' };
        })
        .then(sendResponse, (e: Error) => sendResponse({ ok: false, message: e.message }));
      return true;
    case 'testConnection':
      loadSettings()
        .then((s) => checkHealth(msg.endpoint ?? s.endpoint))
        .then(sendResponse);
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

chrome.runtime.onInstalled.addListener(() => {
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
