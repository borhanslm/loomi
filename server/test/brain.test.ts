import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { byRules, understand } from '../src/brain/capture.js';
import { extractJson } from '../src/brain/llm.js';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { ensureOwner, migrate, openDb, type Db } from '../src/db.js';
import { createPairCode } from '../src/devices.js';
import { addKey, setRoute } from '../src/providers.js';
import { parseMasterKey } from '../src/crypto.js';
import { parseWhen } from '../src/fa/time.js';

const NOW = new Date('2026-11-18T07:00:00Z'); // Wed 10:30 Tehran
const TEH = 210;
const localTime = (d: Date | null) => (d ? new Date(d.getTime() + TEH * 60_000).toISOString().slice(0, 16).replace('T', ' ') : null);

describe('rules (no AI)', () => {
  it('splits a busy sentence into typed items with times', () => {
    const r = byRules('فردا ساعت ۱۰ جلسه با علی، قبلش قرارداد رو چاپ کنم. شیر و نون هم بخرم', NOW, TEH);
    expect(r.map(i => [i.type, i.title, localTime(i.dueAt)])).toEqual([
      ['event', 'جلسه با علی', '2026-11-19 10:00'],
      ['task', 'قرارداد چاپ کنم', '2026-11-19 10:00'],
      ['shopping', 'شیر', null],
      ['shopping', 'نون', null],
    ]);
  });
  it('understands a timed reminder', () => {
    const [i] = byRules('یک ساعت دیگه یادم بنداز به مامان زنگ بزنم', NOW, TEH);
    expect(i).toMatchObject({ type: 'reminder', title: 'به مامان زنگ بزنم' });
    expect(localTime(i.dueAt)).toBe('2026-11-18 11:30');
  });
  it('keeps ideas and notes', () => {
    expect(byRules('ایده: یه کافه کتاب کنار دانشگاه', NOW, TEH)[0]).toMatchObject({ type: 'idea', title: 'یه کافه کتاب کنار دانشگاه', dueAt: null });
  });
});

describe('AI understanding', () => {
  it('reads JSON wrapped in prose or fences', () => {
    expect(extractJson('Sure!\n```json\n{"items":[{"title":"a"}]}\n```')).toEqual({ items: [{ title: 'a' }] });
    expect(extractJson('{"a":"}"} trailing')).toEqual({ a: '}' });
  });
});

