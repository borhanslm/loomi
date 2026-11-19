// Admin panel: static pages at /admin/ and a JSON API at /admin/api/*.
// Every API call needs the admin session cookie; changes also need the
// `x-loomi-admin: 1` header (with SameSite=Strict, this blocks cross-site forgery).
import { statfs } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import fastifyStatic from '@fastify/static';
import cookie from '@fastify/cookie';
import QRCode from 'qrcode';
import type { Config } from '../config.js';
import type { Db } from '../db.js';
import { audit, createPairCode, revokeDevice } from '../devices.js';
import {
  AdminError, completeSetup, createSetupToken, hasAdminPassword, login, logout, MIN_PASSWORD, ownerRow, sessionUser,
} from './auth.js';
import {
  addKey, CAPABILITIES, deleteKey, endpointFor, type Fetcher, listKeys, listRoutes, PROVIDERS, ProviderError, type Route, setRoute, testKey,
} from '../providers.js';
import { AiError, chat } from '../ai/openai-compat.js';

const COOKIE = 'loomi_admin';
const ADMIN_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../admin');

declare module 'fastify' {
  interface FastifyRequest { adminUser?: number }
}

export interface AdminDeps {
  db: Db;
  config: Config;
  masterKey: Buffer | null;
  version: string;
  pairQr: (code: string) => string;
  onDevicesChanged: (userId: number) => void;
  fetcher?: Fetcher;
}

