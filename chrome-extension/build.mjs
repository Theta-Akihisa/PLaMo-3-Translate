import { build } from 'esbuild';
import { cpSync, mkdirSync, rmSync, copyFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
// --e2e: Playwright E2E 用ビルド (dist-e2e/)。ページ内 UI の shadow root を open にする (__E2E__)。
// 配布用の dist/ には決して含めない。
const e2e = process.argv.includes('--e2e');
const dist = join(root, e2e ? 'dist-e2e' : 'dist');
rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });

const common = {
  bundle: true,
  target: 'chrome116',
  sourcemap: false,
  logLevel: 'info',
  legalComments: 'none',
  minify: process.env.NO_MINIFY ? false : true,
  define: { __E2E__: JSON.stringify(e2e) },
};
const src = (p) => join(root, 'src', p);

await Promise.all([
  build({ ...common, entryPoints: { background: src('background/index.ts'), content: src('content/index.ts') }, outdir: dist, format: 'iife' }),
  build({
    ...common,
    entryPoints: { offscreen: src('offscreen/offscreen.ts'), popup: src('popup/popup.ts'), options: src('options/options.ts') },
    outdir: dist,
    format: 'esm',
  }),
]);

cpSync(join(root, 'public'), dist, { recursive: true });
for (const f of ['popup/popup.html', 'popup/popup.css', 'options/options.html', 'options/options.css', 'offscreen/offscreen.html']) {
  copyFileSync(src(f), join(dist, f.split('/')[1]));
}
const wasm = join(root, 'node_modules/@wllama/wllama/esm/wasm/wllama.wasm');
if (!existsSync(wasm)) throw new Error('wllama.wasm not found: run npm install');
copyFileSync(wasm, join(dist, 'wllama.wasm'));
console.log('built ->', dist);
