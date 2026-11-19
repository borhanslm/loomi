// Devices and pairing. A phone/desktop becomes trusted by entering (or scanning) a
// one-time 8-digit code; it then gets its own bearer token, revocable at any time.
import type { Db } from './db.js';
import { newId, newPairCode, newToken, sha256 } from './crypto.js';

export interface Device {
  id: string;
  userId: number;
  name: string;
  platform: string;
  createdAt: string;
  lastSeen: string;
}

type Row = { id: string; user_id: string; name: string; platform: string; created_at: Date | string; last_seen: Date | string };
const toDevice = (r: Row): Device => ({
  id: r.id, userId: Number(r.user_id), name: r.name, platform: r.platform,
  createdAt: new Date(r.created_at).toISOString(), lastSeen: new Date(r.last_seen).toISOString(),
});

export async function createPairCode(db: Db, userId: number, minutes: number): Promise<{ code: string; expiresAt: string }> {
  const code = newPairCode();
  const expires = new Date(Date.now() + minutes * 60_000);
  await db.query(`DELETE FROM pair_codes WHERE expires_at < now() OR used_at IS NOT NULL`);
  await db.query(`INSERT INTO pair_codes (code_hash, user_id, expires_at) VALUES ($1, $2, $3)`, [sha256(code), userId, expires.toISOString()]);
  return { code, expiresAt: expires.toISOString() };
}

export class PairError extends Error {}

/** Trade a valid code for a device token. The code works exactly once. */
export async function completePairing(db: Db, code: string, name: string, platform: string): Promise<{ token: string; device: Device }> {
  const clean = String(code).replace(/\D/g, '');
  if (clean.length !== 8) throw new PairError('کد جفت‌سازی باید ۸ رقم باشد.');
  // Claim the code atomically so two devices can never use the same code.
  const claimed = await db.query<{ user_id: string }>(
    `UPDATE pair_codes SET used_at = now() WHERE code_hash = $1 AND used_at IS NULL AND expires_at > now() RETURNING user_id`,
    [sha256(clean)],
  );
  if (!claimed.length) throw new PairError('کد جفت‌سازی اشتباه است یا منقضی شده.');
  const token = newToken();
  const rows = await db.query<Row>(
    `INSERT INTO devices (id, user_id, name, platform, token_hash) VALUES ($1, $2, $3, $4, $5)
     RETURNING id, user_id, name, platform, created_at, last_seen`,
    [newId(), claimed[0].user_id, name.trim().slice(0, 60) || 'دستگاه', platform.slice(0, 20) || 'unknown', sha256(token)],
  );
  return { token, device: toDevice(rows[0]) };
}

/** Resolve a bearer token to its device; null if unknown or revoked. */
export async function deviceForToken(db: Db, token: string): Promise<Device | null> {
  if (!/^lmi_[\w-]{20,}$/.test(token)) return null;
  const rows = await db.query<Row>(
    `UPDATE devices SET last_seen = now() WHERE token_hash = $1 AND revoked_at IS NULL
     RETURNING id, user_id, name, platform, created_at, last_seen`,
    [sha256(token)],
  );
  return rows.length ? toDevice(rows[0]) : null;
}

export async function listDevices(db: Db, userId: number): Promise<Device[]> {
  const rows = await db.query<Row>(
    `SELECT id, user_id, name, platform, created_at, last_seen FROM devices
     WHERE user_id = $1 AND revoked_at IS NULL ORDER BY created_at`,
    [userId],
  );
  return rows.map(toDevice);
}

export async function revokeDevice(db: Db, userId: number, id: string): Promise<boolean> {
  const rows = await db.query(`UPDATE devices SET revoked_at = now() WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL RETURNING id`, [id, userId]);
  return rows.length > 0;
}

export async function countDevices(db: Db): Promise<number> {
  const rows = await db.query<{ n: string }>(`SELECT count(*)::text AS n FROM devices WHERE revoked_at IS NULL`);
  return Number(rows[0].n);
}

export async function audit(db: Db, action: string, who: { userId?: number; deviceId?: string }, detail: object = {}): Promise<void> {
  await db.query(`INSERT INTO audit_log (user_id, device_id, action, detail) VALUES ($1, $2, $3, $4)`,
    [who.userId ?? null, who.deviceId ?? null, action, JSON.stringify(detail)]);
}
