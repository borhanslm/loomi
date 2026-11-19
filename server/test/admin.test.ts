import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { ensureOwner, migrate, openDb, type Db } from '../src/db.js';
import { createSetupToken } from '../src/admin/auth.js';

let db: Db, app: FastifyInstance;
const config = { ...loadConfig({}), dataDir: ':memory:', masterKey: 'c'.repeat(64), publicUrl: 'https://loomi.example' };
const H = { 'x-loomi-admin': '1' };

// Fake provider APIs: a valid key returns a model list; anything else is rejected.
const fakeFetch = (async (url: string | URL, init?: RequestInit) => {
  const h = (init?.headers ?? {}) as Record<string, string>;
  if (String(url) === 'https://gw.example/v1/models' && h.authorization === 'Bearer or-key-1234') return Response.json({ data: [{ id: 'm-b' }, { id: 'm-a' }] });
  const good = h['x-api-key'] === 'sk-ant-good' || h['xi-api-key'] === 'el-good';
  if (!good) return new Response('{}', { status: 401 });
  if (String(url).includes('anthropic')) return Response.json({ data: [{ id: 'claude-x' }, { id: 'claude-y' }] });
  return Response.json({ voices: [{ name: 'Sara', voice_id: 'v1' }] });
}) as typeof fetch;

let cookie = '';
const cookieFrom = (r: { headers: Record<string, unknown> }) => String(r.headers['set-cookie'] ?? '').split(';')[0];

beforeAll(async () => {
  db = await openDb(config);
  await migrate(db);
  await ensureOwner(db);
  app = await buildApp({ db, config, fetcher: fakeFetch });
});
afterAll(async () => { await app.close(); await db.close(); });

describe('admin setup and login', () => {
  it('serves the panel page with strict security headers', async () => {
    const r = await app.inject({ method: 'GET', url: '/admin/' });
    expect(r.statusCode).toBe(200);
    expect(r.body).toContain('پنل ادمین لومی');
    expect(r.headers['content-security-policy']).toContain("frame-ancestors 'none'");
  });

  it('requires a session for the API', async () => {
    expect((await app.inject({ method: 'GET', url: '/admin/api/overview' })).statusCode).toBe(401);
    expect((await app.inject({ method: 'GET', url: '/admin/api/state' })).json()).toMatchObject({ setupDone: false, signedIn: false });
  });

  it('rejects a bad setup token and a short password', async () => {
    const bad = await app.inject({ method: 'POST', url: '/admin/api/setup', headers: H, payload: { token: 'nope', password: 'long-enough-pass' } });
    expect(bad.statusCode).toBe(400);
    const short = await app.inject({ method: 'POST', url: '/admin/api/setup', headers: H, payload: { token: await createSetupToken(db), password: 'short' } });
    expect(short.statusCode).toBe(400);
  });

  it('sets the password with a one-time link, then logs in', async () => {
    const token = await createSetupToken(db);
    const r = await app.inject({ method: 'POST', url: '/admin/api/setup', headers: H, payload: { token, password: 'a-strong-password' } });
    expect(r.statusCode).toBe(200);
    expect(String(r.headers['set-cookie'])).toMatch(/HttpOnly/i);
    expect(String(r.headers['set-cookie'])).toMatch(/SameSite=Strict/i);
    // the same link cannot be used twice
    expect((await app.inject({ method: 'POST', url: '/admin/api/setup', headers: H, payload: { token, password: 'another-password' } })).statusCode).toBe(400);

    expect((await app.inject({ method: 'POST', url: '/admin/api/login', headers: H, payload: { password: 'wrong-password' } })).statusCode).toBe(401);
    const ok = await app.inject({ method: 'POST', url: '/admin/api/login', headers: H, payload: { password: 'a-strong-password' } });
    expect(ok.statusCode).toBe(200);
    cookie = cookieFrom(ok);
    const o = await app.inject({ method: 'GET', url: '/admin/api/overview', headers: { cookie } });
    expect(o.statusCode).toBe(200);
    expect(o.json()).toMatchObject({ masterKey: true, counts: { users: 1 } });
  });

  it('blocks state-changing calls without the admin header (CSRF)', async () => {
    const r = await app.inject({ method: 'POST', url: '/admin/api/devices/pair-code', headers: { cookie } });
    expect(r.statusCode).toBe(403);
  });
});

