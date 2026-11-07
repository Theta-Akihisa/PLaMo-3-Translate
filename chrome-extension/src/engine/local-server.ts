// macOS アプリ (shared/local-api.md) と llama-server に共通の HTTP クライアント。
// どちらも /health と OpenAI 互換 /v1/completions (PFML3 プロンプト, SSE) を持つ。
// fetch は Service Worker からのみ行う (Origin: chrome-extension://<id> が付き、アプリの Origin 検査を通る)。
import { normalizeEndpoint } from '../core/util';
import { STOP } from '../core/catalog';
import type { AppModel } from '../core/protocol';

export type ApiKind = 'app' | 'server';

/** macOS アプリの起動 URL */
export const APP_LAUNCH_URL = 'plamotranslate://open';

export class AbortedError extends Error {
  constructor() {
    super('cancelled');
    this.name = 'AbortError';
  }
}

/** OpenAI 互換エラー ({"error":{"message","type","code"}}) を表す */
export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly type?: string,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

/** 接続できない (接続拒否・DNS など fetch 自体の失敗) */
export class UnreachableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'UnreachableError';
  }
}

const NAME: Record<ApiKind, string> = { app: 'macOS アプリ', server: 'llama-server' };

export function unreachableMessage(kind: ApiKind, base: string): string {
  return kind === 'app'
    ? `macOS アプリが起動していません（${base} に接続できません）。「PLaMo Translate」アプリを起動してください`
    : `llama-server に接続できません（${base}）。サーバーを起動してください`;
}

async function readJson(res: Response): Promise<any> {
  try {
    const t = await res.text();
    return t ? JSON.parse(t) : null;
  } catch {
    return null;
  }
}

/** HTTP エラー応答を ApiError にする。サーバーのメッセージ (日本語) をそのまま使う */
async function toApiError(kind: ApiKind, res: Response): Promise<ApiError> {
  const j = await readJson(res);
  const e = j?.error;
  const type: string | undefined = typeof e?.type === 'string' ? e.type : undefined;
  const serverMsg: string = typeof e?.message === 'string' ? e.message : typeof e === 'string' ? e : '';
  let msg: string;
  if (res.status === 403 && (type === 'forbidden_origin' || type === 'forbidden_host')) {
    msg = `${NAME[kind]}が接続を拒否しました（${type}）${serverMsg ? `: ${serverMsg}` : ''}`;
  } else if (res.status === 409 && type === 'model_not_installed') {
    msg = serverMsg || 'モデルがダウンロードされていません。macOS アプリの「モデル」画面でダウンロードしてください';
  } else {
    msg = `${NAME[kind]}がエラーを返しました（HTTP ${res.status}${type ? ` ${type}` : ''}）${serverMsg ? `: ${serverMsg}` : ''}`;
  }
  return new ApiError(msg, res.status, type);
}

async function apiFetch(kind: ApiKind, endpoint: string, path: string, init: RequestInit & { timeoutMs?: number } = {}) {
  const base = normalizeEndpoint(endpoint);
  const { timeoutMs, ...rest } = init;
  const outer = init.signal ?? undefined;
  // タイムアウトは応答ヘッダーまで。ストリーム本文の読み取りは呼び出し側の signal だけで中断する
  const timeout = timeoutMs ? new AbortController() : null;
  const t = timeout ? setTimeout(() => timeout.abort(), timeoutMs) : undefined;
  const signal = timeout ? (outer ? AbortSignal.any([outer, timeout.signal]) : timeout.signal) : outer;
  try {
    return await fetch(`${base}${path}`, { ...rest, signal });
  } catch (e) {
    if (outer?.aborted) throw new AbortedError();
    if (timeout?.signal.aborted) {
      const err = new Error(`${NAME[kind]}から応答がありません（タイムアウト）`);
      err.name = 'TimeoutError';
      throw err;
    }
    throw new UnreachableError(unreachableMessage(kind, base));
  } finally {
    clearTimeout(t);
  }
}

// ---------------------------------------------------------------- /health

export interface AppModelInfo {
  id?: string;
  size?: string;
  label?: string;
  quant?: string;
  loaded?: boolean;
}

export type HealthState = 'ok' | 'loading' | 'no_model' | 'unreachable' | 'timeout' | 'forbidden' | 'error';

export interface HealthResult {
  state: HealthState;
  ok: boolean;
  message: string;
  httpStatus?: number;
  model?: AppModelInfo;
  app?: string;
  version?: string;
  api?: number;
}

export function modelLabelOf(m?: AppModelInfo): string {
  if (!m) return '';
  return [m.label ?? m.size ?? m.id, m.quant].filter(Boolean).join(' ');
}

