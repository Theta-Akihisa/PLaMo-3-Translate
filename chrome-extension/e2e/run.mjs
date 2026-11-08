import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import http from 'node:http';
import { startMock } from './mock-server.mjs';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const here = path.dirname(fileURLToPath(import.meta.url));
const ext = path.resolve(here, '../dist');
const vectors = JSON.parse(fs.readFileSync(path.resolve(here, '../../shared/pfml3-test-vectors.json'), 'utf8')).vectors;
const prompt = (name) => vectors.find((v) => v.name === name).prompt;

const SCRATCH = process.env.E2E_SCRATCH || path.join(os.tmpdir(), 'plamo-translate-e2e');
fs.mkdirSync(SCRATCH, { recursive: true });
const MODELS_DIR = process.env.E2E_MODELS || path.join(SCRATCH, 'models');
const PLAMO = path.join(MODELS_DIR, 'plamo-3-translate-0.8b-Q4_K_M.gguf');
const STORIES = path.join(MODELS_DIR, 'stories260K.gguf');
const SHOTS = path.join(SCRATCH, 'screens');
fs.mkdirSync(SHOTS, { recursive: true });

const results = [];
async function test(name, fn) {
  const t0 = Date.now();
  try {
    const note = await fn();
    results.push({ name, ok: true, ms: Date.now() - t0, note });
    console.log(`PASS ${name} (${Date.now() - t0}ms)${note ? ' — ' + note : ''}`);
  } catch (e) {
    results.push({ name, ok: false, ms: Date.now() - t0, error: String(e.message || e) });
    console.log(`FAIL ${name}: ${e.stack || e}`);
  }
}
const assert = (c, m) => { if (!c) throw new Error('assertion failed: ' + m); };
const eq = (a, b, m = '') => { if (a !== b) throw new Error(`${m} expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const modelFiles = {};
if (fs.existsSync(PLAMO)) modelFiles['/plamo.gguf'] = PLAMO;
if (fs.existsSync(STORIES)) modelFiles['/stories.gguf'] = STORIES;
const mock = await startMock({ modelFiles });
const base = `http://127.0.0.1:${mock.port}`;

const userDir = fs.mkdtempSync(path.join(os.tmpdir(), 'plamo-e2e-'));
const ctx = await chromium.launchPersistentContext(userDir, {
  channel: 'chromium',
  headless: true,
  deviceScaleFactor: 2,
  viewport: { width: 900, height: 700 },
  args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`],
});
let [sw] = ctx.serviceWorkers();
if (!sw) sw = await ctx.waitForEvent('serviceworker');
const extId = new URL(sw.url()).host;
console.log('extension id', extId);
const setSettings = async (patch) => {
  await sw.evaluate(async (p) => {
    const cur = (await chrome.storage.local.get('settings')).settings ?? {};
    await chrome.storage.local.set({ settings: { ...cur, version: 2, ...p } });
  }, patch);
};
const getStored = () => sw.evaluate(async () => (await chrome.storage.local.get(null)));
const freePort = () => new Promise((r) => { const s = http.createServer(); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => r(p)); }); });
const rawHttp = (opts, body) => new Promise((resolve, reject) => {
  const req = http.request({ host: '127.0.0.1', port: mock.port, ...opts }, (res) => {
    let b = '';
    res.on('data', (c) => (b += c));
    res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: b }));
  });
  req.on('error', reject);
  if (body) req.write(body);
  req.end();
});
const statusText = (p) => p.textContent('#statusText');
const openPopup = async () => {
  const p = await ctx.newPage();
  await p.setViewportSize({ width: 380, height: 600 });
  await p.goto(`chrome-extension://${extId}/popup.html`);
  return p;
};

// ------------------------------------------------------------------ (0) 初回起動 / macOS アプリ (mock)
await test('first run: welcome (はじめに) opens on install; defaults = macOS app @ 18080', async () => {
  const isWelcome = (pg) => pg.url().endsWith('/options.html#welcome');
  let welcome = ctx.pages().find(isWelcome);
  if (!welcome) welcome = await ctx.waitForEvent('page', { predicate: isWelcome, timeout: 10000 });
  await welcome.waitForLoadState();
  await welcome.waitForFunction(() => document.getElementById('welcome').open && document.getElementById('welcomeStatus').dataset.state !== 'idle', null, { timeout: 10000 });
  const txt = await welcome.textContent('#welcome');
  for (const t of ['macOS アプリをインストールして起動', 'アプリでモデル（0.8B）をダウンロード', '接続テスト']) assert(txt.includes(t), 'step: ' + t);
  const st = await welcome.textContent('#welcomeStatusText');
  eq(await welcome.locator('input[name="backend"][value="app"]').isChecked(), true, 'app backend checked by default');
  eq(await welcome.inputValue('#appEndpoint'), 'http://127.0.0.1:18080', 'default app endpoint');
  eq(await welcome.locator('input[name="backend"][value="wasm"]').isVisible(), false, 'wasm hidden under 詳細設定');
  await welcome.setViewportSize({ width: 900, height: 900 });
  await welcome.screenshot({ path: path.join(SHOTS, 'options-welcome.png') });
  await welcome.close();
  return `welcome status: ${st}`;
});

await test('migration: v1 default (server @ 8080) -> app; customized endpoint kept on server', async () => {
  await sw.evaluate(async () => chrome.storage.local.set({ settings: { backend: 'server', endpoint: 'http://127.0.0.1:8080', targetLang: 'en', modelSize: '2b' } }));
  let p = await openPopup();
  await p.waitForFunction(() => document.getElementById('statusText').textContent !== '確認中…');
  let st = (await getStored()).settings;
  eq(st.backend, 'app'); eq(st.version, 2); eq(st.appEndpoint, 'http://127.0.0.1:18080'); eq(st.targetLang, 'en', 'other settings kept');
  await p.close();
  await sw.evaluate(async () => chrome.storage.local.set({ settings: { backend: 'server', endpoint: 'http://192.168.0.10:9000' } }));
  p = await openPopup();
  await p.waitForFunction(() => document.getElementById('statusText').textContent !== '確認中…');
  st = (await getStored()).settings;
  eq(st.backend, 'server'); eq(st.endpoint, 'http://192.168.0.10:9000');
  await p.close();
  await sw.evaluate(async () => chrome.storage.local.remove('settings'));
});

await test('app: not running -> 「アプリを起動」 opens plamotranslate://open, polls /health, connects when app starts', async () => {
  const port = await freePort();
  await setSettings({ backend: 'app', appEndpoint: `http://127.0.0.1:${port}`, targetLang: 'ja', sourceLang: 'auto', form: 'none', liveTranslate: true });
  await sw.evaluate(() => {
    globalThis.__opened = [];
    globalThis.__origTabs = { update: chrome.tabs.update, create: chrome.tabs.create };
    chrome.tabs.update = async (...a) => { globalThis.__opened.push({ fn: 'update', url: (typeof a[0] === 'object' ? a[0] : a[1])?.url }); return {}; };
    chrome.tabs.create = async (props) => { globalThis.__opened.push({ fn: 'create', url: props?.url }); return {}; };
  });
  const p = await openPopup();
  let appMock;
  try {
    await p.waitForFunction(() => document.getElementById('statusText').textContent.includes('macOS アプリが起動していません'), null, { timeout: 8000 });
    eq(await p.locator('#launchApp').isVisible(), true, 'launch button visible');
    eq(await p.textContent('#launchApp'), 'アプリを起動');
    eq(await p.locator('#setupLink').isVisible(), true, 'setup link (never connected)');
    await p.screenshot({ path: path.join(SHOTS, 'popup-not-running.png') });
    await p.click('#launchApp');
    let opened = [];
    for (let i = 0; i < 50 && !opened.length; i++) { await sleep(100); opened = await sw.evaluate(() => globalThis.__opened); }
    eq(opened.length, 1, 'one open attempt');
    eq(opened[0].url, 'plamotranslate://open', 'launch URL');
    await p.waitForFunction(() => /起動を待っています/.test(document.body.textContent), null, { timeout: 3000 });
    await sleep(1500);
    appMock = await startMock({ port }); // 「アプリが起動した」
    await p.waitForFunction(() => document.getElementById('statusText').textContent.includes('macOS アプリ · 0.8B Q4_K_M'), null, { timeout: 15000 });
    eq(await p.locator('#launchApp').isVisible(), false, 'launch button hidden after connect');
    eq((await getStored()).appEverConnected, true, 'everConnected recorded');
    return `opened via tabs.${opened[0].fn}(${opened[0].url})`;
  } finally {
    await sw.evaluate(() => { chrome.tabs.update = globalThis.__origTabs.update; chrome.tabs.create = globalThis.__origTabs.create; });
    await p.close();
    await appMock?.close();
  }
});

await test('app: connected -> status shows model; translation via /v1/completions with extension Origin', async () => {
  mock.reset();
  await setSettings({ backend: 'app', appEndpoint: base });
  const p = await openPopup();
  await p.waitForFunction(() => document.getElementById('statusText').textContent === 'macOS アプリ · 0.8B Q4_K_M — 接続済み', null, { timeout: 8000 });
  await p.waitForFunction(() => !document.getElementById('modelRow').hidden && document.getElementById('appModel').options.length === 3);
  const opts = await p.$$eval('#appModel option', (os) => os.map((o) => ({ v: o.value, t: o.textContent, d: o.disabled })));
  eq(JSON.stringify(opts.map((o) => o.t)), JSON.stringify(['0.8B', '2B', '8B（アプリでダウンロード）']));
  eq(opts[2].d, true, '8B disabled'); eq(opts[1].d, false, '2B enabled');
  eq(await p.inputValue('#appModel'), 'plamo-3-translate-0.8b');
  await p.selectOption('#sourceLang', 'auto');
  mock.requests.length = 0;
  await p.fill('#input', 'The meeting has been rescheduled to next Monday.');
  await p.waitForFunction(() => document.getElementById('output').textContent.includes('会議は来週の月曜日に変更されました。'), null, { timeout: 15000 });
  const r = mock.requests.at(-1);
  eq(r.model, 'plamo-3-translate'); eq(r.stream, true); eq(r.temperature, 0);
  eq(r.prompt, prompt('basic_en_to_ja'), 'PFML3 prompt');
  eq(r.origin, `chrome-extension://${extId}`, 'Origin header');
  await p.waitForFunction(() => /秒/.test(document.getElementById('meta').textContent));
  await p.screenshot({ path: path.join(SHOTS, 'popup.png') });
  await p.close();
});

await test('app: model switch via POST /v1/models/select; app-side choice is the truth; options list', async () => {
  mock.reset();
  const p = await openPopup();
  await p.waitForFunction(() => document.getElementById('appModel').options.length === 3, null, { timeout: 8000 });
  mock.apiLog.length = 0;
  await p.selectOption('#appModel', 'plamo-3-translate-2b');
  await p.waitForFunction(() => document.getElementById('statusText').textContent.includes('macOS アプリ · 2B Q4_K_M'), null, { timeout: 8000 });
  eq(mock.app.active, '2b', 'app switched');
  assert(mock.apiLog.some((e) => e.method === 'POST' && e.path === '/v1/models/select' && e.status === 200), 'select called');
  // 未ダウンロードのモデルは 409 (UI では選べないが、API 経由でも拒否される)
  const r409 = await p.evaluate(() => chrome.runtime.sendMessage({ type: 'appSelectModel', id: 'plamo-3-translate-8b' }));
  eq(r409.ok, false); assert(/ダウンロード/.test(r409.message), '409 message: ' + r409.message);
  await p.close();
  // アプリの UI で 0.8B に戻された -> 拡張機能はそれに従う
  mock.app.active = '0.8b';
  const p2 = await openPopup();
  await p2.waitForFunction(() => document.getElementById('statusText').textContent.includes('0.8B Q4_K_M') && document.getElementById('appModel').value === 'plamo-3-translate-0.8b', null, { timeout: 8000 });
  await p2.close();
  // 設定画面のモデル一覧
  const o = await ctx.newPage();
  await o.goto(`chrome-extension://${extId}/options.html`);
  await o.waitForFunction(() => document.querySelectorAll('#appModelList .m').length === 3, null, { timeout: 8000 });
  eq(await o.locator('#appModelList .m[data-size="8b"] input').isDisabled(), true, '8B radio disabled');
  eq(await o.locator('#appModelList .m[data-size="8b"] button').textContent(), 'アプリでダウンロード');
  eq(await o.locator('#appModelList .m[data-size="0.8b"] input').isChecked(), true);
  eq(await o.locator('#localModelsBox').isVisible(), false, 'size/quant selector hidden for app');
  await o.locator('#appModelList .m[data-size="2b"] input').check();
  await o.waitForFunction(() => document.getElementById('appModelResult').textContent.includes('切り替えました'), null, { timeout: 8000 });
  eq(mock.app.active, '2b');
  await o.waitForFunction(() => document.getElementById('appStatusText').textContent.includes('2B Q4_K_M'));
  mock.app.active = '0.8b';
  await o.waitForFunction(() => document.getElementById('appStatusText').textContent.includes('0.8B Q4_K_M') && document.querySelector('#appModelList .m[data-size="0.8b"] input').checked, null, { timeout: 8000 });
  await o.screenshot({ path: path.join(SHOTS, 'options.png'), fullPage: true });
  await o.close();
});

await test('app: no_model / loading states; 409 model_not_installed message on translate', async () => {
  mock.reset();
  mock.app.installed = new Set(['2b']); // 選択中の 0.8B が未ダウンロード
  const p = await openPopup();
  await p.waitForFunction(() => document.getElementById('statusText').textContent.includes('モデル未ダウンロード'), null, { timeout: 8000 });
  eq((await p.textContent('#statusHint')).trim(), 'macOS アプリの『モデル』画面でダウンロードしてください');
  await p.selectOption('#sourceLang', 'en');
  await p.fill('#input', 'Hello there.');
  await p.waitForFunction(() => document.getElementById('output').classList.contains('err'), null, { timeout: 10000 });
  const out = await p.textContent('#output');
  assert(out.includes('ダウンロードされていません'), '409 server message shown: ' + out);
  await p.screenshot({ path: path.join(SHOTS, 'popup-no-model.png') });
  await p.close();
  mock.reset();
  mock.app.loading = true;
  const p2 = await openPopup();
  await p2.waitForFunction(() => document.getElementById('statusText').textContent.includes('読み込み中'), null, { timeout: 8000 });
  mock.app.loading = false;
  await p2.waitForFunction(() => document.getElementById('statusText').textContent.includes('接続済み'), null, { timeout: 8000 }); // 3 秒ごとの再確認
  await p2.close();
});

await test('mock: origin/host enforcement (web page rejected, extension allowed), CORS preflight', async () => {
  mock.apiLog.length = 0;
  const page = await ctx.newPage();
  await page.goto(`http://localhost:${mock.port}/page.html`);
  const cross = await page.evaluate(async (u) => { try { await fetch(u); return 'allowed'; } catch (e) { return 'rejected'; } }, `${base}/health`);
  eq(cross, 'rejected', 'cross-origin web page fetch');
  const same = await page.evaluate(async () => { const r = await fetch('/v1/completions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"prompt":"x"}' }); return { s: r.status, j: await r.json() }; });
  eq(same.s, 403); eq(same.j.error.type, 'forbidden_origin');
  await page.close();
  assert(mock.apiLog.some((e) => e.origin === `http://localhost:${mock.port}` && e.status === 403), 'web origin got 403');
  const h = await rawHttp({ path: '/health', headers: { Host: `evil.example:${mock.port}` } });
  eq(h.status, 403); eq(JSON.parse(h.body).error.type, 'forbidden_host');
  const ev = await rawHttp({ path: '/health', headers: { Origin: 'https://evil.example' } });
  eq(ev.status, 403); eq(JSON.parse(ev.body).error.type, 'forbidden_origin');
  const pre = await rawHttp({ method: 'OPTIONS', path: '/v1/completions', headers: { Origin: 'chrome-extension://abc', 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Private-Network': 'true' } });
  eq(pre.status, 204); eq(pre.headers['access-control-allow-origin'], 'chrome-extension://abc'); eq(pre.headers['access-control-allow-private-network'], 'true');
  const noOrigin = await rawHttp({ path: '/health' });
  eq(noOrigin.status, 200, 'no Origin (curl) allowed');
  // 拡張機能から届いたリクエストの Origin は常に chrome-extension://<id> (または無し)
  mock.apiLog.length = 0;
  const p = await openPopup();
  await p.waitForFunction(() => document.getElementById('statusText').textContent.includes('接続済み'), null, { timeout: 8000 });
  await p.waitForFunction(() => document.getElementById('appModel').options.length === 3);
  await p.close();
  const fromExt = mock.apiLog.filter((e) => e.path === '/health' || e.path === '/v1/models');
  assert(fromExt.length >= 2, 'ext requests logged');
  for (const e of fromExt) assert(e.origin === null || e.origin === `chrome-extension://${extId}`, 'ext origin: ' + e.origin);
  eq(fromExt.every((e) => e.status === 200), true, 'ext requests accepted');
  return `ext GET origins: ${[...new Set(fromExt.map((e) => e.origin ?? '(none)'))].join(', ')}`;
});

// ------------------------------------------------------------------ (a) llama-server (mock)
mock.reset();
await setSettings({ backend: 'server', endpoint: base, targetLang: 'ja', sourceLang: 'auto', form: 'none', liveTranslate: true });

await test('server: popup live translation streams + exact PFML3 prompt (explicit source)', async () => {
  const p = await openPopup();
  await p.selectOption('#sourceLang', 'en');
  mock.requests.length = 0;
  await p.fill('#input', 'The meeting has been rescheduled to next Monday.');
  await p.waitForFunction(() => document.getElementById('output').textContent.includes('会議は来週の月曜日に変更されました。'), null, { timeout: 15000 });
  await sleep(200);
  assert(mock.requests.length >= 1, 'no request');
  const r = mock.requests.at(-1);
  eq(r.model, 'plamo-3-translate'); eq(r.temperature, 0); eq(r.stream, true);
  assert(r.max_tokens > 0, 'max_tokens');
  eq(JSON.stringify(r.stop), JSON.stringify(['<|plamo:tag|>', '<|plamo:bos|>']));
  const expected = '<|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>The meeting has been rescheduled to next Monday.<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>';
  eq(r.prompt, expected, 'prompt');
  assert(!r.prompt.startsWith('<|plamo:bos|>'), 'bos must not be in prompt');
  await p.close();
});

await test('server: 言語を検出 (auto) -> 「英語（検出）」 and prompt matches vector', async () => {
  await setSettings({ sourceLang: 'auto' });
  const p = await openPopup();
  mock.requests.length = 0;
  await p.fill('#input', 'The meeting has been rescheduled to next Monday.');
  await p.waitForFunction(() => document.getElementById('output').textContent.includes('会議は来週'), null, { timeout: 15000 });
  const label = await p.locator('#sourceLang option').first().textContent();
  eq(label, '英語（検出）');
  const pr = mock.requests.at(-1).prompt;
  // CLD が「信頼できない」と判断した短文では翻訳元を渡さない (= 公式ベクタ basic_en_to_ja と完全一致)
  eq(pr, prompt('basic_en_to_ja'), 'prompt (unreliable detection -> no source)');
  await p.waitForFunction(() => /秒/.test(document.getElementById('meta').textContent));
  await p.screenshot({ path: path.join(SHOTS, 'popup-server.png') });
  await p.close();
});

await test('server: smart target (ja text with ja target -> en)', async () => {
  await setSettings({ sourceLang: 'auto', targetLang: 'ja' });
  const p = await openPopup();
  mock.requests.length = 0;
  await p.fill('#input', '会議は来週の月曜日に変更されました。');
  await p.waitForFunction(() => document.getElementById('targetLang').value === 'en', null, { timeout: 15000 });
  await p.waitForFunction(() => document.getElementById('output').textContent.length > 3, null, { timeout: 15000 });
  assert(mock.requests.at(-1).prompt.includes('<|plamo:val|>en<|plamo:msg|>'), 'target en in prompt');
  await p.close();
});

await test('server: form=polite appears only for ja target', async () => {
  await setSettings({ form: 'polite' });
  const p = await openPopup();
  mock.requests.length = 0;
  await p.selectOption('#sourceLang', 'en');
  await p.fill('#input', 'This system is convenient.');
  await p.waitForFunction(() => document.getElementById('output').textContent.includes('【訳】'), null, { timeout: 15000 });
  eq(mock.requests.at(-1).prompt, prompt('form_polite').replace('<|plamo:tag|>input<|plamo:msg|>', '<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>'));
  await p.close();
  await setSettings({ form: 'none' });
});

await test('server: cancel when input changes aborts the in-flight request', async () => {
  const p = await openPopup();
  await p.selectOption('#sourceLang', 'en');
  mock.state.aborted = 0;
  mock.requests.length = 0;
  await p.fill('#input', 'SLOW translation job');
  await p.waitForFunction(() => document.getElementById('output').textContent.startsWith('あ'), null, { timeout: 15000 });
  await p.fill('#input', 'Hello again.');
  await p.waitForFunction(() => document.getElementById('output').textContent.includes('【訳】Hello again.'), null, { timeout: 15000 });
  assert(mock.state.aborted >= 1, 'server saw aborted connection');
  await p.close();
});

await test('server: stop button cancels', async () => {
  const p = await openPopup();
  await p.selectOption('#sourceLang', 'en');
  mock.state.aborted = 0;
  await p.fill('#input', 'SLOW again');
  await p.waitForFunction(() => document.getElementById('output').textContent.startsWith('あ'), null, { timeout: 15000 });
  await p.click('#stop');
  await sleep(500);
  assert(mock.state.aborted >= 1, 'aborted');
  await p.close();
});

await test('server: connection test (options) ok / ng', async () => {
  const p = await ctx.newPage();
  await p.goto(`chrome-extension://${extId}/options.html`);
  await p.click('#testConn');
  await p.waitForFunction(() => document.getElementById('connResult').textContent.includes('接続できました'));
  await p.fill('#endpoint', 'http://127.0.0.1:1');
  await p.click('#testConn');
  await p.waitForFunction(() => document.getElementById('connResult').classList.contains('err'), null, { timeout: 8000 });
  await p.fill('#endpoint', base);
  await p.dispatchEvent('#endpoint', 'change');
  await p.screenshot({ path: path.join(SHOTS, 'options-server.png'), fullPage: true });
  await p.close();
});

await test('content: selection icon -> card (streamed), target select, replace in textarea, Esc closes', async () => {
  await setSettings({ backend: 'server', endpoint: base, sourceLang: 'auto', targetLang: 'ja', form: 'none', showSelectionIcon: true });
  const page = await ctx.newPage();
  page.on('console', (m) => process.env.E2E_DEBUG && console.log('[page]', m.text()));
  await page.goto(`${base}/page.html`);
  await page.locator('#p1').click({ clickCount: 3 });
  const icon = page.locator('[data-plamo-translate] .sel-icon');
  await icon.waitFor({ state: 'visible', timeout: 5000 });
  mock.requests.length = 0;
  await icon.click();
  await sleep(2500);
  if (process.env.E2E_DEBUG) console.log('DUMP', await page.evaluate(() => document.querySelector('[data-plamo-translate]')?.shadowRoot.querySelector('.panel .body')?.textContent), JSON.stringify(await sw.evaluate(async () => (await chrome.storage.local.get('settings')).settings)), mock.requests.length);
  await page.waitForFunction(() => document.querySelector('[data-plamo-translate]').shadowRoot.querySelector('.panel .body')?.textContent.includes('会議は来週の月曜日に変更されました。'), null, { timeout: 15000 });
  await page.screenshot({ path: path.join(SHOTS, 'page-panel.png') });
  // 翻訳先を変更 -> 再翻訳
  await page.locator('[data-plamo-translate] .panel select').first().selectOption('en');
  await page.waitForFunction(() => document.querySelector('[data-plamo-translate]').shadowRoot.querySelector('.panel .body')?.textContent.includes('完了') || document.querySelector('[data-plamo-translate]').shadowRoot.querySelector('.panel .foot')?.textContent.includes('完了'), null, { timeout: 15000 });
  await sleep(500);
  assert(mock.requests.at(-1).prompt.includes('<|plamo:val|>en<|plamo:msg|>'), 'en target after change');
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('[data-plamo-translate]').shadowRoot.querySelector('.panel'));
  // textarea 置き換え
  await setSettings({ targetLang: 'ja' });
  await page.evaluate(() => { const t = document.getElementById('ta'); t.focus(); t.setSelectionRange(0, t.value.length); });
  await page.evaluate(() => chrome?.runtime); // noop (isolated world 無し)
  await sw.evaluate(async (u) => {
    const tabs = await chrome.tabs.query({});
    const tab = tabs.filter((t) => t.url === u).at(-1);
    await chrome.tabs.sendMessage(tab.id, { type: 'translate-selection' });
  }, `${base}/page.html`);
  const rep = page.locator('[data-plamo-translate] .panel button.primary');
  await rep.waitFor({ timeout: 5000 });
  await page.waitForFunction(() => document.querySelector('[data-plamo-translate]').shadowRoot.querySelector('.panel .foot')?.textContent.includes('完了'), null, { timeout: 15000 });
  await rep.click();
  eq(await page.inputValue('#ta'), 'こんにちは世界、これは編集可能なテキストです。', 'textarea replaced');
  await page.close();
});

await test('content: icon disabled via option -> no icon', async () => {
  await setSettings({ showSelectionIcon: false });
  const page = await ctx.newPage();
  await page.goto(`${base}/page.html`);
  await sleep(300);
  await page.locator('#p1').click({ clickCount: 3 });
  await sleep(500);
  eq(await page.locator('[data-plamo-translate] .sel-icon').isVisible().catch(() => false), false);
  await page.close();
  await setSettings({ showSelectionIcon: true });
});

await test('content: full-page translation in place, viewport-first, history, skip ja/code, restore', async () => {
  const page = await ctx.newPage();
  await page.goto(`${base}/page.html`);
  mock.requests.length = 0;
  await sw.evaluate(async (u) => {
    const tab = (await chrome.tabs.query({})).filter((t) => t.url === u).at(-1);
    await chrome.tabs.sendMessage(tab.id, { type: 'page-translate', action: 'start' });
  }, `${base}/page.html`);
  await page.waitForFunction(() => document.getElementById('p4').textContent.startsWith('【訳】'), null, { timeout: 30000 });
  eq(await page.textContent('#p1'), '会議は来週の月曜日に変更されました。');
  eq(await page.textContent('#p3'), 'これはすでに日本語の段落なので翻訳されないはずです。', 'ja paragraph untouched');
  eq(await page.textContent('#code'), 'const x = 1; // do not translate');
  assert((await page.textContent('#p2')).includes('【訳】'), 'p2 translated (link kept)');
  eq(await page.locator('#p2 a').count(), 1, 'link preserved');
  assert(!mock.requests.some((r) => r.prompt.includes('これはすでに日本語')), 'ja paragraph never sent');
  assert(!mock.requests.some((r) => r.prompt.includes('do not translate')), 'code never sent');
  assert(mock.requests.some((r) => r.prompt.includes('<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>会議は来週') || r.prompt.includes('<|plamo:msg|>会議は来週')), 'history passed');
  // 先頭は表示領域内の h1
  assert(lastInputOf(mock.requests[0].prompt).startsWith('Project update'), 'first = h1 (viewport first)');
  await page.locator('[data-plamo-translate] .bar').waitFor();
  await page.screenshot({ path: path.join(SHOTS, 'page-translated.png') });
  await page.locator('[data-plamo-translate] .bar button', { hasText: '原文に戻す' }).click();
  eq(await page.textContent('#p1'), 'The meeting has been rescheduled to next Monday.', 'restored');
  assert((await page.textContent('#p2')).includes('project dashboard'), 'p2 restored');
  eq(await page.locator('#p2 a').count(), 1);
  await page.close();
});

await test('content: page translation cancel via toolbar stops queue', async () => {
  const page = await ctx.newPage();
  await page.goto(`${base}/page.html`);
  await page.evaluate(() => { const p = document.getElementById('p1'); p.textContent = 'SLOW paragraph that never ends'; });
  mock.state.aborted = 0;
  await sw.evaluate(async (u) => {
    const tab = (await chrome.tabs.query({})).filter((t) => t.url === u).at(-1);
    await chrome.tabs.sendMessage(tab.id, { type: 'page-translate', action: 'start' });
  }, `${base}/page.html`);
  await page.locator('[data-plamo-translate] .bar button', { hasText: '翻訳を停止' }).waitFor({ timeout: 5000 });
  await sleep(600);
  await page.locator('[data-plamo-translate] .bar button', { hasText: '翻訳を停止' }).click();
  await sleep(800);
  assert(mock.state.aborted >= 1, 'in-flight aborted');
  await page.close();
});

function lastInputOf(p) { const i = p.lastIndexOf('<|plamo:tag|>input'); const r = p.slice(i); const m = r.indexOf('<|plamo:msg|>'); return r.slice(m + 13, r.indexOf('<|plamo:tag|>output')); }

// ------------------------------------------------------------------ (b) WASM
const wasmSettings = (file, size = '0.8b') => ({ maxTokens: 48, backend: 'wasm', modelSize: size, modelUrlOverride: `${base}${file}`, sourceLang: 'en', targetLang: 'ja', wasmThreads: 0 });

if (modelFiles['/stories.gguf']) {
  await test('wasm: plumbing (offscreen + wllama worker + cross-origin isolation) with tiny non-PLaMo GGUF', async () => {
    await setSettings(wasmSettings('/stories.gguf'));
    const p = await openPopup();
    await p.fill('#input', 'Once upon a time');
    await p.waitForFunction(() => {
      const o = document.getElementById('output');
      return !o.classList.contains('empty') && o.textContent.length > 0 && !/準備中/.test(o.textContent);
    }, null, { timeout: 60000 });
    const out = await p.textContent('#output');
    const st = await p.textContent('#statusText');
    const iso = await sw.evaluate(async () => {
      const r = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] });
      return r.length;
    });
    eq(iso, 1, 'offscreen document exists');
    await p.close(); // 進行中のジョブはポート切断でキャンセルされる
    return `output=${JSON.stringify(out.slice(0, 60))} status=${st}`;
  });
}

if (modelFiles['/plamo.gguf'] && !process.env.E2E_SKIP_PLAMO) {
  await test('wasm: real PLaMo 3 0.8B Q4_K_M GGUF -> translation (or clear unsupported error)', async () => {
    await sw.evaluate(async () => { await chrome.runtime.sendMessage({ type: 'offscreen-dispose' }).catch(() => {}); });
    await setSettings(wasmSettings('/plamo.gguf'));
    const p = await openPopup();
    const t0 = Date.now();
    await p.fill('#input', 'The meeting has been rescheduled to next Monday.');
    try {
      await p.waitForFunction(() => {
        const o = document.getElementById('output');
        return o.classList.contains('err') || /会議/.test(o.textContent);
      }, null, { timeout: 120000 });
    } catch (e) {
      console.log('DUMP popup:', await p.textContent('#statusText'), '|', await p.textContent('#output'), '|', await p.textContent('#meta'));
      throw e;
    }
    const out = await p.textContent('#output');
    const ms = Date.now() - t0;
    await p.screenshot({ path: path.join(SHOTS, 'popup-wasm.png') });
    await p.close();
    if (/会議|ミーティング/.test(out)) return `WASM TRANSLATION OK in ${ms}ms: ${out}`;
    assert(/PLaMo 3 のトークナイザに未対応/.test(out), 'friendly unsupported error, got: ' + out);
    return `WASM unsupported (expected with wllama 3.8.1) after ${ms}ms: ${out.slice(0, 200)}`;
  });
}

if (process.env.E2E_DEBUG) console.log('requests', mock.requests.length);
await ctx.close();
await mock.close();
const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
fs.writeFileSync(path.join(SCRATCH, 'e2e-results.json'), JSON.stringify(results, null, 2));
process.exit(failed.length ? 1 : 0);
