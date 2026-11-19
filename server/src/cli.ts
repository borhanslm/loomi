// Admin commands, run on the server itself:
//   npm run pair      → a new one-time pairing code + QR for the owner
//   cli admin         → one-time link to set or reset the admin panel password
//   npm run openapi   → prints the OpenAPI document (used to generate the app's API client)
import qrcode from 'qrcode-terminal';
import { buildApp, pairQr } from './app.js';
import { loadConfig } from './config.js';
import { ensureOwner, migrate, openDb } from './db.js';
import { createPairCode } from './devices.js';
import { adminSetupLink } from './admin/routes.js';

const cmd = process.argv[2];
const config = loadConfig();

function show(code: string, qr: string, expiresAt: string) {
  qrcode.generate(qr, { small: true });
  console.log(`آدرس: ${config.publicUrl}\nکد: ${code.slice(0, 4)} ${code.slice(4)}   (معتبر تا ${expiresAt})`);
}

if (cmd === 'pair') {
  // Ask the running server first: the embedded database must never be opened by two processes.
  let res: Response | null = null;
  try {
    res = await fetch(`http://127.0.0.1:${config.port}/v1/local/pair-code`, { method: 'POST' });
  } catch {
    res = null; // server not running → safe to use the database directly
  }
  if (res) {
    const j = (await res.json()) as { code?: string; qr?: string; expiresAt?: string; error?: string };
    if (!res.ok || !j.code) { console.error(j.error ?? `خطا (${res.status})`); process.exit(1); }
    show(j.code, j.qr!, j.expiresAt!);
  } else {
    const db = await openDb(config);
    await migrate(db);
    const owner = await ensureOwner(db);
    const { code, expiresAt } = await createPairCode(db, owner.id, config.pairMinutes);
    show(code, pairQr(config, code), expiresAt);
    await db.close();
  }
} else if (cmd === 'admin') {
  let link = '';
  try {
    const res = await fetch(`http://127.0.0.1:${config.port}/v1/local/admin-setup`, { method: 'POST' });
    const j = (await res.json()) as { link?: string; error?: string };
    if (!res.ok || !j.link) { console.error(j.error ?? `خطا (${res.status})`); process.exit(1); }
    link = j.link;
  } catch {
    const db = await openDb(config);
    await migrate(db);
    await ensureOwner(db);
    link = await adminSetupLink(db, config);
    await db.close();
  }
  console.log(`لینک یک‌بارمصرف تنظیم رمز پنل ادمین (۳۰ دقیقه):
${link}`);
} else if (cmd === 'openapi') {
  const db = await openDb({ databaseUrl: '', dataDir: ':memory:' });
  const app = await buildApp({ db, config });
  await app.ready();
  process.stdout.write(JSON.stringify(app.swagger(), null, 2) + '\n');
  await app.close(); await db.close();
} else {
  console.error('Usage: cli <pair|admin|openapi>');
  process.exit(2);
}
