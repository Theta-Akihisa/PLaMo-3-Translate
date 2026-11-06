import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
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
    await chrome.storage.local.set({ settings: { ...cur, ...p } });
  }, patch);
};
const openPopup = async () => {
  const p = await ctx.newPage();
  await p.setViewportSize({ width: 380, height: 600 });
  await p.goto(`chrome-extension://${extId}/popup.html`);
  return p;
};

// ------------------------------------------------------------------ (a) ローカルサーバー (mock)
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
  await p.screenshot({ path: path.join(SHOTS, 'popup.png') });
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
  await p.screenshot({ path: path.join(SHOTS, 'options.png'), fullPage: true });
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
mock.close();
const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
fs.writeFileSync(path.join(SCRATCH, 'e2e-results.json'), JSON.stringify(results, null, 2));
process.exit(failed.length ? 1 : 0);
