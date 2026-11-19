// Admin panel login: one owner password (scrypt), short-lived sessions in an
// HttpOnly cookie, and one-time setup links printed on the server (first run,
// or `cli.js admin` when the password is forgotten).
import { randomBytes, scrypt as scryptCb, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import type { Db } from '../db.js';
import { sha256 } from '../crypto.js';

const scrypt = promisify(scryptCb) as (pw: string, salt: Buffer, len: number) => Promise<Buffer>;
export const SESSION_HOURS = 12;
export const MIN_PASSWORD = 10;

export async function hashPassword(pw: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await scrypt(pw, salt, 64);
  return `scrypt$${salt.toString('base64url')}$${key.toString('base64url')}`;
}

export async function verifyPassword(pw: string, stored: string | null): Promise<boolean> {
  if (!stored) return false;
  const [kind, salt, key] = stored.split('$');
  if (kind !== 'scrypt' || !salt || !key) return false;
  const want = Buffer.from(key, 'base64url');
  const got = await scrypt(pw, Buffer.from(salt, 'base64url'), want.length);
  return timingSafeEqual(want, got);
}

export async function ownerRow(db: Db) {
  const r = await db.query<{ id: string; password_hash: string | null }>(
    `SELECT id, password_hash FROM users WHERE role = 'owner' ORDER BY id LIMIT 1`);
  return r.length ? { id: Number(r[0].id), passwordHash: r[0].password_hash } : null;
}

export async function hasAdminPassword(db: Db): Promise<boolean> {
  return !!(await ownerRow(db))?.passwordHash;
}

/** One-time link token to set (or reset) the admin password. */
export async function createSetupToken(db: Db, minutes = 30): Promise<string> {
  const token = randomBytes(24).toString('base64url');
  await db.query(`DELETE FROM admin_setup_tokens WHERE expires_at < now() OR used_at IS NOT NULL`);
  await db.query(`INSERT INTO admin_setup_tokens (token_hash, expires_at) VALUES ($1, $2)`,
    [sha256(token), new Date(Date.now() + minutes * 60_000).toISOString()]);
  return token;
}

export class AdminError extends Error {}

export async function completeSetup(db: Db, token: string, password: string): Promise<number> {
  if (password.length < MIN_PASSWORD) throw new AdminError(`رمز باید دست‌کم ${MIN_PASSWORD} نویسه باشد.`);
  const ok = await db.query(
    `UPDATE admin_setup_tokens SET used_at = now() WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now() RETURNING token_hash`,
    [sha256(String(token))]);
  if (!ok.length) throw new AdminError('لینک راه‌اندازی نامعتبر است یا منقضی شده. روی سرور یک لینک تازه بسازید.');
  const owner = await ownerRow(db);
  if (!owner) throw new AdminError('سرور هنوز آماده نیست.');
  await db.query(`UPDATE users SET password_hash = $1 WHERE id = $2`, [await hashPassword(password), owner.id]);
  await db.query(`DELETE FROM admin_sessions WHERE user_id = $1`, [owner.id]); // reset logs everyone out
  return owner.id;
}

export async function login(db: Db, password: string, ip: string): Promise<{ sid: string; userId: number } | null> {
  const owner = await ownerRow(db);
  if (!owner || !(await verifyPassword(password, owner.passwordHash))) return null;
  const sid = randomBytes(32).toString('base64url');
  await db.query(`DELETE FROM admin_sessions WHERE expires_at < now()`);
  await db.query(`INSERT INTO admin_sessions (id_hash, user_id, expires_at, ip) VALUES ($1, $2, $3, $4)`,
    [sha256(sid), owner.id, new Date(Date.now() + SESSION_HOURS * 3600_000).toISOString(), ip]);
  return { sid, userId: owner.id };
}

export async function sessionUser(db: Db, sid: string | undefined): Promise<number | null> {
  if (!sid || sid.length < 30) return null;
  const r = await db.query<{ user_id: string }>(
    `SELECT user_id FROM admin_sessions WHERE id_hash = $1 AND expires_at > now()`, [sha256(sid)]);
  return r.length ? Number(r[0].user_id) : null;
}

export async function logout(db: Db, sid: string | undefined): Promise<void> {
  if (sid) await db.query(`DELETE FROM admin_sessions WHERE id_hash = $1`, [sha256(sid)]);
}
