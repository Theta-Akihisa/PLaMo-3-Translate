import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  ApiError,
  classifyError,
  CompletionSseParser,
  IncompleteStreamError,
  serverComplete,
  UnreachableError,
} from '../src/engine/local-server';
import { Pfml3Error } from '../src/core/pfml3';

const chunk = (text: string, finish: string | null = null) =>
  `data: ${JSON.stringify({ choices: [{ index: 0, text, finish_reason: finish }] })}\n\n`;

describe('CompletionSseParser', () => {
  it('accumulates text, records finish_reason "stop", completes on [DONE]', () => {
    const p = new CompletionSseParser();
    expect(p.push(chunk('こん') + chunk('にちは'))).toBe(true);
    expect(p.push(chunk('', 'stop'))).toBe(false);
    p.push('data: [DONE]\n\n');
    p.end();
    expect(p.done).toBe(true);
    expect(p.result()).toEqual({ text: 'こんにちは', finishReason: 'stop', truncated: false });
  });

  it('finish_reason "length" -> truncated', () => {
    const p = new CompletionSseParser();
    p.push(chunk('途中まで') + chunk('', 'length') + 'data: [DONE]\n\n');
    p.end();
    expect(p.result()).toEqual({ text: '途中まで', finishReason: 'length', truncated: true });
  });

  it('finish_reason on the last text chunk is kept', () => {
    const p = new CompletionSseParser();
    p.push(chunk('abc', 'length') + 'data: [DONE]\n\n');
    expect(p.result().truncated).toBe(true);
  });

  it('lines split across chunks and CRLF line endings', () => {
    const p = new CompletionSseParser();
    const all = chunk('Hello').replace(/\n/g, '\r\n') + chunk(' world', 'stop') + 'data: [DONE]\r\n\r\n';
    for (const c of all.match(/[\s\S]{1,7}/g)!) p.push(c);
    p.end();
    expect(p.result()).toEqual({ text: 'Hello world', finishReason: 'stop', truncated: false });
  });

  it('stream that ends without [DONE] and without finish_reason is an error', () => {
    const p = new CompletionSseParser('app');
    p.push(chunk('途中'));
    p.end();
    expect(() => p.result()).toThrow(IncompleteStreamError);
    expect(() => p.result()).toThrow(/途中で途切れました/);
  });

  it('final data line without trailing newline is parsed', () => {
    const p = new CompletionSseParser();
    p.push(chunk('はい') + 'data: ' + JSON.stringify({ choices: [{ text: '。', finish_reason: 'length' }] }));
    expect(p.text).toBe('はい');
    expect(p.end()).toBe(true);
    expect(p.result()).toEqual({ text: 'はい。', finishReason: 'length', truncated: true });
    const q = new CompletionSseParser();
    q.push(chunk('x', 'stop') + 'data: [DONE]');
    q.end();
    expect(q.done).toBe(true);
  });

  it('ignores comments, non-data lines, bad JSON and anything after [DONE]', () => {
    const p = new CompletionSseParser();
    p.push(': keep-alive\nevent: message\ndata: {not json\n' + chunk('ok', 'stop') + 'data: [DONE]\n' + chunk('ignored'));
    p.end();
    expect(p.result().text).toBe('ok');
  });

  it('error object in the stream throws ApiError with the server message', () => {
    const p = new CompletionSseParser('server');
    expect(() => p.push('data: {"error":{"message":"context too long","type":"invalid_request","code":400}}\n')).toThrow(
      /llama-server.*context too long/,
    );
  });
});

function sseResponse(parts: string[], { failAfter = false } = {}): Response {
  const enc = new TextEncoder();
  let i = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(ctl) {
      if (i < parts.length) ctl.enqueue(enc.encode(parts[i++]));
      else if (failAfter) ctl.error(new TypeError('network error'));
      else ctl.close();
    },
  });
  return new Response(body, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
}

describe('serverComplete', () => {
  afterEach(() => vi.unstubAllGlobals());
  const run = (onText = (_: string) => {}) =>
    serverComplete({ kind: 'app', endpoint: 'http://127.0.0.1:1', prompt: 'p', maxTokens: 8, signal: new AbortController().signal, onText });

  it('returns text + truncated flag for finish_reason "length"', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([chunk('途中'), chunk('まで', 'length'), 'data: [DONE]\n\n'])));
    const seen: string[] = [];
    const r = await run((t) => seen.push(t));
    expect(r).toEqual({ text: '途中まで', finishReason: 'length', truncated: true });
    expect(seen).toEqual(['途中', '途中まで']);
  });

  it('connection closed before [DONE] -> IncompleteStreamError (not partial success)', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([chunk('途中')])));
    await expect(run()).rejects.toBeInstanceOf(IncompleteStreamError);
  });

  it('network error while reading the body -> IncompleteStreamError', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([chunk('途中')], { failAfter: true })));
    await expect(run()).rejects.toBeInstanceOf(IncompleteStreamError);
  });

  it('final line without newline at end of body', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([chunk('a'), 'data: {"choices":[{"text":"b","finish_reason":"stop"}]}'])));
    expect(await run()).toEqual({ text: 'ab', finishReason: 'stop', truncated: false });
  });

  it('HTTP 400 -> ApiError classified as request; connection refused -> unreachable', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('{"error":{"message":"bad","type":"invalid_request","code":400}}', { status: 400 })),
    );
    const e = await run().catch((x) => x);
    expect(e).toBeInstanceOf(ApiError);
    expect(classifyError(e)).toBe('request');
    vi.stubGlobal('fetch', vi.fn(async () => Promise.reject(new TypeError('Failed to fetch'))));
    const u = await run().catch((x) => x);
    expect(u).toBeInstanceOf(UnreachableError);
    expect(classifyError(u)).toBe('unreachable');
  });
});

describe('classifyError', () => {
  it('maps errors to kinds', () => {
    expect(classifyError(new Pfml3Error('x'))).toBe('input');
    expect(classifyError(new ApiError('x', 413))).toBe('request');
    expect(classifyError(new ApiError('x', 409, 'model_not_installed'))).toBe('fatal');
    expect(classifyError(new ApiError('x', 403, 'forbidden_origin'))).toBe('fatal');
    expect(classifyError(new ApiError('x', 500))).toBe('other');
    expect(classifyError(new IncompleteStreamError('app'))).toBe('other');
  });
});
