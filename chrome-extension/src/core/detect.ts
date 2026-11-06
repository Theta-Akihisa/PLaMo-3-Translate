import { LANGUAGES, TARGET_LANGUAGES } from './catalog';

export interface Detected {
  /** languages.json に存在する言語コード (信頼できるときのみ)。なければ null */
  code: string | null;
  /** 参考表示用 (信頼できなくても最有力候補) */
  guess: string | null;
  reliable: boolean;
}

const MAP: Record<string, string> = {
  zh: 'zh-hans', 'zh-cn': 'zh-hans', 'zh-hans': 'zh-hans', 'zh-tw': 'zh-hant', 'zh-hant': 'zh-hant', 'zh-hk': 'zh-hant',
  iw: 'he', in: 'id', fil: 'tl', jw: 'jv',
};
const KNOWN = new Set(LANGUAGES.map((l) => l.code));

export function mapDetected(lang: string): string | null {
  const l = lang.toLowerCase();
  const m = MAP[l] ?? l.split('-')[0];
  return KNOWN.has(m) ? m : null;
}

export function detectLanguage(text: string): Promise<Detected> {
  const sample = text.slice(0, 600);
  return new Promise((resolve) => {
    try {
      chrome.i18n.detectLanguage(sample, (r) => {
        const top = r?.languages?.[0];
        const code = top ? mapDetected(top.language) : null;
        const reliable = !!r?.isReliable && !!code;
        resolve({ code: reliable ? code : null, guess: code, reliable });
      });
    } catch {
      resolve({ code: null, guess: null, reliable: false });
    }
  });
}

/**
 * DeepL 風の「スマートな翻訳先」: 検出した翻訳元が翻訳先と同じなら、
 * 翻訳先を英語 (翻訳先が英語のときは日本語) に切り替える。
 */
export function smartTarget(detected: string | null, target: string): string {
  if (!detected) return target;
  const same = detected === target || (detected === 'ja' && target === 'ja(easy)');
  if (!same) return target;
  return detected === 'en' ? 'ja' : 'en';
}

export function langJa(code: string): string {
  return TARGET_LANGUAGES.find((l) => l.code === code)?.ja ?? code;
}
