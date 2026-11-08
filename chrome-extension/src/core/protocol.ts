import type { Form, HistoryItem } from './pfml3';
import type { BackendId } from './settings';

/** UI からの翻訳リクエスト。未指定の項目は設定値で補われる。 */
export interface TranslateRequest {
  text: string;
  sourceLang?: string; // 'auto' | code
  targetLang?: string;
  form?: Form | 'none';
  history?: HistoryItem[];
}

/**
 * - `not_running`: macOS アプリ / サーバーに接続できない (接続拒否)
 * - `no_model`: macOS アプリで選択中のモデルが未ダウンロード
 */
export type EngineState = 'idle' | 'downloading' | 'loading' | 'ready' | 'error' | 'not_running' | 'no_model';

export interface EngineStatus {
  backend: BackendId;
  state: EngineState;
  /** ダウンロード進捗 */
  loaded?: number;
  total?: number;
  /** 例: "0.8B Q4_K_M" */
  modelLabel?: string;
  message?: string;
  /** wasm のみ: マルチスレッドかどうか */
  threads?: number;
  crossOriginIsolated?: boolean;
  /** app / server: 接続先 */
  endpoint?: string;
  /** app のみ: 一度でも接続できたことがあるか (未接続ならセットアップ手順へ誘導) */
  everConnected?: boolean;
  /** app のみ: 「アプリを起動」後、起動待ち中 */
  launching?: boolean;
  /** app のみ: アプリのバージョン */
  appVersion?: string;
}

/** macOS アプリ GET /v1/models の 1 エントリ (shared/local-api.md) */
export interface AppModel {
  id: string;
  size: string;
  label: string;
  installed: boolean;
  active: boolean;
  quant?: string;
  installedQuants?: string[];
  sizeBytes?: number;
}

export interface AppModelsResult {
  ok: boolean;
  models: AppModel[];
  message?: string;
}

export interface AppSelectResult {
  ok: boolean;
  message: string;
  status?: EngineStatus;
}

/** 'translate' ポート: クライアント → Service Worker */
export type ClientToSw =
  | { op: 'start'; id: string; req: TranslateRequest }
  | { op: 'cancel'; id: string };

/** 'translate' ポート: Service Worker → クライアント */
export type SwToClient =
  | { op: 'phase'; id: string; phase: 'queued' | 'preparing' | 'generating'; status?: EngineStatus }
  | { op: 'chunk'; id: string; text: string }
  | { op: 'done'; id: string; text: string; ms: number }
  | { op: 'error'; id: string; message: string; cancelled?: boolean };

export const PORT_TRANSLATE = 'plamo-translate';
export const PORT_ENGINE_PREFIX = 'plamo-engine:';

/** Service Worker ↔ Offscreen (WASM) */
export interface ModelSpec {
  size: string;
  quant: string;
  url: string;
  sizeBytes: number;
  label: string;
}

export type SwToOffscreen =
  | { op: 'run'; prompt: string; maxTokens: number; model: ModelSpec; threads: number }
  | { op: 'prepare'; model: ModelSpec; threads: number }
  | { op: 'cancel' };

export type OffscreenToSw =
  | { op: 'status'; status: EngineStatus }
  | { op: 'chunk'; text: string }
  | { op: 'done'; text: string }
  | { op: 'error'; message: string; cancelled?: boolean };

/** 一回きりの runtime メッセージ */
export type RuntimeMessage =
  | { type: 'getStatus' }
  | { type: 'prepare' }
  | { type: 'testConnection'; endpoint?: string; backend?: BackendId }
  /** macOS アプリを URL スキームで起動し、/health をポーリングする (応答は最終 EngineStatus) */
  | { type: 'launchApp' }
  | { type: 'appModels' }
  | { type: 'appSelectModel'; id: string }
  | { type: 'openOptions' }
  | { type: 'engine-status'; status: EngineStatus }
  | { type: 'page-state'; state: PageState }
  // popup/background → content script
  | { type: 'get-selection' }
  | { type: 'translate-selection'; text?: string }
  | { type: 'page-translate'; action: 'start' | 'restore' | 'cancel' | 'toggle' | 'state' };

export interface PageState {
  mode: 'idle' | 'translating' | 'translated';
  done: number;
  total: number;
  error?: string;
}
