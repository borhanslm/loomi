// A tiny database layer: real PostgreSQL in production, embedded Postgres (PGlite)
// for development and tests. Both speak the same SQL, so the code above never cares.
import type { Config } from './config.js';

export interface Db {
  query<T = Record<string, unknown>>(sql: string, params?: unknown[]): Promise<T[]>;
  close(): Promise<void>;
}

export async function openDb(config: Pick<Config, 'databaseUrl' | 'dataDir'>): Promise<Db> {
  if (config.databaseUrl) {
    const { default: pg } = await import('pg');
    const pool = new pg.Pool({ connectionString: config.databaseUrl });
    return {
      async query(sql, params = []) { return (await pool.query(sql, params)).rows; },
      async close() { await pool.end(); },
    };
  }
  const { PGlite } = await import('@electric-sql/pglite');
  const lite = config.dataDir === ':memory:' ? new PGlite() : new PGlite(config.dataDir);
  return {
    async query<T>(sql: string, params: unknown[] = []) { return (await lite.query<T>(sql, params)).rows; },
    async close() { await lite.close(); },
  };
}

// Ordered, append-only migrations. Never edit one that has shipped; add a new one.
const MIGRATIONS: string[] = [
  `CREATE TABLE users (
     id          BIGSERIAL PRIMARY KEY,
     name        TEXT NOT NULL,
     role        TEXT NOT NULL DEFAULT 'member',
     created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
   );
   CREATE TABLE devices (
     id          TEXT PRIMARY KEY,
     user_id     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
     name        TEXT NOT NULL,
     platform    TEXT NOT NULL DEFAULT 'unknown',
     token_hash  TEXT NOT NULL UNIQUE,
     created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
     last_seen   TIMESTAMPTZ NOT NULL DEFAULT now(),
     revoked_at  TIMESTAMPTZ
   );
   CREATE TABLE pair_codes (
     code_hash   TEXT PRIMARY KEY,
     user_id     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
     expires_at  TIMESTAMPTZ NOT NULL,
     used_at     TIMESTAMPTZ
   );
   CREATE TABLE audit_log (
     id          BIGSERIAL PRIMARY KEY,
     user_id     BIGINT,
     device_id   TEXT,
     action      TEXT NOT NULL,
     detail      JSONB NOT NULL DEFAULT '{}'::jsonb,
     at          TIMESTAMPTZ NOT NULL DEFAULT now()
   );`,
];

export async function migrate(db: Db): Promise<void> {
  await db.query(`CREATE TABLE IF NOT EXISTS schema_version (version INT NOT NULL)`);
  const rows = await db.query<{ version: number }>(`SELECT version FROM schema_version`);
  let current = rows.length ? Number(rows[0].version) : 0;
  if (!rows.length) await db.query(`INSERT INTO schema_version (version) VALUES (0)`);
  for (; current < MIGRATIONS.length; current++) {
    for (const stmt of MIGRATIONS[current].split(/;\s*\n/).map(s => s.trim()).filter(Boolean)) await db.query(stmt);
    await db.query(`UPDATE schema_version SET version = $1`, [current + 1]);
  }
}

/** The server owner (first user). Created on first start. */
export async function ensureOwner(db: Db): Promise<{ id: number; name: string }> {
  const rows = await db.query<{ id: string; name: string }>(`SELECT id, name FROM users WHERE role = 'owner' ORDER BY id LIMIT 1`);
  if (rows.length) return { id: Number(rows[0].id), name: rows[0].name };
  const made = await db.query<{ id: string; name: string }>(`INSERT INTO users (name, role) VALUES ('owner', 'owner') RETURNING id, name`);
  return { id: Number(made[0].id), name: made[0].name };
}