export async function adminPlugin(app: FastifyInstance, deps: AdminDeps) {
  const { db, config, masterKey } = deps;
  const started = Date.now();
  await app.register(cookie);

  // Strict security headers for the panel pages and API.
  app.addHook('onSend', async (req, reply) => {
    if (!req.url.startsWith('/admin')) return;
    reply.header('content-security-policy', "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
    reply.header('x-frame-options', 'DENY');
    reply.header('referrer-policy', 'no-referrer');
    reply.header('x-content-type-options', 'nosniff');
    if (req.url.startsWith('/admin/api')) reply.header('cache-control', 'no-store');
  });

  await app.register(fastifyStatic, { root: ADMIN_DIR, prefix: '/admin/', decorateReply: false, index: ['index.html'] });
  app.get('/admin', (_req, reply) => reply.redirect('/admin/'));

  const PUBLIC = new Set(['/admin/api/state', '/admin/api/login', '/admin/api/setup']);
  app.addHook('onRequest', async (req, reply) => {
    const p = req.url.split('?')[0];
    if (!p.startsWith('/admin/api/')) return;
    if (req.method !== 'GET' && req.headers['x-loomi-admin'] !== '1') return reply.code(403).send({ error: 'درخواست نامعتبر.' });
    if (PUBLIC.has(p)) return;
    const uid = await sessionUser(db, req.cookies[COOKIE]);
    if (!uid) return reply.code(401).send({ error: 'دوباره وارد شوید.' });
    req.adminUser = uid;
  });

  const fail = (reply: FastifyReply, e: unknown) => {
    if (e instanceof AdminError || e instanceof ProviderError) return reply.code(400).send({ error: e.message });
    throw e;
  };
  const setCookie = (req: FastifyRequest, reply: FastifyReply, sid: string) =>
    reply.setCookie(COOKIE, sid, { path: '/admin', httpOnly: true, sameSite: 'strict', secure: req.protocol === 'https', maxAge: 12 * 3600 });

  // ── login ──
  app.get('/admin/api/state', { schema: { hide: true } }, async req => ({
    setupDone: await hasAdminPassword(db),
    signedIn: !!(await sessionUser(db, req.cookies[COOKIE])),
    minPassword: MIN_PASSWORD,
    version: deps.version,
  }));

  app.post<{ Body: { token: string; password: string } }>('/admin/api/setup', {
    schema: { hide: true, body: { type: 'object', required: ['token', 'password'], properties: { token: { type: 'string', maxLength: 100 }, password: { type: 'string', maxLength: 200 } } } },
    config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
  }, async (req, reply) => {
    try {
      const uid = await completeSetup(db, req.body.token, req.body.password);
      await audit(db, 'admin.password_set', { userId: uid }, { ip: req.ip });
      const s = await login(db, req.body.password, req.ip);
      if (s) setCookie(req, reply, s.sid);
      return { ok: true };
    } catch (e) { return fail(reply, e); }
  });

  app.post<{ Body: { password: string } }>('/admin/api/login', {
    schema: { hide: true, body: { type: 'object', required: ['password'], properties: { password: { type: 'string', maxLength: 200 } } } },
    config: { rateLimit: { max: 5, timeWindow: '1 minute' } },
  }, async (req, reply) => {
    const s = await login(db, req.body.password, req.ip);
    if (!s) {
      await audit(db, 'admin.login_failed', {}, { ip: req.ip });
      return reply.code(401).send({ error: 'رمز اشتباه است.' });
    }
    await audit(db, 'admin.login', { userId: s.userId }, { ip: req.ip });
    setCookie(req, reply, s.sid);
    return { ok: true };
  });

  app.post('/admin/api/logout', { schema: { hide: true } }, async (req, reply) => {
    await logout(db, req.cookies[COOKIE]);
    reply.clearCookie(COOKIE, { path: '/admin' });
    return { ok: true };
  });

  // ── dashboard ──
  app.get('/admin/api/overview', { schema: { hide: true } }, async () => {
    let disk: { total: number; free: number } | null = null;
    try {
      const s = await statfs(config.databaseUrl ? '/' : path.resolve(config.dataDir === ':memory:' ? '.' : config.dataDir));
      disk = { total: s.blocks * s.bsize, free: s.bavail * s.bsize };
    } catch { /* not available */ }
    const n = async (sql: string) => Number((await db.query<{ n: string }>(sql))[0].n);
    return {
      version: deps.version,
      publicUrl: config.publicUrl,
      uptimeSec: Math.round((Date.now() - started) / 1000),
      memory: { total: os.totalmem(), free: os.freemem(), process: process.memoryUsage().rss },
      load: os.loadavg()[0], cpus: os.cpus().length,
      disk,
      masterKey: !!masterKey,
      counts: {
        users: await n(`SELECT count(*)::text AS n FROM users`),
        devices: await n(`SELECT count(*)::text AS n FROM devices WHERE revoked_at IS NULL`),
        providers: await n(`SELECT count(*)::text AS n FROM provider_keys`),
      },
    };
  });

  // ── devices ──
  app.get('/admin/api/devices', { schema: { hide: true } }, async () =>
    (await db.query<{ id: string; name: string; platform: string; user_name: string; created_at: Date; last_seen: Date }>(
      `SELECT d.id, d.name, d.platform, u.name AS user_name, d.created_at, d.last_seen FROM devices d JOIN users u ON u.id = d.user_id
       WHERE d.revoked_at IS NULL ORDER BY d.last_seen DESC`)).map(d => ({
      id: d.id, name: d.name, platform: d.platform, user: d.user_name,
      createdAt: new Date(d.created_at).toISOString(), lastSeen: new Date(d.last_seen).toISOString(),
    })));

  app.post('/admin/api/devices/pair-code', { schema: { hide: true } }, async req => {
    const owner = (await ownerRow(db))!;
    const r = await createPairCode(db, owner.id, config.pairMinutes);
    await audit(db, 'pair.code', { userId: req.adminUser }, { via: 'admin' });
    const qr = deps.pairQr(r.code);
    return { ...r, qr, qrSvg: await QRCode.toString(qr, { type: 'svg', margin: 1, errorCorrectionLevel: 'M' }) };
  });

  app.delete<{ Params: { id: string } }>('/admin/api/devices/:id', { schema: { hide: true } }, async (req, reply) => {
    const owner = (await ownerRow(db))!;
    if (!(await revokeDevice(db, owner.id, req.params.id))) return reply.code(404).send({ error: 'این دستگاه پیدا نشد.' });
    await audit(db, 'device.revoked', { userId: req.adminUser }, { revoked: req.params.id, via: 'admin' });
    deps.onDevicesChanged(owner.id);
    return { ok: true };
  });

  // ── AI providers (API keys) ──
  app.get('/admin/api/providers', { schema: { hide: true } }, async () => ({
    catalog: PROVIDERS, capabilities: CAPABILITIES, keys: await listKeys(db), routes: await listRoutes(db), masterKey: !!masterKey,
  }));

  app.post<{ Body: { provider: string; label?: string; apiKey?: string; baseUrl?: string } }>('/admin/api/providers/keys', {
    schema: { hide: true, body: { type: 'object', required: ['provider'], properties: {
      provider: { type: 'string', maxLength: 30 }, label: { type: 'string', maxLength: 40 }, apiKey: { type: 'string', maxLength: 500 }, baseUrl: { type: 'string', maxLength: 300 },
    } } },
  }, async (req, reply) => {
    try {
      const k = await addKey(db, masterKey, req.body);
      await audit(db, 'provider.key_added', { userId: req.adminUser }, { provider: k.provider, label: k.label, last4: k.keyLast4 });
      return await testKey(db, masterKey, k.id, deps.fetcher);
    } catch (e) { return fail(reply, e); }
  });

  app.post<{ Params: { id: string } }>('/admin/api/providers/keys/:id/test', { schema: { hide: true } }, async (req, reply) => {
    try { return await testKey(db, masterKey, req.params.id, deps.fetcher); } catch (e) { return fail(reply, e); }
  });

  app.delete<{ Params: { id: string } }>('/admin/api/providers/keys/:id', { schema: { hide: true } }, async (req, reply) => {
    if (!(await deleteKey(db, req.params.id))) return reply.code(404).send({ error: 'این کلید پیدا نشد.' });
    await audit(db, 'provider.key_deleted', { userId: req.adminUser }, { id: req.params.id });
    return { ok: true };
  });

  app.put<{ Body: Route }>('/admin/api/providers/routes', {
    schema: { hide: true, body: { type: 'object', required: ['capability'], properties: {
      capability: { type: 'string' }, keyId: { type: ['string', 'null'] }, model: { type: ['string', 'null'], maxLength: 200 },
      fallbackKeyId: { type: ['string', 'null'] }, fallbackModel: { type: ['string', 'null'], maxLength: 200 },
    } } },
  }, async (req, reply) => {
    try {
      const b = req.body;
      await setRoute(db, { capability: b.capability, keyId: b.keyId ?? null, model: b.model ?? null, fallbackKeyId: b.fallbackKeyId ?? null, fallbackModel: b.fallbackModel ?? null });
      await audit(db, 'provider.route_set', { userId: req.adminUser }, { capability: req.body.capability, keyId: req.body.keyId, model: req.body.model });
      return { ok: true, routes: await listRoutes(db) };
    } catch (e) { return fail(reply, e); }
  });

  // Try the brain with a short prompt (uses a little real credit — only when the admin clicks).
  app.post<{ Body: { prompt: string } }>('/admin/api/providers/try', {
    schema: { hide: true, body: { type: 'object', required: ['prompt'], properties: { prompt: { type: 'string', minLength: 1, maxLength: 1000 } } } },
    config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
  }, async (req, reply) => {
    const route = (await listRoutes(db)).find(r => r.capability === 'chat');
    const tries = [[route?.keyId, route?.model], [route?.fallbackKeyId, route?.fallbackModel]].filter(([k, m]) => k && m) as [string, string][];
    if (!tries.length) return reply.code(400).send({ error: 'اول برای «مغز» یک کلید و مدل انتخاب و ذخیره کنید.' });
    const errors: string[] = [];
    for (const [keyId, model] of tries) {
      const started = Date.now();
      try {
        const ep = await endpointFor(db, masterKey, keyId, deps.fetcher);
        const r = await chat(ep, { model, maxTokens: 300, messages: [
          { role: 'system', content: 'تو لومی هستی، یک دستیار شخصی فارسی‌زبان. کوتاه و صمیمی جواب بده.' },
          { role: 'user', content: req.body.prompt },
        ] });
        await audit(db, 'provider.tried', { userId: req.adminUser }, { model, usage: r.usage });
        return { text: r.text, model, usage: r.usage, ms: Date.now() - started, usedFallback: errors.length > 0, errors };
      } catch (e) {
        errors.push(`${model}: ${e instanceof AiError || e instanceof ProviderError ? e.message : 'خطای ناشناخته'}`);
      }
    }
    return reply.code(502).send({ error: errors.join(' — ') });
  });

  // ── activity log ──
  app.get<{ Querystring: { limit?: string } }>('/admin/api/audit', { schema: { hide: true } }, async req => {
    const limit = Math.min(Math.max(Number(req.query.limit) || 100, 1), 500);
    return (await db.query<{ id: string; action: string; device_id: string | null; detail: unknown; at: Date }>(
      `SELECT id, action, device_id, detail, at FROM audit_log ORDER BY id DESC LIMIT $1`, [limit]))
      .map(r => ({ id: Number(r.id), action: r.action, deviceId: r.device_id, detail: r.detail, at: new Date(r.at).toISOString() }));
  });
}

/** Setup link for the admin panel (first run, or a forgotten password). */
export async function adminSetupLink(db: Db, config: Pick<Config, 'publicUrl'>): Promise<string> {
  return `${config.publicUrl}/admin/#setup=${await createSetupToken(db)}`;
}
