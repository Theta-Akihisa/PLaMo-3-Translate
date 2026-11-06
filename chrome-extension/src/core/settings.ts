import type { Form, GlossaryItem } from './pfml3';
import type { SizeId } from './catalog';

export type BackendId = 'wasm' | 'server';

export interface Settings {
  backend: BackendId;
  modelSize: SizeId;
  quant: string;
  endpoint: string;
  sourceLang: string; // 'auto' または言語コード
  targetLang: string;
  form: Form | 'none';
  glossary: GlossaryItem[];
  context: string;
  maxTokens: number;
  /** 上級者向け: モデル URL を上書き (WASM バックエンド)。空なら catalog の URL。 */
  modelUrlOverride: string;
  /** 上級者向け: WASM スレッド数 (0 = 自動) */
  wasmThreads: number;
  /** ページ翻訳で直前の段落を history として渡す数 */
  historyParagraphs: number;
  /** 選択テキストの横に翻訳アイコンを表示する (DeepL 風) */
  showSelectionIcon: boolean;
  /** 入力しながら自動翻訳 (ポップアップ) */
  liveTranslate: boolean;
}

/**
 * 既定バックエンド: 同梱の wllama (llama.cpp) が PLaMo 3 トークナイザ未対応のため、
 * 現時点ではローカルサーバーを既定にしている。WASM が対応したら 'wasm' に戻す。
 */
export const DEFAULT_SETTINGS: Settings = {
  backend: 'server',
  modelSize: '0.8b',
  quant: 'Q4_K_M',
  endpoint: 'http://127.0.0.1:8080',
  sourceLang: 'auto',
  targetLang: 'ja',
  form: 'none',
  glossary: [],
  context: '',
  maxTokens: 1024,
  modelUrlOverride: '',
  wasmThreads: 0,
  historyParagraphs: 2,
  showSelectionIcon: true,
  liveTranslate: true,
};

const KEY = 'settings';

export async function loadSettings(): Promise<Settings> {
  const r = await chrome.storage.local.get(KEY);
  return { ...DEFAULT_SETTINGS, ...(r[KEY] as Partial<Settings> | undefined) };
}

export async function saveSettings(patch: Partial<Settings>): Promise<Settings> {
  const cur = await loadSettings();
  const next = { ...cur, ...patch };
  await chrome.storage.local.set({ [KEY]: next });
  return next;
}

export function onSettingsChanged(cb: (s: Settings) => void): void {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes[KEY]) cb({ ...DEFAULT_SETTINGS, ...(changes[KEY].newValue as Partial<Settings>) });
  });
}
