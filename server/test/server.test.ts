import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { ensureOwner, migrate, openDb, type Db } from '../src/db.js';
import { createPairCode } from '../src/devices.js';
import { open, parseMasterKey, seal } from '../src/crypto.js';

let db: Db, app: FastifyInstance, ownerId: number;
const config = { ...loadConfig({}), dataDir: ':memory:', publicUrl: 'https://loomi.example' };

beforeAll(async () => {
  db = await openDb(config);
  await migrate(db);
  await migrate(db); // idempotent
  ownerId = (await ensureOwner(db)).id;
  app = await buildApp({ db, config });
});
afterAll(async () => { await app.close(); await db.close(); });

const pair = async (code: string, name = 'گوشی من') =>
  app.inject({ method: 'POST', url: '/v1/pair', payload: { code, name, platform: 'android' } });

describe('health', () => {
  it('is public', async () => {
    const r = await app.inject({ method: 'GET', url: '/v1/health' });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toMatchObject({ ok: true, name: 'loomi', api: 1 });
  });
});

describe('pairing and devices', () => {
  it('rejects requests without a token', async () => {
    expect((await app.inject({ method: 'GET', url: '/v1/me' })).statusCode).toBe(401);
    expect((await app.inject({ method: 'GET', url: '/v1/me', headers: { authorization: 'Bearer lmi_nottherealtokennope' } })).statusCode).toBe(401);
  });

  it('pairs with a one-time code, exactly once', async () => {
    const { code } = await createPairCode(db, ownerId, 5);
    const r = await pair(code);
    expect(r.statusCode).toBe(200);
    const { token, device } = r.json();
    expect(token).toMatch(/^lmi_/);
    expect(device.name).toBe('گوشی من');

    const me = await app.inject({ method: 'GET', url: '/v1/me', headers: { authorization: `Bearer ${token}` } });
    expect(me.statusCode).toBe(200);
    expect(me.json().userId).toBe(ownerId);

    expect((await pair(code, 'دومی')).statusCode).toBe(400); // already used
  });

  it('rejects wrong and expired codes', async () => {
    expect((await pair('12345678')).statusCode).toBe(400);
    const { code } = await createPairCode(db, ownerId, -1);
    expect((await pair(code)).statusCode).toBe(400);
  });

  it('a paired device can invite another, list and revoke', async () => {
    const first = (await pair((await createPairCode(db, ownerId, 5)).code, 'گوشی')).json();
    const auth = { authorization: `Bearer ${first.token}` };
    const inv = await app.inject({ method: 'POST', url: '/v1/pair/codes', headers: auth });
    expect(inv.statusCode).toBe(200);
    const { code, qr } = inv.json();
    expect(JSON.parse(qr)).toEqual({ loomi: 1, url: 'https://loomi.example', code });

    const second = (await pair(code, 'دسکتاپ')).json();
    const list = await app.inject({ method: 'GET', url: '/v1/devices', headers: auth });
    expect(list.json().map((d: { name: string }) => d.name)).toContain('دسکتاپ');
    expect(JSON.stringify(list.json())).not.toContain('token');

    const del = await app.inject({ method: 'DELETE', url: `/v1/devices/${second.device.id}`, headers: auth });
    expect(del.statusCode).toBe(200);
    const after = await app.inject({ method: 'GET', url: '/v1/me', headers: { authorization: `Bearer ${second.token}` } });
    expect(after.statusCode).toBe(401); // revoked device is locked out
  });
});

describe('local pair code', () => {
  it('works from this machine and refuses proxied requests', async () => {
    const ok = await app.inject({ method: 'POST', url: '/v1/local/pair-code', remoteAddress: '127.0.0.1' });
    expect(ok.statusCode).toBe(200);
    expect((await pair(ok.json().code, 'از خط فرمان')).statusCode).toBe(200);

    const proxied = await app.inject({ method: 'POST', url: '/v1/local/pair-code', remoteAddress: '127.0.0.1', headers: { 'x-forwarded-for': '8.8.8.8' } });
    expect(proxied.statusCode).toBe(403);
    const remote = await app.inject({ method: 'POST', url: '/v1/local/pair-code', remoteAddress: '203.0.113.9' });
    expect(remote.statusCode).toBe(403);
  });
});

describe('crypto', () => {
  it('seals and opens secrets; tampering fails', () => {
    const key = parseMasterKey('a'.repeat(64));
    const s = seal('sk-ant-secret', key);
    expect(s).not.toContain('secret');
    expect(open(s, key)).toBe('sk-ant-secret');
    // flip one byte of the ciphertext (editing base64 text directly can leave the bytes unchanged)
    const [v, iv, tag, data] = s.split('.');
    const bytes = Buffer.from(data, 'base64url'); bytes[0] ^= 0xff;
    expect(() => open([v, iv, tag, bytes.toString('base64url')].join('.'), key)).toThrow();
    const tagBytes = Buffer.from(tag, 'base64url'); tagBytes[0] ^= 0xff;
    expect(() => open([v, iv, tagBytes.toString('base64url'), data].join('.'), key)).toThrow();
    expect(() => parseMasterKey('short')).toThrow();
  });
});

describe('openapi', () => {
  it('documents the routes', async () => {
    await app.ready();
    const doc = app.swagger() as { paths: Record<string, unknown> };
    expect(Object.keys(doc.paths)).toEqual(expect.arrayContaining(['/v1/health', '/v1/pair', '/v1/devices', '/v1/me']));
  });
});
