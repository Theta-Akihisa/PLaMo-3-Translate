import { Wllama, WllamaAbortError, type DownloadProgressCallback } from '@wllama/wllama';
import type { EngineStatus, ModelSpec } from '../core/protocol';
import { STOP } from '../core/catalog';

/** 同梱 wllama の llama.cpp が PLaMo 3 に未対応のときに出す、分かりやすいメッセージ */
export function friendlyLoadError(raw: string): string {
  if (/unknown tokenizer|unknown model architecture|plamo3/i.test(raw)) {
    return (
      `このブラウザ内エンジン (wllama ${Wllama.getLibllamaVersion?.() ?? ''}) に含まれる llama.cpp は ` +
      'PLaMo 3 のトークナイザに未対応のため、モデルを読み込めません。' +
      '設定でバックエンドを「ローカルサーバー」に切り替えてください。' +
      ` (詳細: ${raw.split('\n')[0].slice(0, 160)})`
    );
  }
  return raw;
}

export class WasmEngine {
  private wllama: Wllama | null = null;
  private loadedKey = '';
  private status: EngineStatus = { backend: 'wasm', state: 'idle' };

  constructor(private onStatus: (s: EngineStatus) => void) {}

  getStatus(): EngineStatus {
    return this.status;
  }

  private set(s: Partial<EngineStatus>): void {
    this.status = {
      ...this.status,
      backend: 'wasm',
      crossOriginIsolated: self.crossOriginIsolated,
      ...s,
    };
    this.onStatus(this.status);
  }

  async ensureLoaded(model: ModelSpec, threads: number): Promise<Wllama> {
    const key = `${model.url}|${threads}`;
    if (this.wllama && this.loadedKey === key && this.wllama.isModelLoaded()) return this.wllama;

    if (this.wllama) {
      try {
        await this.wllama.exit();
      } catch {
        /* ignore */
      }
      this.wllama = null;
      this.loadedKey = '';
    }

    this.set({ state: 'downloading', loaded: 0, total: model.sizeBytes, modelLabel: model.label, message: undefined });
    const w = new Wllama({ default: chrome.runtime.getURL('wllama.wasm') }, { suppressNativeLog: true });
    const progressCallback: DownloadProgressCallback = ({ loaded, total }) => {
      this.set({ state: 'downloading', loaded, total: total || model.sizeBytes });
    };
    try {
      this.set({ message: undefined });
      await w.loadModelFromUrl(model.url, {
        n_ctx: 4096,
        ...(threads > 0 ? { n_threads: threads } : {}),
        useCache: true,
        progressCallback,
      });
      // ダウンロードが終わるとここでロード完了
    } catch (e) {
      const msg = friendlyLoadError(e instanceof Error ? e.message : String(e));
      this.set({ state: 'error', message: msg });
      try {
        await w.exit();
      } catch {
        /* ignore */
      }
      throw new Error(msg);
    }
    this.wllama = w;
    this.loadedKey = key;
    this.set({
      state: 'ready',
      loaded: undefined,
      total: undefined,
      threads: w.getNumThreads(),
      message: w.isMultithread() ? 'マルチスレッド' : 'シングルスレッド',
    });
    return w;
  }

  /** PFML3 プロンプトを補完する (貪欲デコード)。BOS 付加と特殊トークン解析は llama.cpp サーバー実装側で行われる。 */
  async complete(opts: {
    prompt: string;
    maxTokens: number;
    model: ModelSpec;
    threads: number;
    signal: AbortSignal;
    onText: (acc: string) => void;
  }): Promise<string> {
    const w = await this.ensureLoaded(opts.model, opts.threads);
    if (opts.signal.aborted) throw new WllamaAbortError();
    let acc = '';
    try {
      const stream = await w.createCompletion({
        prompt: opts.prompt,
        max_tokens: opts.maxTokens,
        temperature: 0,
        stop: [...STOP],
        stream: true,
        abortSignal: opts.signal,
      });
      for await (const chunk of stream) {
        const t = chunk.choices?.[0]?.text;
        if (t) {
          acc += t;
          opts.onText(acc);
        }
      }
    } catch (e) {
      if (opts.signal.aborted || e instanceof WllamaAbortError || (e as Error)?.name === 'AbortError') {
        throw new WllamaAbortError();
      }
      throw e;
    }
    return acc;
  }

  async dispose(): Promise<void> {
    if (this.wllama) {
      try {
        await this.wllama.exit();
      } catch {
        /* ignore */
      }
    }
    this.wllama = null;
    this.loadedKey = '';
    this.set({ state: 'idle', message: undefined });
  }
}
