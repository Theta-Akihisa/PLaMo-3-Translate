import { afterEach, describe, expect, it } from 'vitest';
import { loadSettings, saveSettings } from '../src/core/settings';

/** chrome.storage.local の非同期モック (get / set の間にランダムな遅延を入れて競合を起こしやすくする) */
function installStorage() {
  let stored: Record<string, unknown> = {};
  const tick = () => new Promise((r) => setTimeout(r, Math.random() * 5));
  const local = {
    get: async (k: string) => {
      await tick();
      return k in stored ? { [k]: structuredClone(stored[k]) } : {};
    },
    set: async (o: Record<string, unknown>) => {
      await tick();
      stored = { ...stored, ...structuredClone(o) };
    },
  };
  (globalThis as any).chrome = { storage: { local } };
  return local;
}

describe('saveSettings', () => {
  afterEach(() => {
    delete (globalThis as any).chrome;
  });

  it('serializes concurrent saves so no update is lost', async () => {
    installStorage();
    const results = await Promise.all([
      saveSettings({ targetLang: 'en' }),
      saveSettings({ sourceLang: 'fr' }),
      saveSettings({ form: 'polite' }),
      saveSettings({ maxTokens: 2048 }),
    ]);
    const s = await loadSettings();
    expect(s).toMatchObject({ targetLang: 'en', sourceLang: 'fr', form: 'polite', maxTokens: 2048 });
    // 後の呼び出しは前の更新を含んだ設定を返す
    expect(results[3]).toMatchObject({ targetLang: 'en', sourceLang: 'fr', form: 'polite', maxTokens: 2048 });
  });

  it('a failed save does not block later saves', async () => {
    const local = installStorage();
    const set = local.set;
    local.set = async () => Promise.reject(new Error('quota'));
    await expect(saveSettings({ context: 'x' })).rejects.toThrow('quota');
    local.set = set;
    expect((await saveSettings({ context: 'y' })).context).toBe('y');
    expect((await loadSettings()).context).toBe('y');
  });
});
