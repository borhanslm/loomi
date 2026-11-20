import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { ensureOwner, migrate, openDb, type Db } from '../src/db.js';
import { createPairCode } from '../src/devices.js';
import { takeDueReminders } from '../src/items.js';
import { byRules, itemLine } from '../src/brain/ask.js';
import type { Item } from '../src/items.js';

const TEH = 210;
const MIN = 60_000;

describe('reminders, snooze and ask', () => {
  let db: Db, app: FastifyInstance, token = '', ownerId = 0;
  let aiReply: string | null = null;
  const fake = (async (url: string) => {
    if (!String(url).endsWith('/chat/completions') || aiReply === null) return Response.json({ data: [] });
    return Response.json({ choices: [{ message: { content: aiReply } }] });
  }) as unknown as typeof fetch;
  const auth = () => ({ authorization: `Bearer ${token}` });
  const capture = async (text: string) =>
    (await app.inject({ method: 'POST', url: '/v1/capture', headers: auth(), payload: { text, tzOffset: TEH } })).json().items as Item[];
  const patch = async (id: string, payload: object) =>
    (await app.inject({ method: 'PATCH', url: `/v1/items/${id}`, headers: auth(), payload })).json() as Item;

  beforeAll(async () => {
    const config = { ...loadConfig({}), dataDir: ':memory:', masterKey: 'e'.repeat(64) };
    db = await openDb(config); await migrate(db);
    ownerId = (await ensureOwner(db)).id;
    app = await buildApp({ db, config, fetcher: fake, reminderEveryMs: 0 });
    const { code } = await createPairCode(db, ownerId, 5);
    token = (await app.inject({ method: 'POST', url: '/v1/pair', payload: { code, name: 'گوشی' } })).json().token;
  });
  afterAll(async () => { await app.close(); await db.close(); });

  it('sends a due reminder exactly once, and again after a snooze', async () => {
    const [it0] = await capture('زنگ به مامان');
    const due = new Date(Date.now() + 2 * MIN);
    const item = await patch(it0.id, { dueAt: due.toISOString() });
    expect(item.remindAt).toBe(due.toISOString());

    expect(await takeDueReminders(db, new Date(Date.now() + MIN))).toEqual([]); // not yet
    const fired = await takeDueReminders(db, new Date(Date.now() + 3 * MIN));
    expect(fired.map(r => [r.userId, r.item.id])).toEqual([[ownerId, it0.id]]);
    expect(await takeDueReminders(db, new Date(Date.now() + 4 * MIN))).toEqual([]); // only once

    const s = await app.inject({ method: 'POST', url: `/v1/items/${it0.id}/snooze`, headers: auth(), payload: { minutes: 10 } });
    expect(s.statusCode).toBe(200);
    const snoozed = s.json() as Item;
    expect(snoozed.dueAt).toBe(due.toISOString()); // the due time stays
    expect(Date.parse(snoozed.remindAt!)).toBeGreaterThan(Date.now() + 9 * MIN);
    expect(await takeDueReminders(db, new Date(Date.now() + 5 * MIN))).toEqual([]);
    expect((await takeDueReminders(db, new Date(Date.now() + 11 * MIN))).map(r => r.item.id)).toEqual([it0.id]);

    // a new due time clears the snooze
    const moved = await patch(it0.id, { dueAt: new Date(Date.now() + 60 * MIN).toISOString() });
    expect(moved.remindAt).toBe(moved.dueAt);
    // done items never remind
    const doneIt = await patch(it0.id, { done: true });
    expect(doneIt.remindAt).toBeNull();
    expect(await takeDueReminders(db, new Date(Date.now() + 61 * MIN))).toEqual([]);
  });

  it('skips items saved after their own time and very late ones', async () => {
    const [past] = await capture('جلسه‌ی صبح');
    await patch(past.id, { dueAt: new Date(Date.now() - 30 * MIN).toISOString() });
    expect(await takeDueReminders(db, new Date())).toEqual([]);

    const [late] = await capture('قبض برق');
    await patch(late.id, { dueAt: new Date(Date.now() + MIN).toISOString() });
    expect(await takeDueReminders(db, new Date(Date.now() + 8 * 60 * MIN))).toEqual([]); // server was down all night
  });

  it('rejects bad snoozes', async () => {
    expect((await app.inject({ method: 'POST', url: '/v1/items/nope/snooze', headers: auth(), payload: { minutes: 10 } })).statusCode).toBe(404);
    const [x] = await capture('یک چیز');
    expect((await app.inject({ method: 'POST', url: `/v1/items/${x.id}/snooze`, headers: auth(), payload: { minutes: 0 } })).statusCode).toBe(400);
    expect((await app.inject({ method: 'POST', url: `/v1/items/${x.id}/snooze`, payload: { minutes: 5 } })).statusCode).toBe(401);
  });

  it('answers questions by rules without a brain', async () => {
    const [meet] = await capture('جلسه با علی');
    const tomorrow10 = new Date(Date.now() + 86_400_000);
    await patch(meet.id, { dueAt: tomorrow10.toISOString() });
    const r = await app.inject({ method: 'POST', url: '/v1/ask', headers: auth(), payload: { question: 'فردا چی کار دارم؟', tzOffset: TEH } });
    expect(r.statusCode).toBe(200);
    const a = r.json();
    expect(a.via).toBe('rules');
    expect(a.answer).toContain('جلسه با علی');
    expect(a.items.map((i: Item) => i.id)).toContain(meet.id);

    const s = (await app.inject({ method: 'POST', url: '/v1/ask', headers: auth(), payload: { question: 'علی کیه؟' } })).json();
    expect(s.answer).toContain('جلسه با علی');
  });

  it('answers with the brain when one is set', async () => {
    const keyId = 'k-test';
    const { seal, parseMasterKey } = await import('../src/crypto.js');
    await db.query(`INSERT INTO provider_keys (id, provider, label, base_url, key_sealed, key_last4) VALUES ($1, 'custom', 'x', 'https://ai.example/v1', $2, 'abcd')`,
      [keyId, seal('sk-test', parseMasterKey('e'.repeat(64)))]);
    await db.query(`INSERT INTO capability_routes (capability, key_id, model) VALUES ('chat', $1, 'm1')`, [keyId]);
    const items = (await app.inject({ method: 'GET', url: '/v1/items?status=open', headers: auth() })).json() as Item[];
    const meet = items.find(i => i.title === 'جلسه با علی')!;
    aiReply = JSON.stringify({ answer: 'فردا با علی جلسه داری.', ids: [meet.id, 'not-a-real-id'] });
    const a = (await app.inject({ method: 'POST', url: '/v1/ask', headers: auth(), payload: { question: 'فردا چی دارم؟' } })).json();
    expect(a).toMatchObject({ answer: 'فردا با علی جلسه داری.', via: 'ai', model: 'm1' });
    expect(a.items.map((i: Item) => i.id)).toEqual([meet.id]);
    aiReply = null;
  });
});

