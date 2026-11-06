import type { Settings } from './settings';
import { buildPrompt, type Pfml3Request } from './pfml3';
import type { TranslateRequest } from './protocol';

/** UI リクエストと設定値から PFML3 リクエストを作る */
export function toPfml3(req: TranslateRequest, s: Settings): Pfml3Request {
  const targetLang = req.targetLang ?? s.targetLang;
  const form = req.form ?? s.form;
  const src = req.sourceLang ?? s.sourceLang;
  const glossary = s.glossary.filter((g) => g.source.trim() && g.target.trim());
  return {
    text: req.text,
    targetLang,
    sourceLang: src && src !== 'auto' ? src : null,
    form: targetLang === 'ja' && form !== 'none' ? form : null,
    context: s.context.trim() ? s.context : null,
    glossary: glossary.length ? glossary : null,
    history: req.history ?? [],
  };
}

export function promptFor(req: TranslateRequest, s: Settings): string {
  return buildPrompt(toPfml3(req, s));
}

export function normalizeEndpoint(url: string): string {
  let u = url.trim().replace(/\/+$/, '');
  u = u.replace(/\/v1$/, '');
  return u;
}

export function genId(): string {
  return Math.random().toString(36).slice(2) + Date.now().toString(36);
}
