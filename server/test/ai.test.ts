import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { chat, chatStream, deltaText, normalizeChat, speech, verifyKey } from '../src/ai/openai-compat.js';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { ensureOwner, migrate, openDb, type Db } from '../src/db.js';
import { createSetupToken } from '../src/admin/auth.js';

describe('reply shapes from different providers', () => {
  it('reads OpenAI, togpt.ir and Responses-API replies', () => {
    expect(normalizeChat({ choices: [{ message: { content: 'سلام' } }], usage: { prompt_tokens: 3, completion_tokens: 2 } }))
      .toMatchObject({ text: 'سلام', usage: { input: 3, output: 2 } });
    expect(normalizeChat({ text: 'درود', usage: { input_tokens: 25, output_tokens: 120, total_tokens: 145 } }))
      .toMatchObject({ text: 'درود', usage: { input: 25, output: 120 } });
    expect(normalizeChat({ output_text: 'hi' }).text).toBe('hi');
    expect(normalizeChat({ output: [{ content: [{ text: 'a' }, { text: 'b' }] }] }).text).toBe('ab');
    const tc = normalizeChat({ choices: [{ message: { content: null, tool_calls: [{ id: '1', type: 'function', function: { name: 'get_weather', arguments: '{"location":"تهران"}' } }] } }] });
    expect(tc.toolCalls[0].function.name).toBe('get_weather');
  });

  it('reads stream chunks of every shape', () => {
    expect(deltaText({ choices: [{ delta: { content: 'یک' } }] })).toBe('یک');
    expect(deltaText({ text: 'دو' })).toBe('دو');
    expect(deltaText({ delta: 'سه' })).toBe('سه');
    expect(deltaText({ choices: [{ delta: {} }] })).toBe('');
  });
});

const sse = (lines: string[]) => new Response(new ReadableStream({
  start(c) { for (const l of lines) c.enqueue(new TextEncoder().encode(l)); c.close(); },
}), { headers: { 'content-type': 'text/event-stream' } });

describe('client', () => {
  it('chat sends the OpenAI request and reads a togpt.ir reply', async () => {
    let sent: { url: string; body: Record<string, unknown>; auth: string } | null = null;
    const f = (async (url: string, init: RequestInit) => {
      sent = { url, body: JSON.parse(String(init.body)), auth: (init.headers as Record<string, string>).authorization };
      return Response.json({ text: 'پاسخ', usage: { input_tokens: 5, output_tokens: 7 } });
    }) as unknown as typeof fetch;
    const r = await chat({ baseUrl: 'https://togpt.ir/api/v1', apiKey: 'k1', fetch: f }, { model: 'openai/gpt-5', messages: [{ role: 'user', content: 'سلام' }] });
    expect(r).toMatchObject({ text: 'پاسخ', usage: { input: 5, output: 7 } });
    expect(sent!.url).toBe('https://togpt.ir/api/v1/chat/completions');
    expect(sent!.auth).toBe('Bearer k1');
    expect(sent!.body).toMatchObject({ model: 'openai/gpt-5', stream: false });
  });

  it('streams SSE (split across chunks) and falls back to a plain reply', async () => {
    const f1 = (async () => sse(['data: {"choices":[{"delta":{"content":"سل"}}]}\n\nda', 'ta: {"choices":[{"delta":{"content":"ام"}}]}\n\n', 'data: [DONE]\n\n'])) as unknown as typeof fetch;
    const parts: string[] = [];
    for await (const t of chatStream({ baseUrl: 'x', apiKey: 'k', fetch: f1 }, { model: 'm', messages: [] })) parts.push(t);
    expect(parts.join('')).toBe('سلام');

    const f2 = (async () => Response.json({ text: 'کامل' })) as unknown as typeof fetch;
    const all: string[] = [];
    for await (const t of chatStream({ baseUrl: 'x', apiKey: 'k', fetch: f2 }, { model: 'm', messages: [] })) all.push(t);
    expect(all).toEqual(['کامل']);
  });

  it('maps errors to Persian, including 402 (no credit)', async () => {
    const f = (async () => Response.json({ error: 'low' }, { status: 402 })) as unknown as typeof fetch;
    await expect(chat({ baseUrl: 'x', apiKey: 'k', fetch: f }, { model: 'm', messages: [] })).rejects.toThrow('اعتبار حساب');
  });

  it('text to speech returns audio bytes', async () => {
    const f = (async () => new Response(new Uint8Array([73, 68, 51]), { headers: { 'content-type': 'audio/mpeg' } })) as unknown as typeof fetch;
    const r = await speech({ baseUrl: 'x', apiKey: 'k', fetch: f }, { model: 'elevenlabs/eleven-v4', input: 'سلام', voice: 'george' });
    expect(r.contentType).toBe('audio/mpeg');
    expect(r.audio.length).toBe(3);
  });

  it('verifies a key without spending credit (401 = bad key, 400 = good key)', async () => {
    const f = (async (_u: string, init: RequestInit) => {
      const ok = (init.headers as Record<string, string>).authorization === 'Bearer good';
      return Response.json({ error: { message: ok ? 'messages required' : 'Incorrect API key' } }, { status: ok ? 400 : 401 });
    }) as unknown as typeof fetch;
    await expect(verifyKey({ baseUrl: 'x', apiKey: 'good', fetch: f })).resolves.toBeUndefined();
    await expect(verifyKey({ baseUrl: 'x', apiKey: 'bad', fetch: f })).rejects.toThrow('رد شد');
  });
});

