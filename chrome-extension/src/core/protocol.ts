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

export type EngineState = 'idle' | 'downloading' | 'loading' | 'ready' | 'error';

export interface EngineStatus {
  backend: BackendId;
  state: EngineState;
  /** ダウンロード進捗 */
  loaded?: number;
  total?: number;
  modelLabel?: string;
  message?: string;
  /** wasm のみ: マルチスレッドかどうか */
  threads?: number;
  crossOriginIsolated?: boolean;
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
  | { type: 'testConnection'; endpoint?: string }
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
