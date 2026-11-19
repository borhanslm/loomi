// Loomi Server configuration, read from environment variables.
// Everything has a safe default so `npm run dev` works with zero setup.

export interface Config {
  host: string;
  port: number;
  /** Public address phones use to reach this server (goes into the pairing QR). */
  publicUrl: string;
  /** postgres://… for production; empty = embedded Postgres (PGlite) in dataDir. */
  databaseUrl: string;
  /** Folder for the embedded database; ':memory:' for tests. */
  dataDir: string;
  /** 32-byte key (hex or base64) that encrypts users' API keys at rest. */
  masterKey: string;
  /** Minutes a pairing code stays valid. */
  pairMinutes: number;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const port = Number(env.LOOMI_PORT ?? env.PORT ?? 8787);
  return {
    host: env.LOOMI_HOST ?? '0.0.0.0',
    port,
    publicUrl: (env.LOOMI_PUBLIC_URL ?? `http://localhost:${port}`).replace(/\/+$/, ''),
    databaseUrl: env.DATABASE_URL ?? '',
    dataDir: env.LOOMI_DATA_DIR ?? './data',
    masterKey: env.LOOMI_MASTER_KEY ?? '',
    pairMinutes: Number(env.LOOMI_PAIR_MINUTES ?? 5),
  };
}
