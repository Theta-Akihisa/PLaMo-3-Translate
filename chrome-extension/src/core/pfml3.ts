/**
 * PFML3 プロンプトビルダー (shared/README.md の仕様)。
 * Jinja は使わず、公式チャットテンプレートと同じ文字列を直接組み立てる。
 * 先頭の <|plamo:bos|> は含めない (トークナイザ側で BOS を付加する)。
 */

export type Form = 'plain' | 'polite';

export interface HistoryItem {
  source: string;
  translation: string;
}

export interface GlossaryItem {
  source: string;
  target: string;
}

export interface Pfml3Request {
  text: string;
  targetLang?: string;
  sourceLang?: string | null;
  form?: Form | null;
  context?: string | null;
  glossary?: GlossaryItem[] | null;
  history?: HistoryItem[] | null;
}

export const STOP_STRINGS = ['<|plamo:tag|>', '<|plamo:bos|>'] as const;

export class Pfml3Error extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'Pfml3Error';
  }
}

// 公式テンプレートは ASCII の空白 (space, tab, CR, LF) のみで空判定する
const ASCII_WS = /^[ \t\r\n]*$/;

function checkText(value: unknown, name: string, allowEmpty = false): asserts value is string {
  if (typeof value !== 'string') throw new Pfml3Error(`${name} は文字列である必要があります`);
  if (!allowEmpty && ASCII_WS.test(value)) throw new Pfml3Error(`${name} が空です`);
  if (value.includes('<|plamo:')) {
    throw new Pfml3Error(`${name} に予約トークン (<|plamo:...) を含めることはできません`);
  }
}

/** やさしい日本語の旧表記 ja(easy) を PFML3 の ja-easy に正規化する（公式テンプレート 2026-11-07 版と同じ）。 */
export function normalizeLang(value: string): string {
  return value === 'ja(easy)' ? 'ja-easy' : value;
}

export function isValidLangCode(value: string): boolean {
  if (value === 'ja(easy)') return true;
  const parts = value.split('-');
  if (parts.length > 2) return false;
  if (parts[0].length !== 2 && parts[0].length !== 3) return false;
  if (parts.length === 2 && parts[1].length !== 4) return false;
  return /^[a-z-]+$/.test(value);
}

function checkLang(value: unknown, name: string): asserts value is string {
  checkText(value, name);
  if (!isValidLangCode(value)) {
    throw new Pfml3Error(
      `${name} は小文字の言語コード (en, ja, zh-hans, ja-easy など) で指定してください: ${value}`,
    );
  }
}

/** PFML3 プロンプト文字列を組み立てる。 */
export function buildPrompt(req: Pfml3Request): string {
  const targetLang = normalizeLang(req.targetLang ?? 'ja');
  const sourceLang = req.sourceLang != null ? normalizeLang(req.sourceLang) : null;
  const form = req.form ?? null;
  const context = req.context ?? null;
  const glossary = req.glossary ?? null;
  const history = req.history ?? [];

  checkText(req.text, 'text');
  checkLang(targetLang, 'target_lang');
  if (sourceLang !== null) checkLang(sourceLang, 'source_lang');
  if (context !== null) checkText(context, 'context', true);
  if (form !== null) {
    if ((form as string) !== 'plain' && (form as string) !== 'polite') {
      throw new Pfml3Error('form は plain または polite を指定してください');
    }
    if (targetLang !== 'ja') throw new Pfml3Error('form は翻訳先が ja のときのみ指定できます');
  }
  if (glossary !== null) {
    for (const g of glossary) {
      checkText(g.source, 'glossary source');
      checkText(g.target, 'glossary target');
    }
  }
  for (const h of history) {
    checkText(h.source, 'history source');
    checkText(h.translation, 'history translation');
  }

  const srcKey = sourceLang !== null ? `<|plamo:key|>lang<|plamo:val|>${sourceLang}` : '';
  let p = '<|plamo:tag|>dataset<|plamo:msg|>translation';
  if (context) p += `<|plamo:tag|>context<|plamo:msg|>${context}`;
  for (const h of history) {
    p += `<|plamo:tag|>input${srcKey}<|plamo:msg|>${h.source}`;
    p += `<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>${targetLang}<|plamo:msg|>${h.translation}`;
  }
  if (glossary && glossary.length > 0) {
    p += '<|plamo:tag|>glossary';
    for (const g of glossary) p += `<|plamo:index|>${g.source}<|plamo:item|>${g.target}`;
  }
  p += `<|plamo:tag|>input${srcKey}<|plamo:msg|>${req.text}`;
  p += `<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>${targetLang}`;
  if (form !== null) p += `<|plamo:key|>form<|plamo:val|>${form}`;
  p += '<|plamo:msg|>';
  return p;
}

/** 出力末尾に残った停止文字列を除去し、前後の空白を落とす。 */
export function cleanOutput(text: string): string {
  let out = text;
  let cut = -1;
  for (const s of STOP_STRINGS) {
    const i = out.indexOf(s);
    if (i >= 0 && (cut < 0 || i < cut)) cut = i;
  }
  if (cut >= 0) out = out.slice(0, cut);
  else {
    // ストリーミング途中で停止文字列の先頭だけが見えている場合も隠す
    for (const s of STOP_STRINGS) {
      for (let n = s.length - 1; n > 0; n--) {
        if (out.endsWith(s.slice(0, n))) {
          out = out.slice(0, out.length - n);
          break;
        }
      }
    }
  }
  return out.trim();
}
