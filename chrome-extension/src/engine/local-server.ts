import { normalizeEndpoint } from '../core/util';
import { STOP } from '../core/catalog';

export class AbortedError extends Error {
  constructor() {
    super('cancelled');
    this.name = 'AbortError';
  }
}

export async function checkHealth(endpoint: string, timeoutMs = 4000): Promise<{ ok: boolean; message: string }> {
  const base = normalizeEndpoint(endpoint);
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const r = await fetch(`${base}/health`, { signal: ctl.signal });
    if (r.ok) {
      let extra = '';
      try {
        const j = await r.json();
        if (j && typeof j.status === 'string') extra = ` (${j.status})`;
      } catch {
        /* 本文が JSON でなくても可 */
      }
      return { ok: true, message: `接続できました${extra}` };
    }
    if (r.status === 503) return { ok: false, message: 'サーバーはモデルを読み込み中です (503)。しばらく待ってください' };
    return { ok: false, message: `サーバーがエラーを返しました (HTTP ${r.status})` };
  } catch (e) {
    if ((e as Error).name === 'AbortError') return { ok: false, message: '接続がタイムアウトしました' };
    return {
      ok: false,
      message: `接続できません: ${base}。llama-server か macOS アプリの API サーバーが起動しているか確認してください`,
    };
  } finally {
    clearTimeout(t);
  }
}

/** OpenAI 互換 /v1/completions (SSE ストリーム)。onText には累積テキストを渡す。 */
export async function serverComplete(opts: {
  endpoint: string;
  prompt: string;
  maxTokens: number;
  signal: AbortSignal;
  onText: (accumulated: string) => void;
}): Promise<string> {
  const base = normalizeEndpoint(opts.endpoint);
  let res: Response;
  try {
    res = await fetch(`${base}/v1/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'plamo-3-translate',
        prompt: opts.prompt,
        max_tokens: opts.maxTokens,
        temperature: 0,
        stop: STOP,
        stream: true,
      }),
      signal: opts.signal,
    });
  } catch (e) {
    if (opts.signal.aborted) throw new AbortedError();
    throw new Error(
      `ローカルサーバーに接続できません (${base})。llama-server または macOS アプリの API サーバーを起動してください`,
    );
  }
  if (!res.ok) {
    let detail = '';
    try {
      detail = (await res.text()).slice(0, 300);
    } catch {
      /* ignore */
    }
    throw new Error(`サーバーエラー HTTP ${res.status}${detail ? `: ${detail}` : ''}`);
  }
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
          const t: string | undefined = j?.choices?.[0]?.text;
          if (j?.error) throw new Error(String(j.error.message ?? j.error));
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
