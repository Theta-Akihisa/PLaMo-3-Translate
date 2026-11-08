// Playwright の Chromium で SVG を PNG に変換してアイコンを生成する (開発時に 1 度だけ実行し、結果は public/icons に置く)
import { createRequire } from 'node:module';
import { writeFileSync } from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const svg = (n) => `<svg xmlns="http://www.w3.org/2000/svg" width="${n}" height="${n}" viewBox="0 0 128 128">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#4f8bff"/><stop offset="1" stop-color="#2459c4"/></linearGradient></defs>
<rect width="128" height="128" rx="28" fill="url(#g)"/>
<text x="64" y="90" text-anchor="middle" font-family="Helvetica, Arial, sans-serif" font-weight="800" font-size="84" fill="#fff">P</text>
<path d="M88 22h20M98 22v8M92 36c4 10 10 14 18 16M108 36c-4 10-10 14-18 16" stroke="#fff" stroke-width="5" stroke-linecap="round" fill="none" opacity=".9"/></svg>`;
const b = await chromium.launch();
const p = await b.newPage();
for (const n of [16, 32, 48, 128]) {
  await p.setViewportSize({ width: n, height: n });
  await p.setContent(`<body style="margin:0;background:transparent">${svg(n)}</body>`);
  writeFileSync(new URL(`../public/icons/icon${n}.png`, import.meta.url), await p.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: n, height: n } }));
}
await b.close();
