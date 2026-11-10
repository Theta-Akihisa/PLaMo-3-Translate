import type { Form, GlossaryItem } from './pfml3';
import type { SizeId } from './catalog';

/**
 * - `app`: macOS アプリ「PLaMo Translate」のローカル API（推奨・既定。shared/local-api.md）
 * - `server`: 素の llama-server（上級者向け）
 * - `wasm`: ブラウザ内 wllama（実験的。同梱 llama.cpp が PLaMo 3 トークナイザ未対応のため現在は動かない）
 */
export type BackendId = 'app' | 'server' | 'wasm';

export interface Settings {
  /** 設定スキーマのバージョン (マイグレーション用) */
  version: number;
  backend: BackendId;
  /** llama-server / WASM 用のモデルサイズ。macOS アプリではアプリ側の選択が正 (この値は使わない) */
  modelSize: SizeId;
  quant: string;
  /** macOS アプリの API エンドポイント */
  appEndpoint: string;
  /** llama-server のエンドポイント */
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

export const SETTINGS_VERSION = 2;
export const APP_ENDPOINT = 'http://127.0.0.1:18080';
export const SERVER_ENDPOINT = 'http://127.0.0.1:8080';

export const DEFAULT_SETTINGS: Settings = {
  version: SETTINGS_VERSION,
  backend: 'app',
  modelSize: '0.8b',
  quant: 'Q4_K_M',
  appEndpoint: APP_ENDPOINT,
  endpoint: SERVER_ENDPOINT,
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

/** v1 の既定エンドポイント (llama-server と旧 macOS アプリ API の共通ポート 8080) */
function isLegacyDefaultEndpoint(ep: unknown): boolean {
  if (typeof ep !== 'string' || !ep.trim()) return true;
  const u = ep.trim().replace(/\/+$/, '').replace(/\/v1$/, '').toLowerCase();
  return u === 'http://127.0.0.1:8080' || u === 'http://localhost:8080';
}

/**
 * 保存済み設定を現在のスキーマに変換する (純関数)。
 * v1 (version なし) → v2:
 * - `server` + 既定エンドポイント (8080) → `app` (macOS アプリ, 18080)。
 *   v1 は設定を丸ごと保存していたので、既定値のままの人もここに当たる。
 * - `server` + ユーザーが変えたエンドポイント → `server` のまま (エンドポイントも維持)。
 * - `wasm` (PLaMo 3 は読み込めない) → モデル URL を上書きしていなければ `app`。上書きしていれば維持。
 */
export function migrateSettings(raw: unknown): { settings: Settings; changed: boolean } {
  if (!raw || typeof raw !== 'object') return { settings: { ...DEFAULT_SETTINGS }, changed: false };
  const r = { ...(raw as Record<string, unknown>) };
  const version = typeof r.version === 'number' ? r.version : 1;
  let changed = false;
  if (version < 2) {
    changed = true;
    const backend = r.backend;
    if (backend === 'wasm') {
      if (!(typeof r.modelUrlOverride === 'string' && r.modelUrlOverride.trim())) r.backend = 'app';
    } else if (backend === 'server' || backend === undefined) {
      if (isLegacyDefaultEndpoint(r.endpoint)) {
        r.backend = 'app';
        r.endpoint = SERVER_ENDPOINT;
      } else {
        r.backend = 'server';
      }
    }
    r.version = 2;
  }
  if (r.backend !== 'app' && r.backend !== 'server' && r.backend !== 'wasm') {
    r.backend = DEFAULT_SETTINGS.backend;
    changed = true;
  }
  const settings = { ...DEFAULT_SETTINGS, ...(r as Partial<Settings>), version: SETTINGS_VERSION };
  // やさしい日本語の旧表記を移行
  if (settings.targetLang === 'ja(easy)') {
    settings.targetLang = 'ja-easy';
    changed = true;
  }
  if (typeof settings.appEndpoint !== 'string' || !settings.appEndpoint.trim()) settings.appEndpoint = APP_ENDPOINT;
  if (typeof settings.endpoint !== 'string' || !settings.endpoint.trim()) settings.endpoint = SERVER_ENDPOINT;
  return { settings, changed };
}

/** 現在のバックエンドが接続する HTTP エンドポイント */
export function endpointOf(s: Settings): string {
  return s.backend === 'app' ? s.appEndpoint : s.endpoint;
}

export async function loadSettings(): Promise<Settings> {
  const r = await chrome.storage.local.get(KEY);
  const { settings, changed } = migrateSettings(r[KEY]);
  if (changed) await chrome.storage.local.set({ [KEY]: settings });
  return settings;
}

let saveChain: Promise<unknown> = Promise.resolve();

/** 拡張機能のページ / Service Worker 間で共有できる Web Locks (content script ではページのオリジンになるので使わない) */
function extensionLocks(): LockManager | undefined {
  const g = globalThis as { navigator?: { locks?: LockManager }; location?: { protocol?: string } };
  return g.location?.protocol === 'chrome-extension:' ? g.navigator?.locks : undefined;
}

/**
 * 設定の一部を保存する。読み込み→マージ→書き込みを直列化するので、同時に呼んでも更新が失われない
 * (同じコンテキスト内はプロミスの連鎖で、拡張機能のページ同士は Web Locks で)。
 */
export function saveSettings(patch: Partial<Settings>): Promise<Settings> {
  const write = async (): Promise<Settings> => {
    const cur = await loadSettings();
    const next = { ...cur, ...patch, version: SETTINGS_VERSION };
    await chrome.storage.local.set({ [KEY]: next });
    return next;
  };
  const locked = (): Promise<Settings> => {
    const locks = extensionLocks();
    return locks ? (locks.request('plamo-translate-settings', write) as Promise<Settings>) : write();
  };
  const p = saveChain.then(locked, locked);
  saveChain = p.catch(() => {});
  return p;
}

export function onSettingsChanged(cb: (s: Settings) => void): void {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes[KEY]) cb(migrateSettings(changes[KEY].newValue).settings);
  });
}
