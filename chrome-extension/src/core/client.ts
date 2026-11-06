import {
  PORT_TRANSLATE,
  type ClientToSw,
  type EngineStatus,
  type SwToClient,
  type TranslateRequest,
} from './protocol';
import { genId } from './util';

export interface TranslateHandle {
  promise: Promise<{ text: string; ms: number }>;
  cancel: () => void;
}

export interface TranslateCallbacks {
  onChunk?: (text: string) => void;
  onPhase?: (phase: 'queued' | 'preparing' | 'generating') => void;
}

export class TranslateCancelled extends Error {
  constructor() {
    super('キャンセルしました');
    this.name = 'TranslateCancelled';
  }
}

/** Service Worker に翻訳ジョブを投げる。1 ジョブにつき 1 ポート (切断 = キャンセル)。 */
export function translateStream(req: TranslateRequest, cb: TranslateCallbacks = {}): TranslateHandle {
  const id = genId();
  const port = chrome.runtime.connect({ name: PORT_TRANSLATE });
  let finished = false;
  let cancelled = false;
  const promise = new Promise<{ text: string; ms: number }>((resolve, reject) => {
    port.onMessage.addListener((m: SwToClient) => {
      if (m.id !== id) return;
      if (m.op === 'phase') cb.onPhase?.(m.phase);
      else if (m.op === 'chunk') cb.onChunk?.(m.text);
      else if (m.op === 'done') {
        finished = true;
        port.disconnect();
        resolve({ text: m.text, ms: m.ms });
      } else if (m.op === 'error') {
        finished = true;
        port.disconnect();
        reject(m.cancelled ? new TranslateCancelled() : new Error(m.message));
      }
    });
    port.onDisconnect.addListener(() => {
      if (!finished) {
        finished = true;
        reject(cancelled ? new TranslateCancelled() : new Error('拡張機能のバックグラウンド処理との接続が切れました'));
      }
    });
    port.postMessage({ op: 'start', id, req } satisfies ClientToSw);
  });
  return {
    promise,
    cancel: () => {
      if (finished) return;
      cancelled = true;
      try {
        port.postMessage({ op: 'cancel', id } satisfies ClientToSw);
      } catch {
        /* ignore */
      }
    },
  };
}

export async function getEngineStatus(): Promise<EngineStatus> {
  return (await chrome.runtime.sendMessage({ type: 'getStatus' })) as EngineStatus;
}
