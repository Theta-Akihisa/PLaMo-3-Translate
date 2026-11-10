// macOS アプリ「PLaMo Translate」のローカル API (shared/local-api.md) のモック + テスト用ページ + モデル配信。
// llama-server 互換の /health・/v1/completions (SSE) も兼ねる。
import http from 'node:http';
import fs from 'node:fs';

export const PAGE_HTML = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Test page</title>
<style>body{font:16px/1.6 sans-serif;max-width:640px;margin:40px auto}</style></head><body>
<h1>Project update</h1>
<p id="p1">The meeting has been rescheduled to next Monday.</p>
<p id="p2">Please open the <a href="#x">project dashboard</a> to review the tasks.</p>
<p id="p3">これはすでに日本語の段落なので翻訳されないはずです。</p>
<pre id="code">const x = 1; // do not translate</pre>
<textarea id="ta" rows="2" cols="40">Hello world, this is editable text.</textarea>
<p id="p4">You can also filter them by owner.</p>
</body></html>`;

const DICT = {
  'The meeting has been rescheduled to next Monday.': '会議は来週の月曜日に変更されました。',
  'Hello world, this is editable text.': 'こんにちは世界、これは編集可能なテキストです。',
};

/** プロンプトから最後の入力テキストを取り出す */
export function lastInput(prompt) {
  const i = prompt.lastIndexOf('<|plamo:tag|>input');
  const rest = prompt.slice(i);
  const m = rest.indexOf('<|plamo:msg|>');
  const o = rest.indexOf('<|plamo:tag|>output');
  return rest.slice(m + '<|plamo:msg|>'.length, o);
}

export const CATALOG = [
  { id: 'plamo-3-translate-0.8b', size: '0.8b', label: '0.8B', quant: 'Q4_K_M', size_bytes: 573123200 },
  { id: 'plamo-3-translate-2b', size: '2b', label: '2B', quant: 'Q4_K_M', size_bytes: 1807199392 },
  { id: 'plamo-3-translate-8b', size: '8b', label: '8B', quant: 'Q4_K_M', size_bytes: 5300000000 },
];

/** アプリの状態 (テストから書き換える) */
export function defaultAppState() {
  return { installed: new Set(['0.8b', '2b']), active: '0.8b', loading: false, version: '1.0.0', loaded: false };
}

const json = (res, status, body, extra = {}) => {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', ...extra });
  res.end(JSON.stringify(body));
};
const apiError = (res, status, type, message, extra) => json(res, status, { error: { message, type, code: status } }, extra);

export function startMock({ modelFiles = {}, port = 0 } = {}) {
  const requests = [];
  /** API リクエストのログ: { method, path, origin, host, status } */
  const apiLog = [];
  const state = { aborted: 0, completed: 0 };
  const app = defaultAppState();
  let listenPort = port;

  const activeEntry = () => CATALOG.find((m) => m.size === app.active);
  const health = () => {
    const m = activeEntry();
    const installed = app.installed.has(m.size);
    const status = !installed ? 'no_model' : app.loading ? 'loading' : 'ok';
    return {
      code: status === 'ok' ? 200 : 503,
      body: {
        status,
        app: 'PLaMo Translate',
        version: app.version,
        api: 1,
        model: { id: m.id, size: m.size, label: m.label, quant: m.quant, loaded: installed && app.loaded },
      },
    };
  };
  const notInstalled = (res, m, cors) =>
    apiError(res, 409, 'model_not_installed', `モデル ${m.label} はダウンロードされていません。アプリの「モデル」画面でダウンロードしてください`, cors);

  const srv = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    // モデル配信 (Range 対応, CORS/CORP 許可)
    if (modelFiles[url.pathname]) {
      const f = modelFiles[url.pathname];
      const st = fs.statSync(f);
      res.setHeader('Access-Control-Allow-Origin', '*');
      res.setHeader('Access-Control-Allow-Headers', '*');
      res.setHeader('Access-Control-Expose-Headers', '*');
      res.setHeader('Cross-Origin-Resource-Policy', 'cross-origin');
      res.setHeader('Content-Type', 'application/octet-stream');
      res.setHeader('ETag', `"${st.size}-${st.mtimeMs}"`);
      res.setHeader('Accept-Ranges', 'bytes');
      if (req.method === 'OPTIONS') { res.statusCode = 204; return res.end(); }
      const range = req.headers.range && /bytes=(\d+)-(\d*)/.exec(req.headers.range);
      if (range) {
        const a = +range[1], b = range[2] ? +range[2] : st.size - 1;
        res.statusCode = 206;
        res.setHeader('Content-Range', `bytes ${a}-${b}/${st.size}`);
        res.setHeader('Content-Length', b - a + 1);
        return req.method === 'HEAD' ? res.end() : fs.createReadStream(f, { start: a, end: b }).pipe(res);
      }
      res.setHeader('Content-Length', st.size);
      return req.method === 'HEAD' ? res.end() : fs.createReadStream(f).pipe(res);
    }
    if (url.pathname === '/page.html') {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      return res.end(PAGE_HTML);
    }

    // ---------------------------------------------------------------- local API
    const origin = req.headers.origin;
    const host = req.headers.host ?? '';
    const entry = { method: req.method, path: url.pathname, origin: origin ?? null, host, status: 0 };
    apiLog.push(entry);
    res.on('finish', () => (entry.status = res.statusCode));
    // 1. Host 検査 (DNS リバインディング対策)
    const okHosts = ['127.0.0.1', 'localhost', `127.0.0.1:${listenPort}`, `localhost:${listenPort}`];
    if (!okHosts.includes(host.toLowerCase())) {
      return apiError(res, 403, 'forbidden_host', `許可されていない Host です: ${host}`);
    }
    // 2. Origin 検査: chrome-extension:// のみ許可 (Origin なしは許可)
    if (origin !== undefined && !origin.startsWith('chrome-extension://')) {
      return apiError(res, 403, 'forbidden_origin', `この Origin からのアクセスは許可されていません: ${origin}`);
    }
    // 3. CORS
    const cors = origin ? { 'Access-Control-Allow-Origin': origin, Vary: 'Origin' } : {};
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        ...cors,
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        'Access-Control-Allow-Private-Network': 'true',
        'Access-Control-Max-Age': '600',
      });
      return res.end();
    }

    if (url.pathname === '/health' && req.method === 'GET') {
      const h = health();
      return json(res, h.code, h.body, cors);
    }
    if (url.pathname === '/v1/models' && req.method === 'GET') {
      const a = activeEntry();
      return json(res, 200, {
        object: 'list',
        data: [
          { id: 'plamo-3-translate', object: 'model', owned_by: 'pfnet', alias_of: a.id },
          ...CATALOG.map((m) => ({
            id: m.id, object: 'model', owned_by: 'pfnet', size: m.size, label: m.label,
            installed: app.installed.has(m.size), active: m.size === app.active, quant: m.quant,
            installed_quants: app.installed.has(m.size) ? [m.quant] : [], size_bytes: m.size_bytes,
          })),
        ],
      }, cors);
    }

    let body = '';
    req.on('data', (c) => {
      body += c;
      if (body.length > 1024 * 1024) req.destroy();
    });
    req.on('end', () => {
      if (req.method !== 'POST') return apiError(res, 404, 'not_found', `不明なパスです: ${url.pathname}`, cors);
      let j;
      try {
        j = JSON.parse(body);
      } catch {
        return apiError(res, 400, 'invalid_request', 'JSON を解析できません', cors);
      }
      if (url.pathname === '/v1/models/select') {
        const m = CATALOG.find((x) => x.id === j.model);
        if (!m) return apiError(res, 404, 'not_found', `不明なモデル ID です: ${j.model}`, cors);
        if (!app.installed.has(m.size)) return notInstalled(res, m, cors);
        app.active = m.size;
        app.loaded = false;
        const h = health();
        return json(res, 200, h.body, cors);
      }
      if (url.pathname !== '/v1/completions') return apiError(res, 404, 'not_found', `不明なパスです: ${url.pathname}`, cors);
      if (typeof j.prompt !== 'string') return apiError(res, 400, 'invalid_request', 'prompt がありません', cors);
      if (j.model && j.model !== 'plamo-3-translate') {
        const m = CATALOG.find((x) => x.id === j.model);
        if (!m) return apiError(res, 404, 'not_found', `不明なモデル ID です: ${j.model}`, cors);
        if (!app.installed.has(m.size)) return notInstalled(res, m, cors);
        app.active = m.size;
      }
      if (!app.installed.has(app.active)) return notInstalled(res, activeEntry(), cors);
      app.loaded = true;
      requests.push({ ...j, origin: origin ?? null });
      const text = lastInput(j.prompt);
      // BADPARA を含む段落だけ 400 で拒否する (ページ翻訳のスキップのテスト用)
      if (text.includes('BADPARA')) return apiError(res, 400, 'invalid_request', 'この段落は処理できません (テスト)', cors);
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', ...cors });
      let out = DICT[text] ?? `【訳】${text}`;
      let delay = 25;
      // LONG で始まる入力は max_tokens に達したことにする (finish_reason: "length")
      let finish = 'stop';
      if (text.startsWith('LONG')) { out = '【途中】長い訳文の途中まで'; finish = 'length'; }
      if (text.startsWith('SLOW')) { out = 'あ'.repeat(200); delay = 100; }
      const chars = [...out];
      let i = 0;
      let closed = false;
      res.on('close', () => { if (!closed) { closed = true; if (i < chars.length) state.aborted++; } });
      const tick = () => {
        if (closed) return;
        if (i >= chars.length) {
          res.write(`data: ${JSON.stringify({ choices: [{ text: '', index: 0, finish_reason: finish }] })}\n\n`);
          res.write('data: [DONE]\n\n');
          state.completed++;
          closed = true;
          return res.end();
        }
        const piece = chars.slice(i, i + 3).join('');
        i += 3;
        res.write(`data: ${JSON.stringify({ choices: [{ text: piece, index: 0, finish_reason: null }] })}\n\n`);
        setTimeout(tick, delay);
      };
      tick();
    });
  });
  return new Promise((resolve, reject) => {
    srv.once('error', reject);
    srv.listen(port, '127.0.0.1', () => {
      listenPort = srv.address().port;
      resolve({
        srv, port: listenPort, requests, apiLog, state, app,
        reset: () => Object.assign(app, defaultAppState()),
        close: () => new Promise((r) => { srv.closeAllConnections?.(); srv.close(() => r()); }),
      });
    });
  });
}
