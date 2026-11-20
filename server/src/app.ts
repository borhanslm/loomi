// HTTP + WebSocket API of Loomi Server. Every route except /v1/health and /v1/pair
// needs a device bearer token. The OpenAPI document is generated from these schemas.
import Fastify, { type FastifyInstance, type FastifyRequest } from 'fastify';
import swagger from '@fastify/swagger';
import rateLimit from '@fastify/rate-limit';
import websocket from '@fastify/websocket';
import cors from '@fastify/cors';
import { Type, type Static } from '@sinclair/typebox';
import type { Config } from './config.js';
import type { Db } from './db.js';
import {
  audit, completePairing, createPairCode, deviceForToken, listDevices, PairError, revokeDevice, type Device,
} from './devices.js';
import { parseMasterKey } from './crypto.js';
import { adminPlugin, adminSetupLink } from './admin/routes.js';
import type { Fetcher } from './providers.js';
import { ITEM_TYPES, understand } from './brain/capture.js';
import { deleteItem, ItemError, listItems, saveCapture, updateItem } from './items.js';

export const VERSION = '0.5.0';
export const API_VERSION = 1;

declare module 'fastify' {
  interface FastifyRequest { device?: Device }
}

const DeviceT = Type.Object({
  id: Type.String(), name: Type.String(), platform: Type.String(),
  createdAt: Type.String({ format: 'date-time' }), lastSeen: Type.String({ format: 'date-time' }),
});
const ErrorT = Type.Object({ error: Type.String() });
const PairBodyT = Type.Object({
  code: Type.String({ minLength: 8, maxLength: 12 }),
  name: Type.String({ minLength: 1, maxLength: 60 }),
  platform: Type.Optional(Type.String({ maxLength: 20 })),
});
const PairCodeT = Type.Object({ code: Type.String(), expiresAt: Type.String({ format: 'date-time' }), qr: Type.String() });

/** What the pairing QR contains: the server address and the one-time code. */
export const pairQr = (config: Pick<Config, 'publicUrl'>, code: string): string =>
  JSON.stringify({ loomi: 1, url: config.publicUrl, code });

/** Live events to connected apps (phase 0: device changes; later items, reminders, approvals). */
type Listener = (ev: object) => void;
export class Bus {
  private byUser = new Map<number, Set<Listener>>();
  on(userId: number, fn: Listener) {
    const set = this.byUser.get(userId) ?? new Set<Listener>();
    set.add(fn); this.byUser.set(userId, set);
    return () => set.delete(fn);
  }
  emit(userId: number, ev: object) { for (const fn of this.byUser.get(userId) ?? []) fn(ev); }
}

