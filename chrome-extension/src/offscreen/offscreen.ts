import { WasmEngine } from '../engine/wasm';
import {
  PORT_ENGINE_PREFIX,
  type EngineStatus,
  type OffscreenToSw,
  type SwToOffscreen,
} from '../core/protocol';

const engine = new WasmEngine((status) => {
  chrome.runtime.sendMessage({ type: 'engine-status', status }).catch(() => {});
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type === 'offscreen-status') {
    sendResponse(engine.getStatus() satisfies EngineStatus);
  } else if (msg?.type === 'offscreen-dispose') {
    engine.dispose().then(() => sendResponse(true));
    return true;
  }
  return false;
});

chrome.runtime.onConnect.addListener((port) => {
  if (!port.name.startsWith(PORT_ENGINE_PREFIX)) return;
  const ctl = new AbortController();
  const send = (m: OffscreenToSw) => {
    try {
      port.postMessage(m);
    } catch {
      /* port closed */
    }
  };
  port.onDisconnect.addListener(() => ctl.abort());
  port.onMessage.addListener(async (m: SwToOffscreen) => {
    if (m.op === 'cancel') {
      ctl.abort();
      return;
    }
    if (m.op === 'prepare') {
      try {
        await engine.ensureLoaded(m.model, m.threads);
        send({ op: 'done', text: '' });
      } catch (e) {
        send({ op: 'error', message: (e as Error).message || String(e) });
      }
      return;
    }
    if (m.op === 'run') {
      try {
        const text = await engine.complete({
          prompt: m.prompt,
          maxTokens: m.maxTokens,
          model: m.model,
          threads: m.threads,
          signal: ctl.signal,
          onText: (t) => send({ op: 'chunk', text: t }),
        });
        send({ op: 'done', text });
      } catch (e) {
        const err = e as Error;
        send({ op: 'error', message: err.message || String(e), cancelled: ctl.signal.aborted });
      }
    }
  });
});
