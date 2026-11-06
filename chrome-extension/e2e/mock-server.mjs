// OpenAI 互換 /v1/completions (SSE) のモックサーバー + テスト用ページ + モデル配信
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

export function startMock({ modelFiles = {} } = {}) {
  const requests = [];
  const state = { aborted: 0, completed: 0 };
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
    if (url.pathname === '/health') {
      res.setHeader('Content-Type', 'application/json');
      return res.end('{"status":"ok"}');
    }
    if (url.pathname === '/v1/completions' && req.method === 'POST') {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        const j = JSON.parse(body);
        requests.push(j);
        res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
        const text = lastInput(j.prompt);
        let out = DICT[text] ?? `【訳】${text}`;
        let delay = 25;
        if (text.startsWith('SLOW')) { out = 'あ'.repeat(200); delay = 100; }
        const chars = [...out];
        let i = 0;
        let closed = false;
        res.on('close', () => { if (!closed) { closed = true; if (i < chars.length) state.aborted++; } });
        const tick = () => {
          if (closed) return;
          if (i >= chars.length) {
            res.write(`data: ${JSON.stringify({ choices: [{ text: '', index: 0, finish_reason: 'stop' }] })}\n\n`);
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
      return;
    }
    res.statusCode = 404;
    res.end();
  });
  return new Promise((resolve) =>
    srv.listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port, requests, state, close: () => srv.close() })),
  );
}