// ── togpt.ir end to end through the admin panel (fake network) ──
describe('togpt.ir in the admin panel', () => {
  let db: Db, app: FastifyInstance, cookie = '';
  const H = { 'x-loomi-admin': '1' };
  const fake = (async (url: string, init?: RequestInit) => {
    const u = String(url), auth = ((init?.headers ?? {}) as Record<string, string>).authorization;
    if (u === 'https://togpt.ir/api/v1/models') return Response.json({ object: 'list', data: [{ id: 'openai/gpt-5' }, { id: 'anthropic/claude-sonnet-4.6' }] });
    if (u === 'https://togpt.ir/api/v1/chat/completions') {
      if (auth !== 'Bearer tg-good') return Response.json({ error: { code: 'invalid_api_key' } }, { status: 401 });
      const b = JSON.parse(String(init?.body));
      if (!b.messages?.length) return Response.json({ error: { message: 'messages required' } }, { status: 400 });
      if (b.model === 'broken/model') return Response.json({ error: 'down' }, { status: 503 });
      return Response.json({ text: 'سلام! من لومی هستم.', usage: { input_tokens: 30, output_tokens: 8 } });
    }
    return new Response('{}', { status: 404 });
  }) as unknown as typeof fetch;

  beforeAll(async () => {
    const config = { ...loadConfig({}), dataDir: ':memory:', masterKey: 'e'.repeat(64) };
    db = await openDb(config); await migrate(db); await ensureOwner(db);
    app = await buildApp({ db, config, fetcher: fake });
    await app.inject({ method: 'POST', url: '/admin/api/setup', headers: H, payload: { token: await createSetupToken(db), password: 'a-strong-password' } });
    const r = await app.inject({ method: 'POST', url: '/admin/api/login', headers: H, payload: { password: 'a-strong-password' } });
    cookie = String(r.headers['set-cookie']).split(';')[0];
  });
  afterAll(async () => { await app.close(); await db.close(); });

  it('rejects a wrong key even though the model list is public', async () => {
    const r = await app.inject({ method: 'POST', url: '/admin/api/providers/keys', headers: { cookie, ...H }, payload: { provider: 'togpt', apiKey: 'tg-wrong' } });
    expect(r.json()).toMatchObject({ lastTestOk: false });
  });

  it('accepts the right key, chats, and falls back when the main model fails', async () => {
    const k = (await app.inject({ method: 'POST', url: '/admin/api/providers/keys', headers: { cookie, ...H }, payload: { provider: 'togpt', apiKey: 'tg-good' } })).json();
    expect(k).toMatchObject({ provider: 'togpt', baseUrl: 'https://togpt.ir/api/v1', lastTestOk: true, models: ['anthropic/claude-sonnet-4.6', 'openai/gpt-5'] });

    await app.inject({ method: 'PUT', url: '/admin/api/providers/routes', headers: { cookie, ...H }, payload: { capability: 'chat', keyId: k.id, model: 'broken/model', fallbackKeyId: k.id, fallbackModel: 'openai/gpt-5' } });
    const t = await app.inject({ method: 'POST', url: '/admin/api/providers/try', headers: { cookie, ...H }, payload: { prompt: 'سلام' } });
    expect(t.statusCode).toBe(200);
    expect(t.json()).toMatchObject({ text: 'سلام! من لومی هستم.', model: 'openai/gpt-5', usedFallback: true, usage: { input: 30, output: 8 } });
  });
});