describe('admin devices', () => {
  it('creates a pairing code with a QR image', async () => {
    const r = await app.inject({ method: 'POST', url: '/admin/api/devices/pair-code', headers: { cookie, ...H } });
    expect(r.statusCode).toBe(200);
    const j = r.json();
    expect(j.code).toMatch(/^\d{8}$/);
    expect(j.qrSvg).toContain('<svg');
    const paired = await app.inject({ method: 'POST', url: '/v1/pair', payload: { code: j.code, name: 'گوشی', platform: 'android' } });
    expect(paired.statusCode).toBe(200);
    const list = (await app.inject({ method: 'GET', url: '/admin/api/devices', headers: { cookie } })).json();
    expect(list).toHaveLength(1);
    expect((await app.inject({ method: 'DELETE', url: `/admin/api/devices/${list[0].id}`, headers: { cookie, ...H } })).statusCode).toBe(200);
  });
});

describe('admin AI providers', () => {
  it('stores a key sealed, tests it, never returns it', async () => {
    const r = await app.inject({ method: 'POST', url: '/admin/api/providers/keys', headers: { cookie, ...H }, payload: { provider: 'anthropic', label: 'Claude من', apiKey: 'sk-ant-good' } });
    expect(r.statusCode).toBe(200);
    const k = r.json();
    expect(k).toMatchObject({ provider: 'anthropic', keyLast4: 'good', lastTestOk: true, models: ['claude-x', 'claude-y'] });
    expect(r.body).not.toContain('sk-ant-good');

    const raw = await db.query<{ key_sealed: string }>(`SELECT key_sealed FROM provider_keys WHERE id = $1`, [k.id]);
    expect(raw[0].key_sealed).toMatch(/^v1\./);
    expect(raw[0].key_sealed).not.toContain('sk-ant-good');

    const list = await app.inject({ method: 'GET', url: '/admin/api/providers', headers: { cookie } });
    expect(list.body).not.toContain('sk-ant-good');
    expect(list.body).not.toContain('key_sealed');
  });

  it('supports a custom OpenAI-compatible API (address + optional key)', async () => {
    const r = await app.inject({ method: 'POST', url: '/admin/api/providers/keys', headers: { cookie, ...H }, payload: { provider: 'custom', label: 'OpenRouter', baseUrl: 'https://gw.example/v1/', apiKey: 'or-key-1234' } });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toMatchObject({ provider: 'custom', baseUrl: 'https://gw.example/v1', keyLast4: '1234', lastTestOk: true, models: ['m-a', 'm-b'] });
    expect(r.body).not.toContain('or-key-1234');
    const bad = await app.inject({ method: 'POST', url: '/admin/api/providers/keys', headers: { cookie, ...H }, payload: { provider: 'custom', baseUrl: 'not a url' } });
    expect(bad.statusCode).toBe(400);
  });

  it('reports a rejected key in Persian', async () => {
    const r = await app.inject({ method: 'POST', url: '/admin/api/providers/keys', headers: { cookie, ...H }, payload: { provider: 'elevenlabs', apiKey: 'el-bad' } });
    expect(r.json()).toMatchObject({ lastTestOk: false, lastTestMsg: 'کلید رد شد (نامعتبر یا بدون اجازه).' });
  });

  it('routes capabilities only to providers that support them', async () => {
    const { keys } = (await app.inject({ method: 'GET', url: '/admin/api/providers', headers: { cookie } })).json();
    const claude = keys.find((k: { provider: string }) => k.provider === 'anthropic');
    const ok = await app.inject({ method: 'PUT', url: '/admin/api/providers/routes', headers: { cookie, ...H }, payload: { capability: 'chat', keyId: claude.id, model: 'claude-x' } });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().routes.find((r: { capability: string }) => r.capability === 'chat')).toMatchObject({ keyId: claude.id, model: 'claude-x' });
    const bad = await app.inject({ method: 'PUT', url: '/admin/api/providers/routes', headers: { cookie, ...H }, payload: { capability: 'tts', keyId: claude.id } });
    expect(bad.statusCode).toBe(400);
  });

  it('logs out', async () => {
    await app.inject({ method: 'POST', url: '/admin/api/logout', headers: { cookie, ...H } });
    expect((await app.inject({ method: 'GET', url: '/admin/api/overview', headers: { cookie } })).statusCode).toBe(401);
  });
});
