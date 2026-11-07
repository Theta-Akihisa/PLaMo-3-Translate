import type { EngineStatus } from './protocol';
import type { BackendId } from './settings';

export const BACKEND_NAME: Record<BackendId, string> = {
  app: 'macOS アプリ',
  server: 'llama-server',
  wasm: 'ブラウザ内 (WASM)',
};

export interface StatusView {
  /** 1 行目 (例: "macOS アプリ · 0.8B Q4_K_M — 接続済み") */
  text: string;
  /** 2 行目の補足 */
  hint?: string;
  /** 「アプリを起動」ボタンを出す */
  canLaunch: boolean;
  /** セットアップ手順へのリンクを出す (一度も接続できていない) */
  showSetup: boolean;
}

/** EngineStatus を popup / 設定画面の表示に変換する (純関数) */
export function statusSummary(st: EngineStatus): StatusView {
  const name = BACKEND_NAME[st.backend];
  const withModel = st.modelLabel ? `${name} · ${st.modelLabel}` : name;
  if (st.backend === 'app') {
    switch (st.state) {
      case 'ready':
        return { text: `${withModel} — 接続済み`, canLaunch: false, showSetup: false };
      case 'loading':
        return { text: `${withModel} — 読み込み中`, hint: 'モデルを読み込み中です。しばらくお待ちください', canLaunch: false, showSetup: false };
      case 'no_model':
        return {
          text: `${withModel} — モデル未ダウンロード`,
          hint: 'macOS アプリの『モデル』画面でダウンロードしてください',
          canLaunch: false,
          showSetup: !st.everConnected,
        };
      case 'not_running':
        return {
          text: 'macOS アプリが起動していません',
          hint: st.launching
            ? 'macOS アプリの起動を待っています…'
            : st.message?.includes('起動できませんでした')
              ? st.message
              : undefined,
          canLaunch: true,
          showSetup: !st.everConnected,
        };
      default:
        return { text: `${name} — 接続エラー`, hint: st.message, canLaunch: false, showSetup: !st.everConnected };
    }
  }
  if (st.backend === 'server') {
    switch (st.state) {
      case 'ready':
        return { text: `${withModel} — 準備完了`, canLaunch: false, showSetup: false };
      case 'loading':
        return { text: `${withModel} — モデルを読み込み中…`, canLaunch: false, showSetup: false };
      case 'not_running':
        return { text: `${name} に接続できません`, hint: st.message, canLaunch: false, showSetup: false };
      default:
        return { text: `${name} — エラー`, hint: st.message, canLaunch: false, showSetup: false };
    }
  }
  let text = withModel;
  if (st.state === 'loading') text += ' — モデルを読み込み中…';
  else if (st.state === 'ready') text += ' — 準備完了';
  else if (st.message && st.state !== 'downloading') text += ` — ${st.message}`;
  return { text, canLaunch: false, showSetup: false };
}
