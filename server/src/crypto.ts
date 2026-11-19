// Small, auditable crypto helpers. Uses only Node's built-in crypto.
import { createCipheriv, createDecipheriv, createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';

/** Long random bearer token for a device (shown to the device once, stored only as a hash). */
export const newToken = (): string => 'lmi_' + randomBytes(32).toString('base64url');

/** Short id for rows people may see (device ids). */
export const newId = (): string => randomBytes(9).toString('base64url');

/** 8-digit one-time pairing code, uniformly random. */
export const newPairCode = (): string => String(randomInt(0, 100_000_000)).padStart(8, '0');

export const sha256 = (s: string): string => createHash('sha256').update(s).digest('hex');

export function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

/** Parse the master key (64 hex chars or base64 of 32 bytes). */
export function parseMasterKey(raw: string): Buffer {
  const s = raw.trim();
  const key = /^[0-9a-f]{64}$/i.test(s) ? Buffer.from(s, 'hex') : Buffer.from(s, 'base64');
  if (key.length !== 32) throw new Error('LOOMI_MASTER_KEY must be 32 bytes (64 hex characters or base64).');
  return key;
}

/** Encrypt a secret (e.g. a user's API key) with AES-256-GCM. Output: v1.<iv>.<tag>.<data> (base64url). */
export function seal(plain: string, key: Buffer): string {
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key, iv);
  const data = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  return ['v1', iv, c.getAuthTag(), data].map(p => (typeof p === 'string' ? p : p.toString('base64url'))).join('.');
}

export function open(sealed: string, key: Buffer): string {
  const [v, iv, tag, data] = sealed.split('.');
  if (v !== 'v1' || !iv || !tag || data === undefined) throw new Error('Not a sealed value.');
  const d = createDecipheriv('aes-256-gcm', key, Buffer.from(iv, 'base64url'));
  d.setAuthTag(Buffer.from(tag, 'base64url'));
  return Buffer.concat([d.update(Buffer.from(data, 'base64url')), d.final()]).toString('utf8');
}
