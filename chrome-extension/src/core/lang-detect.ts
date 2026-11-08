/**
 * 「既に翻訳先の言語である」ことを粗く判定するヒューリスティック。
 * ページ翻訳で不要な再翻訳を避けるためのもの。確信が持てなければ false。
 */
const RE = {
  kana: /[぀-ヿㇰ-ㇿ]/g,
  han: /[㐀-䶿一-鿿]/g,
  hangul: /[가-힯ᄀ-ᇿ]/g,
  latin: /[A-Za-zÀ-ɏ]/g,
  cyrillic: /[Ѐ-ӿ]/g,
  arabic: /[؀-ۿ]/g,
  thai: /[฀-๿]/g,
  devanagari: /[ऀ-ॿ]/g,
};

function count(s: string, re: RegExp): number {
  return (s.match(re) ?? []).length;
}

export function letterCount(s: string): number {
  return count(s, /\p{L}/gu);
}

export function looksLikeLang(text: string, lang: string): boolean {
  const letters = letterCount(text);
  if (letters === 0) return true; // 数字・記号のみ: 翻訳不要
  const kana = count(text, RE.kana);
  const han = count(text, RE.han);
  const hangul = count(text, RE.hangul);
  const latin = count(text, RE.latin);
  switch (lang) {
    case 'ja':
    case 'ja-easy':
    case 'ja(easy)':
      return kana / letters > 0.1 || (kana + han) / letters > 0.5;
    case 'zh-hans':
    case 'zh-hant':
      return han / letters > 0.5 && kana / letters < 0.05;
    case 'ko':
      return hangul / letters > 0.5;
    case 'ru':
    case 'uk':
    case 'bg':
    case 'be':
    case 'sr':
    case 'kk':
      return count(text, RE.cyrillic) / letters > 0.6;
    case 'ar':
    case 'fa':
    case 'ur':
      return count(text, RE.arabic) / letters > 0.6;
    case 'th':
      return count(text, RE.thai) / letters > 0.6;
    case 'hi':
    case 'mr':
    case 'ne':
      return count(text, RE.devanagari) / letters > 0.6;
    case 'en': {
      // ラテン文字が大半で、英語らしい高頻度語を含む場合のみ
      if (latin / letters < 0.9) return false;
      const words = text.toLowerCase().match(/[a-z']+/g) ?? [];
      if (words.length < 3) return false;
      const common = new Set(['the', 'and', 'of', 'to', 'in', 'is', 'that', 'for', 'it', 'with', 'as', 'on', 'are', 'this', 'be', 'by', 'you', 'we', 'can', 'from']);
      const hits = words.filter((w) => common.has(w)).length;
      return hits / words.length > 0.12;
    }
    default:
      return false;
  }
}
