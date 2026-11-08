import { describe, expect, it } from 'vitest';
import { DEFAULT_SETTINGS, SETTINGS_VERSION, endpointOf, migrateSettings } from '../src/core/settings';
import { interpretHealth } from '../src/engine/local-server';
import { statusSummary } from '../src/core/status-view';

describe('settings migration', () => {
  it('fresh install -> macOS app @ 18080 (no write)', () => {
    const { settings, changed } = migrateSettings(undefined);
    expect(changed).toBe(false);
    expect(settings.backend).toBe('app');
    expect(settings.appEndpoint).toBe('http://127.0.0.1:18080');
    expect(settings.endpoint).toBe('http://127.0.0.1:8080');
    expect(endpointOf(settings)).toBe('http://127.0.0.1:18080');
    expect(DEFAULT_SETTINGS.version).toBe(SETTINGS_VERSION);
  });

  it('v1 default (server @ 8080, saved as a whole object) -> app; other settings kept', () => {
    const v1 = { backend: 'server', endpoint: 'http://127.0.0.1:8080', targetLang: 'en', glossary: [{ source: 'a', target: 'b' }] };
    const { settings, changed } = migrateSettings(v1);
    expect(changed).toBe(true);
    expect(settings.backend).toBe('app');
    expect(settings.version).toBe(2);
    expect(settings.appEndpoint).toBe('http://127.0.0.1:18080');
    expect(settings.endpoint).toBe('http://127.0.0.1:8080');
    expect(settings.targetLang).toBe('en');
    expect(settings.glossary).toEqual([{ source: 'a', target: 'b' }]);
  });

  it('v1 default endpoint variants count as default', () => {
    for (const ep of ['http://localhost:8080', 'http://127.0.0.1:8080/', 'http://127.0.0.1:8080/v1', '', undefined]) {
      expect(migrateSettings({ backend: 'server', endpoint: ep }).settings.backend).toBe('app');
    }
    expect(migrateSettings({ targetLang: 'fr' }).settings.backend).toBe('app');
  });

  it('v1 server with customized endpoint -> stays server, endpoint kept', () => {
    const { settings } = migrateSettings({ backend: 'server', endpoint: 'http://127.0.0.1:8081' });
    expect(settings.backend).toBe('server');
    expect(settings.endpoint).toBe('http://127.0.0.1:8081');
    expect(settings.appEndpoint).toBe('http://127.0.0.1:18080');
  });

  it('v1 wasm: -> app unless a model URL override is set', () => {
    expect(migrateSettings({ backend: 'wasm' }).settings.backend).toBe('app');
    expect(migrateSettings({ backend: 'wasm', modelUrlOverride: 'http://x/m.gguf' }).settings.backend).toBe('wasm');
  });

  it('v2 settings are left alone (explicit llama-server @ 8080 is respected)', () => {
    const v2 = { ...DEFAULT_SETTINGS, backend: 'server' as const, endpoint: 'http://127.0.0.1:8080' };
    const { settings, changed } = migrateSettings(v2);
    expect(changed).toBe(false);
    expect(settings.backend).toBe('server');
    expect(migrateSettings({ ...DEFAULT_SETTINGS, backend: 'wasm' }).settings.backend).toBe('wasm');
  });

  it('unknown backend -> default', () => {
    expect(migrateSettings({ version: 2, backend: 'nope' }).settings.backend).toBe('app');
  });
});

describe('health (shared/local-api.md)', () => {
  const model = { id: 'plamo-3-translate-0.8b', size: '0.8b', label: '0.8B', quant: 'Q4_K_M', loaded: true };
  it('ok / loading / no_model / forbidden', () => {
    expect(interpretHealth('app', 200, { status: 'ok', model }).state).toBe('ok');
    expect(interpretHealth('app', 503, { status: 'loading', model }).state).toBe('loading');
    const nm = interpretHealth('app', 503, { status: 'no_model', model: { ...model, loaded: false } });
    expect(nm.state).toBe('no_model');
    expect(nm.message).toContain('『モデル』画面でダウンロード');
    const f = interpretHealth('app', 403, { error: { message: '許可されていません', type: 'forbidden_origin', code: 403 } });
    expect(f.state).toBe('forbidden');
    expect(f.message).toContain('forbidden_origin');
    expect(f.message).toContain('許可されていません');
  });
  it('llama-server responses', () => {
    expect(interpretHealth('server', 200, { status: 'ok' }).state).toBe('ok');
    expect(interpretHealth('server', 503, { error: { code: 503, message: 'Loading model' } }).state).toBe('loading');
  });
  it('status summary text', () => {
    expect(statusSummary({ backend: 'app', state: 'ready', modelLabel: '0.8B Q4_K_M' }).text).toBe('macOS アプリ · 0.8B Q4_K_M — 接続済み');
    const nr = statusSummary({ backend: 'app', state: 'not_running', everConnected: false });
    expect(nr.text).toBe('macOS アプリが起動していません');
    expect(nr.canLaunch).toBe(true);
    expect(nr.showSetup).toBe(true);
    expect(statusSummary({ backend: 'app', state: 'not_running', everConnected: true }).showSetup).toBe(false);
    expect(statusSummary({ backend: 'app', state: 'no_model', modelLabel: '2B Q4_K_M' }).hint).toBe(
      'macOS アプリの『モデル』画面でダウンロードしてください',
    );
  });
});

describe('easy Japanese code migration', () => {
  it('migrates stored ja(easy) to ja-easy', () => {
    const { settings, changed } = migrateSettings({ version: SETTINGS_VERSION, backend: 'app', targetLang: 'ja(easy)' });
    expect(settings.targetLang).toBe('ja-easy');
    expect(changed).toBe(true);
  });
});
