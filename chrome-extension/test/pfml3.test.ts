import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { buildPrompt, cleanOutput, isValidLangCode, Pfml3Error } from '../src/core/pfml3';
import { smartTarget, mapDetected } from '../src/core/detect';
import { looksLikeLang } from '../src/core/lang-detect';
import { normalizeEndpoint } from '../src/core/util';
import { LANGUAGES, MODELS } from '../src/core/catalog';

const vectors = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../shared/pfml3-test-vectors.json', import.meta.url)), 'utf8'),
) as { vectors: { name: string; input: Record<string, unknown>; prompt?: string; error?: string }[] };

describe('PFML3 test vectors (byte-for-byte)', () => {
  for (const v of vectors.vectors) {
    it(v.name, () => {
      const i = v.input as {
        text: string; target_lang?: string; source_lang?: string; form?: 'plain' | 'polite';
        context?: string; glossary?: { source: string; target: string }[];
        history?: { source: string; translation: string }[];
      };
      expect(buildPrompt({
        text: i.text, targetLang: i.target_lang, sourceLang: i.source_lang, form: i.form,
        context: i.context, glossary: i.glossary, history: i.history,
      })).toBe(v.prompt);
    });
  }
  it('has vectors', () => expect(vectors.vectors.length).toBeGreaterThanOrEqual(10));
});

describe('validation', () => {
  it('rejects reserved tokens', () => {
    expect(() => buildPrompt({ text: 'a <|plamo:tag|> b' })).toThrow(Pfml3Error);
    expect(() => buildPrompt({ text: 'x', context: '<|plamo:msg|>' })).toThrow(Pfml3Error);
    expect(() => buildPrompt({ text: 'x', glossary: [{ source: '<|plamo:', target: 'y' }] })).toThrow(Pfml3Error);
  });
  it('rejects empty text (ASCII whitespace only)', () => {
    expect(() => buildPrompt({ text: ' \n\t' })).toThrow(Pfml3Error);
    expect(() => buildPrompt({ text: '　' })).not.toThrow(); // 全角空白は空と見なさない (公式テンプレート準拠)
  });
  it('form requires ja target', () => {
    expect(() => buildPrompt({ text: 'x', targetLang: 'en', form: 'plain' })).toThrow(Pfml3Error);
    expect(() => buildPrompt({ text: 'x', form: 'weird' as never })).toThrow(Pfml3Error);
  });
  it('validates language codes', () => {
    for (const c of ['ja', 'en', 'zh-hans', 'zh-hant', 'ja(easy)', 'ceb']) expect(isValidLangCode(c)).toBe(true);
    for (const c of ['EN', 'en-US', 'e', 'zh-hans-x', 'ja easy', 'jp1']) expect(isValidLangCode(c)).toBe(false);
    expect(() => buildPrompt({ text: 'x', targetLang: 'en-US' })).toThrow(Pfml3Error);
  });
  it('every language in languages.json is valid', () => {
    for (const l of LANGUAGES) expect(isValidLangCode(l.code)).toBe(true);
  });
});

describe('cleanOutput', () => {
  it('strips stop strings and trims', () => {
    expect(cleanOutput('  こんにちは。<|plamo:tag|>input')).toBe('こんにちは。');
    expect(cleanOutput('はい<|plamo:bos|>')).toBe('はい');
    expect(cleanOutput('\nはい\n')).toBe('はい');
  });
  it('hides partial stop prefix while streaming', () => {
    expect(cleanOutput('はい<|plamo:t')).toBe('はい');
    expect(cleanOutput('1 < 2')).toBe('1 < 2');
  });
});

describe('misc', () => {
  it('normalizeEndpoint', () => {
    expect(normalizeEndpoint('http://127.0.0.1:8080/')).toBe('http://127.0.0.1:8080');
    expect(normalizeEndpoint('http://x:1/v1/')).toBe('http://x:1');
  });
  it('catalog', () => {
    expect(MODELS.map((m) => m.size)).toEqual(['0.8b', '2b', '8b']);
  });
  it('smartTarget', () => {
    expect(smartTarget('ja', 'ja')).toBe('en');
    expect(smartTarget('en', 'en')).toBe('ja');
    expect(smartTarget('fr', 'ja')).toBe('ja');
    expect(smartTarget(null, 'ja')).toBe('ja');
  });
  it('mapDetected', () => {
    expect(mapDetected('zh-CN')).toBe('zh-hans');
    expect(mapDetected('zh-TW')).toBe('zh-hant');
    expect(mapDetected('iw')).toBe('he');
    expect(mapDetected('xx')).toBeNull();
  });
  it('looksLikeLang', () => {
    expect(looksLikeLang('これは日本語の文章です。', 'ja')).toBe(true);
    expect(looksLikeLang('The quick brown fox jumps over the lazy dog and the cat.', 'en')).toBe(true);
    expect(looksLikeLang('Bonjour tout le monde', 'ja')).toBe(false);
    expect(looksLikeLang('12345', 'ja')).toBe(true);
  });
});