// ── through the API, with a fake AI provider ──
describe('capture API', () => {
  let db: Db, app: FastifyInstance, token = '', aiMode: 'good' | 'down' = 'good';
  const fake = (async (url: string, init?: RequestInit) => {
    if (!String(url).endsWith('/chat/completions')) return Response.json({ data: [] });
    if (aiMode === 'down') return Response.json({ error: 'down' }, { status: 503 });
    const body = JSON.parse(String(init?.body));
    if (!body.messages?.length) return Response.json({ error: 'messages required' }, { status: 400 });
    // reply in the togpt.ir shape: { text, usage }
    return Response.json({ text: JSON.stringify({ items: [
      { type: 'event', title: 'جلسه با علی', when_text: 'فردا ساعت ۱۰', when: '2026-11-19T10:00', all_day: false, people: ['علی'], place: null },
      { type: 'task', title: 'چاپ قرارداد', when_text: null, when: '2026-11-19T09:00', all_day: false, people: [], place: null },
      { type: 'shopping', title: 'شیر' }, { type: 'shopping', title: 'نان' },
      { type: 'weird', title: '' },
    ] }), usage: { input_tokens: 100, output_tokens: 50 } });
  }) as unknown as typeof fetch;
  const auth = () => ({ authorization: `Bearer ${token}` });

  beforeAll(async () => {
    const config = { ...loadConfig({}), dataDir: ':memory:', masterKey: 'f'.repeat(64) };
    db = await openDb(config); await migrate(db);
    const owner = await ensureOwner(db);
    app = await buildApp({ db, config, fetcher: fake });
    const { code } = await createPairCode(db, owner.id, 5);
    token = (await app.inject({ method: 'POST', url: '/v1/pair', payload: { code, name: 'گوشی' } })).json().token;
  });
  afterAll(async () => { await app.close(); await db.close(); });

  it('uses simple rules when no brain is configured', async () => {
    const r = await app.inject({ method: 'POST', url: '/v1/capture', headers: auth(), payload: { text: 'ایده: اپ دستور آشپزی', tzOffset: TEH } });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toMatchObject({ via: 'rules', warning: null, items: [{ type: 'idea', title: 'اپ دستور آشپزی' }] });
  });

  it('uses the AI brain once configured, and our parser for its time phrases', async () => {
    const k = await addKey(db, parseMasterKey('f'.repeat(64)), { provider: 'togpt', apiKey: 'tg-key' });
    await setRoute(db, { capability: 'chat', keyId: k.id, model: 'openai/gpt-5', fallbackKeyId: null, fallbackModel: null });
    const r = await app.inject({ method: 'POST', url: '/v1/capture', headers: auth(), payload: { text: 'فردا ساعت ۱۰ جلسه با علی، قبلش قرارداد رو چاپ کنم. شیر و نون هم بخرم', tzOffset: TEH, clientId: 'c-1' } });
    const j = r.json();
    expect(j).toMatchObject({ via: 'ai', model: 'openai/gpt-5', duplicate: false });
    expect(j.items.map((i: { type: string; title: string }) => `${i.type}:${i.title}`)).toEqual(['event:جلسه با علی', 'task:چاپ قرارداد', 'shopping:شیر', 'shopping:نان']);
    // the API runs on the real clock: «فردا ساعت ۱۰» is tomorrow 10:00 from today
    expect(j.items[0].dueAt).toBe(parseWhen('فردا ساعت ۱۰', new Date(), TEH)!.at.toISOString());
    expect(j.items[0].people).toEqual(['علی']);
    expect(localTime(new Date(j.items[1].dueAt))).toBe('2026-11-19 09:00');

    // the app retrying the same offline capture does not duplicate it
    const again = await app.inject({ method: 'POST', url: '/v1/capture', headers: auth(), payload: { text: 'whatever', clientId: 'c-1' } });
    expect(again.json()).toMatchObject({ duplicate: true });
    expect(again.json().items).toHaveLength(4);
  });

  it('falls back to rules (with a warning) when the AI is down', async () => {
    aiMode = 'down';
    const r = await app.inject({ method: 'POST', url: '/v1/capture', headers: auth(), payload: { text: 'یه ساعت دیگه یادم بنداز نون بخرم', tzOffset: TEH } });
    expect(r.json()).toMatchObject({ via: 'rules', items: [{ type: 'shopping', title: 'نون' }] });
    expect(r.json().warning).toContain('قواعد ساده');
    aiMode = 'good';
  });

  it('lists, searches, completes, edits and deletes items', async () => {
    const all = (await app.inject({ method: 'GET', url: '/v1/items?status=open', headers: auth() })).json();
    expect(all.length).toBeGreaterThanOrEqual(6);
    expect(all[0].dueAt).not.toBeNull(); // dated items first

    const found = (await app.inject({ method: 'GET', url: `/v1/items?q=${encodeURIComponent('علی')}`, headers: auth() })).json();
    expect(found.map((i: { title: string }) => i.title)).toContain('جلسه با علی');

    const milk = all.find((i: { title: string }) => i.title === 'شیر');
    const done = await app.inject({ method: 'PATCH', url: `/v1/items/${milk.id}`, headers: auth(), payload: { done: true } });
    expect(done.json()).toMatchObject({ done: true });
    expect((await app.inject({ method: 'GET', url: '/v1/items?status=open', headers: auth() })).json().find((i: { id: string }) => i.id === milk.id)).toBeUndefined();

    const edited = await app.inject({ method: 'PATCH', url: `/v1/items/${milk.id}`, headers: auth(), payload: { title: 'شیر کم‌چرب', done: false, dueAt: null } });
    expect(edited.json()).toMatchObject({ title: 'شیر کم‌چرب', done: false, dueAt: null });
    expect((await app.inject({ method: 'PATCH', url: `/v1/items/${milk.id}`, headers: auth(), payload: { title: '  ' } })).statusCode).toBe(400);

    expect((await app.inject({ method: 'DELETE', url: `/v1/items/${milk.id}`, headers: auth() })).statusCode).toBe(200);
    expect((await app.inject({ method: 'DELETE', url: `/v1/items/${milk.id}`, headers: auth() })).statusCode).toBe(404);
  });

  it('needs a device token', async () => {
    expect((await app.inject({ method: 'GET', url: '/v1/items' })).statusCode).toBe(401);
    expect((await app.inject({ method: 'POST', url: '/v1/capture', payload: { text: 'x' } })).statusCode).toBe(401);
  });

  it('understand() never throws without a brain', async () => {
    const u = await understand('سلام', NOW, TEH, null);
    expect(u.via).toBe('rules');
    expect(u.items.length).toBe(1);
  });
});
