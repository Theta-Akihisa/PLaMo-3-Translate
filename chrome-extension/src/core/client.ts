import {
  PORT_TRANSLATE,
  type ClientToSw,
  type EngineStatus,
  type SwToClient,
  type TranslateErrorKind,
  type TranslateRequest,
} from './protocol';
import { genId } from './util';

export interface TranslateResult {
  text: string;
  ms: number;
  /** 最大トークン数に達して途中で切れた (text は途中までの訳文) */
  truncated: boolean;
}

export interface TranslateHandle {
  promise: Promise<TranslateResult>;
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

/** 翻訳の失敗。kind はエラーの種類 (protocol.ts の TranslateErrorKind) */
export class TranslateError extends Error {
  constructor(
    message: string,
    readonly kind: TranslateErrorKind = 'other',
  ) {
    super(message);
    this.name = 'TranslateError';
  }
}

/** Service Worker に翻訳ジョブを投げる。1 ジョブにつき 1 ポート (切断 = キャンセル)。 */
export function translateStream(req: TranslateRequest, cb: TranslateCallbacks = {}): TranslateHandle {
  const id = genId();
  const port = chrome.runtime.connect({ name: PORT_TRANSLATE });
  let finished = false;
  let cancelled = false;
  const promise = new Promise<TranslateResult>((resolve, reject) => {
    port.onMessage.addListener((m: SwToClient) => {
      if (m.id !== id) return;
      if (m.op === 'phase') cb.onPhase?.(m.phase);
      else if (m.op === 'chunk') cb.onChunk?.(m.text);
      else if (m.op === 'done') {
        finished = true;
        port.disconnect();
        resolve({ text: m.text, ms: m.ms, truncated: !!m.truncated });
      } else if (m.op === 'error') {
        finished = true;
        port.disconnect();
        reject(m.cancelled ? new TranslateCancelled() : new TranslateError(m.message, m.kind));
      }
    });
    port.onDisconnect.addListener(() => {
      if (!finished) {
        finished = true;
        reject(cancelled ? new TranslateCancelled() : new TranslateError('拡張機能のバックグラウンド処理との接続が切れました'));
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