describe('ask by rules', () => {
  const NOW = new Date('2026-11-18T07:00:00Z'); // Wednesday 27 Aban 1405, 10:30 Tehran
  const mk = (p: Partial<Item>): Item => ({
    id: Math.random().toString(36).slice(2), type: 'task', title: '', notes: null, dueAt: null, allDay: false, people: [], place: null,
    done: false, doneAt: null, createdAt: NOW.toISOString(), updatedAt: NOW.toISOString(), captureId: null, remindAt: null, ...p,
  });
  const pool = [
    mk({ type: 'shopping', title: 'شیر' }), mk({ type: 'shopping', title: 'نان' }),
    mk({ type: 'event', title: 'دندانپزشکی', dueAt: '2026-11-19T06:30:00Z' }),
    mk({ title: 'گزارش ماهانه', notes: 'برای مدیر' }),
  ];
  it('lists shopping', () => {
    expect(byRules('چی باید بخرم؟', pool, NOW, TEH).answer).toBe('۲ قلم برای خرید داری: شیر، نان.');
  });
  it('lists a day', () => {
    const a = byRules('فردا چی دارم', pool, NOW, TEH);
    expect(a.answer).toContain('پنجشنبه ۲۸ آبان');
    expect(a.answer).toContain('دندانپزشکی (۱۰:۰۰)');
    expect(byRules('پس فردا چی دارم', pool, NOW, TEH).answer).toContain('چیزی ثبت نکرده‌ای');
  });
  it('searches words', () => {
    expect(byRules('گزارش کی بود؟', pool, NOW, TEH).items.map(i => i.title)).toEqual(['گزارش ماهانه']);
    expect(byRules('مدیر', pool, NOW, TEH).items.length).toBe(1);
    expect(byRules('چی؟', pool, NOW, TEH).items).toEqual([]);
  });
  it('describes items for the brain', () => {
    expect(itemLine(pool[2], TEH)).toMatch(/قرار \| دندانپزشکی \| پنجشنبه 28 آبان، ساعت 10:00$/);
  });
});