/** GET /health の JSON (または llama-server の応答) を解釈する。純関数 (テスト用に export) */
export function interpretHealth(kind: ApiKind, httpStatus: number, j: any): HealthResult {
  const model: AppModelInfo | undefined = j && typeof j.model === 'object' && j.model ? j.model : undefined;
  const info = { httpStatus, model, app: j?.app, version: j?.version, api: j?.api };
  const status: string | undefined = typeof j?.status === 'string' ? j.status : undefined;
  if (httpStatus === 403) {
    const e = j?.error;
    return {
      ...info,
      state: 'forbidden',
      ok: false,
      message: `${NAME[kind]}が接続を拒否しました（${e?.type ?? 'HTTP 403'}）${e?.message ? `: ${e.message}` : ''}`,
    };
  }
  if (status === 'no_model') {
    return {
      ...info,
      state: 'no_model',
      ok: false,
      message: `モデル${model?.label ? ` ${model.label}` : ''}が未ダウンロードです。macOS アプリの『モデル』画面でダウンロードしてください`,
    };
  }
  if (status === 'loading' || (httpStatus === 503 && kind === 'server')) {
    return { ...info, state: 'loading', ok: false, message: 'モデルを読み込み中です。しばらくお待ちください' };
  }
  if (httpStatus >= 200 && httpStatus < 300) {
    const label = modelLabelOf(model);
    return { ...info, state: 'ok', ok: true, message: label ? `接続できました（${label}）` : `接続できました${status ? ` (${status})` : ''}` };
  }
  if (httpStatus === 503) {
    return { ...info, state: 'loading', ok: false, message: 'モデルを読み込み中です。しばらくお待ちください' };
  }
  const e = j?.error;
  return {
    ...info,
    state: 'error',
    ok: false,
    message: `${NAME[kind]}がエラーを返しました（HTTP ${httpStatus}）${e?.message ? `: ${e.message}` : ''}`,
  };
}

export async function checkHealth(kind: ApiKind, endpoint: string, timeoutMs = 4000): Promise<HealthResult> {
  let res: Response;
  try {
    res = await apiFetch(kind, endpoint, '/health', { timeoutMs, cache: 'no-store' });
  } catch (e) {
    const err = e as Error;
    if (err.name === 'TimeoutError') return { state: 'timeout', ok: false, message: err.message };
    return { state: 'unreachable', ok: false, message: err.message };
  }
  return interpretHealth(kind, res.status, await readJson(res));
}

// ---------------------------------------------------------------- /v1/models (macOS アプリ)

export async function listAppModels(endpoint: string): Promise<AppModel[]> {
  const res = await apiFetch('app', endpoint, '/v1/models', { timeoutMs: 4000, cache: 'no-store' });
  if (!res.ok) throw await toApiError('app', res);
  const j = await readJson(res);
  const data: any[] = Array.isArray(j?.data) ? j.data : [];
  return data
    .filter((m) => typeof m?.id === 'string' && typeof m?.size === 'string' && !m.alias_of)
    .map((m) => ({
      id: m.id,
      size: m.size,
      label: m.label ?? m.size,
      installed: !!m.installed,
      active: !!m.active,
      quant: m.quant,
      installedQuants: m.installed_quants,
      sizeBytes: m.size_bytes,
    }));
}

/** POST /v1/models/select。成功時は /health と同じ JSON */
export async function selectAppModel(endpoint: string, id: string): Promise<HealthResult> {
  const res = await apiFetch('app', endpoint, '/v1/models/select', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: id }),
    timeoutMs: 15000,
  });
  if (!res.ok) throw await toApiError('app', res);
  return interpretHealth('app', res.status, await readJson(res));
}

// ---------------------------------------------------------------- /v1/completions

/** OpenAI 互換 /v1/completions (SSE ストリーム)。onText には累積テキストを渡す。 */
export async function serverComplete(opts: {
  kind: ApiKind;
  endpoint: string;
  prompt: string;
  maxTokens: number;
  signal: AbortSignal;
  onText: (accumulated: string) => void;
}): Promise<string> {
  const res = await apiFetch(opts.kind, opts.endpoint, '/v1/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      // macOS アプリでは別名 plamo-3-translate = アプリで選択中のモデル (アプリの選択を尊重する)
      model: 'plamo-3-translate',
      prompt: opts.prompt,
      max_tokens: opts.maxTokens,
      temperature: 0,
      stop: STOP,
      stream: true,
    }),
    signal: opts.signal,
  });
  if (!res.ok) throw await toApiError(opts.kind, res);
  if (!res.body) throw new Error('サーバーからストリームを受信できませんでした');

  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  let acc = '';
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let idx: number;
      while ((idx = buf.search(/\r?\n/)) >= 0) {
        const line = buf.slice(0, idx).trim();
        buf = buf.slice(buf[idx] === '\r' ? idx + 2 : idx + 1);
        if (!line.startsWith('data:')) continue;
        const data = line.slice(5).trim();
        if (data === '[DONE]') return acc;
        try {
          const j = JSON.parse(data);
          if (j?.error) throw new Error(String(j.error.message ?? j.error));
          const t: string | undefined = j?.choices?.[0]?.text;
          if (t) {
            acc += t;
            opts.onText(acc);
          }
        } catch (e) {
          if (e instanceof SyntaxError) continue;
          throw e;
        }
      }
    }
  } catch (e) {
    if (opts.signal.aborted) throw new AbortedError();
    throw e;
  } finally {
    reader.cancel().catch(() => {});
  }
  if (opts.signal.aborted) throw new AbortedError();
  return acc;
}