export async function buildApp(opts: { db: Db; config: Config; logger?: boolean; fetcher?: Fetcher }): Promise<FastifyInstance> {
  const { db, config } = opts;
  const bus = new Bus();
  // Trust X-Forwarded-For only from a proxy on this machine or the private network (Caddy, nginx),
  // so nobody on the internet can fake their address.
  const app = Fastify({ logger: opts.logger ?? false, trustProxy: 'loopback, uniquelocal', bodyLimit: 1_000_000 });

  await app.register(swagger, {
    openapi: {
      info: { title: 'Loomi Server API', version: VERSION, license: { name: 'AGPL-3.0-only' } },
      components: { securitySchemes: { device: { type: 'http', scheme: 'bearer' } } },
      security: [{ device: [] }],
    },
  });
  await app.register(rateLimit, { max: 300, timeWindow: '1 minute' });
  await app.register(websocket);
  // Development only: let a browser build of the app (e.g. http://localhost:8795) call this server.
  // Off unless LOOMI_DEV_CORS is set to that exact origin; native apps never need it.
  if (process.env.LOOMI_DEV_CORS) await app.register(cors, { origin: process.env.LOOMI_DEV_CORS, methods: ['GET', 'POST', 'PATCH', 'DELETE'] });
  const masterKey = config.masterKey ? parseMasterKey(config.masterKey) : null;
  await app.register(adminPlugin, {
    db, config, masterKey, version: VERSION, fetcher: opts.fetcher,
    pairQr: code => pairQr(config, code),
    onDevicesChanged: userId => bus.emit(userId, { type: 'devices' }),
  });

  const bearer = (req: FastifyRequest): string => {
    const h = req.headers.authorization ?? '';
    if (h.startsWith('Bearer ')) return h.slice(7).trim();
    // WebSocket clients may not set headers; allow ?token= only on the live socket.
    const q = (req.query as { token?: string } | undefined)?.token;
    return req.url.startsWith('/v1/live') && typeof q === 'string' ? q : '';
  };

  app.addHook('onRequest', async (req, reply) => {
    const path = req.url.split('?')[0];
    if (!path.startsWith('/v1/') || path === '/v1/health' || path === '/v1/pair' || path.startsWith('/v1/local/')) return;
    const device = await deviceForToken(db, bearer(req));
    if (!device) return reply.code(401).send({ error: 'دستگاه شناخته نشد؛ دوباره جفت کنید.' });
    req.device = device;
  });

  app.get('/v1/health', {
    schema: { security: [], response: { 200: Type.Object({ ok: Type.Boolean(), name: Type.String(), version: Type.String(), api: Type.Number() }) } },
  }, async () => ({ ok: true, name: 'loomi', version: VERSION, api: API_VERSION }));

  app.post<{ Body: Static<typeof PairBodyT> }>('/v1/pair', {
    config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
    schema: { security: [], body: PairBodyT, response: { 200: Type.Object({ token: Type.String(), device: DeviceT }), 400: ErrorT } },
  }, async (req, reply) => {
    try {
      const r = await completePairing(db, req.body.code, req.body.name, req.body.platform ?? 'unknown');
      await audit(db, 'device.paired', { userId: r.device.userId, deviceId: r.device.id }, { name: r.device.name, platform: r.device.platform });
      bus.emit(r.device.userId, { type: 'devices' });
      return { token: r.token, device: r.device };
    } catch (e) {
      if (e instanceof PairError) return reply.code(400).send({ error: e.message });
      throw e;
    }
  });

  app.post('/v1/pair/codes', { schema: { response: { 200: PairCodeT } } }, async req => {
    const d = req.device!;
    const r = await createPairCode(db, d.userId, config.pairMinutes);
    await audit(db, 'pair.code', { userId: d.userId, deviceId: d.id });
    return { ...r, qr: pairQr(config, r.code) };
  });

  // For admin commands on the server itself (`cli.js pair`, `cli.js admin`): only from this machine, never via a proxy.
  const fromThisMachine = (req: FastifyRequest) => {
    const raw = req.socket.remoteAddress ?? '';
    return (raw === '127.0.0.1' || raw === '::1' || raw === '::ffff:127.0.0.1') && !req.headers['x-forwarded-for'] && !req.headers['forwarded'];
  };
  app.post('/v1/local/admin-setup', { schema: { hide: true } }, async (req, reply) => {
    if (!fromThisMachine(req)) return reply.code(403).send({ error: 'فقط از خود سرور.' });
    return { link: await adminSetupLink(db, config) };
  });

  app.post('/v1/local/pair-code', { schema: { hide: true } }, async (req, reply) => {
    if (!fromThisMachine(req)) return reply.code(403).send({ error: 'فقط از خود سرور.' });
    const owner = await db.query<{ id: string }>(`SELECT id FROM users WHERE role = 'owner' ORDER BY id LIMIT 1`);
    if (!owner.length) return reply.code(503).send({ error: 'سرور هنوز آماده نیست.' });
    const r = await createPairCode(db, Number(owner[0].id), config.pairMinutes);
    await audit(db, 'pair.code', { userId: Number(owner[0].id) }, { via: 'local' });
    return { ...r, qr: pairQr(config, r.code) };
  });

  app.get('/v1/me', {
    schema: { response: { 200: Type.Object({ userId: Type.Number(), device: DeviceT }) } },
  }, async req => ({ userId: req.device!.userId, device: req.device! }));

  app.get('/v1/devices', { schema: { response: { 200: Type.Array(DeviceT) } } }, async req => listDevices(db, req.device!.userId));

  app.delete<{ Params: { id: string } }>('/v1/devices/:id', {
    schema: { params: Type.Object({ id: Type.String() }), response: { 200: Type.Object({ ok: Type.Boolean() }), 404: ErrorT } },
  }, async (req, reply) => {
    const d = req.device!;
    if (!(await revokeDevice(db, d.userId, req.params.id))) return reply.code(404).send({ error: 'این دستگاه پیدا نشد.' });
    await audit(db, 'device.revoked', { userId: d.userId, deviceId: d.id }, { revoked: req.params.id });
    bus.emit(d.userId, { type: 'devices' });
    return { ok: true };
  });

  // ── the second brain: capture → items ──
  const ItemT = Type.Object({
    id: Type.String(), type: Type.Union(ITEM_TYPES.map(t => Type.Literal(t))), title: Type.String(), notes: Type.Union([Type.String(), Type.Null()]),
    dueAt: Type.Union([Type.String({ format: 'date-time' }), Type.Null()]), allDay: Type.Boolean(),
    people: Type.Array(Type.String()), place: Type.Union([Type.String(), Type.Null()]),
    done: Type.Boolean(), doneAt: Type.Union([Type.String({ format: 'date-time' }), Type.Null()]),
    createdAt: Type.String({ format: 'date-time' }), updatedAt: Type.String({ format: 'date-time' }), captureId: Type.Union([Type.String(), Type.Null()]),
  });
  const CaptureBodyT = Type.Object({
    text: Type.String({ minLength: 1, maxLength: 4000 }),
    clientId: Type.Optional(Type.String({ maxLength: 64 })),
    /** the device's UTC offset in minutes (Tehran = 210), so «فردا ساعت ۵» means the user's 5 o'clock */
    tzOffset: Type.Optional(Type.Integer({ minimum: -720, maximum: 840 })),
  });

  app.post<{ Body: Static<typeof CaptureBodyT> }>('/v1/capture', {
    config: { rateLimit: { max: 60, timeWindow: '1 minute' } },
    schema: {
      body: CaptureBodyT,
      response: { 200: Type.Object({
        captureId: Type.String(), via: Type.String(), model: Type.Union([Type.String(), Type.Null()]),
        warning: Type.Union([Type.String(), Type.Null()]), duplicate: Type.Boolean(), items: Type.Array(ItemT),
      }) },
    },
  }, async req => {
    const d = req.device!;
    const offset = req.body.tzOffset ?? 210;
    const u = await understand(req.body.text, new Date(), offset, { db, masterKey, fetcher: opts.fetcher });
    const r = await saveCapture(db, d.userId, d.id, req.body.text, req.body.clientId ?? null, u);
    if (!r.duplicate) bus.emit(d.userId, { type: 'items' });
    return { captureId: r.captureId, via: u.via, model: u.model, warning: u.warning, duplicate: r.duplicate, items: r.items };
  });

  app.get<{ Querystring: { status?: 'open' | 'done' | 'all'; type?: string; q?: string; limit?: number } }>('/v1/items', {
    schema: {
      querystring: Type.Object({
        status: Type.Optional(Type.Union([Type.Literal('open'), Type.Literal('done'), Type.Literal('all')])),
        type: Type.Optional(Type.String()), q: Type.Optional(Type.String({ maxLength: 200 })), limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 1000 })),
      }),
      response: { 200: Type.Array(ItemT) },
    },
  }, async req => listItems(db, req.device!.userId, req.query));

  const PatchT = Type.Object({
    title: Type.Optional(Type.String({ maxLength: 200 })), notes: Type.Optional(Type.Union([Type.String({ maxLength: 2000 }), Type.Null()])),
    type: Type.Optional(Type.String()), dueAt: Type.Optional(Type.Union([Type.String(), Type.Null()])),
    allDay: Type.Optional(Type.Boolean()), done: Type.Optional(Type.Boolean()),
  });
  app.patch<{ Params: { id: string }; Body: Static<typeof PatchT> }>('/v1/items/:id', {
    schema: { params: Type.Object({ id: Type.String() }), body: PatchT, response: { 200: ItemT, 400: ErrorT, 404: ErrorT } },
  }, async (req, reply) => {
    try {
      const it = await updateItem(db, req.device!.userId, req.params.id, req.body);
      if (!it) return reply.code(404).send({ error: 'این مورد پیدا نشد.' });
      bus.emit(req.device!.userId, { type: 'items' });
      return it;
    } catch (e) {
      if (e instanceof ItemError) return reply.code(400).send({ error: e.message });
      throw e;
    }
  });

  app.delete<{ Params: { id: string } }>('/v1/items/:id', {
    schema: { params: Type.Object({ id: Type.String() }), response: { 200: Type.Object({ ok: Type.Boolean() }), 404: ErrorT } },
  }, async (req, reply) => {
    if (!(await deleteItem(db, req.device!.userId, req.params.id))) return reply.code(404).send({ error: 'این مورد پیدا نشد.' });
    bus.emit(req.device!.userId, { type: 'items' });
    return { ok: true };
  });

  app.get('/v1/live', { websocket: true, schema: { hide: true } }, (socket, req) => {
    const send = (ev: object) => socket.send(JSON.stringify(ev));
    send({ type: 'hello', device: req.device!.id, version: VERSION });
    const off = bus.on(req.device!.userId, send);
    socket.on('close', off);
  });

  return app;
}
