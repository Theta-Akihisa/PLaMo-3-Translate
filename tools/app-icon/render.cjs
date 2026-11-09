// icon.html を Chromium で 1024px の原本 PNG に書き出す。
// usage: node tools/app-icon/render.cjs <出力ディレクトリ>
const path = require('node:path');
const fs = require('node:fs');
const { chromium } = require('playwright');

(async () => {
  const out = path.resolve(process.argv[2] || 'icon-masters');
  fs.mkdirSync(out, { recursive: true });
  const html = 'file://' + path.join(__dirname, 'icon.html');
  const variants = {
    'full': '?shape=full',                       // iOS（全面・角丸なし）
    'rounded': '?shape=rounded',                 // macOS / Chrome（角丸 + 余白 + 影）
    'rounded-simple': '?shape=rounded&detail=simple', // 16〜32px 用
  };
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  for (const [name, query] of Object.entries(variants)) {
    await page.goto(html + query);
    await page.evaluate(() => document.fonts.ready);
    await page.locator('#icon').screenshot({ path: path.join(out, `${name}.png`), omitBackground: true });
    console.log('rendered', name);
  }
  await browser.close();
})();
