// Starts Loomi Server. On a fresh server (no paired devices yet) it prints a pairing
// QR + code in the log so the owner can connect their phone right away.
import qrcode from 'qrcode-terminal';
import { buildApp, pairQr } from './app.js';
import { loadConfig } from './config.js';
import { ensureOwner, migrate, openDb } from './db.js';
import { countDevices, createPairCode } from './devices.js';
import { parseMasterKey } from './crypto.js';
import { hasAdminPassword } from './admin/auth.js';
import { adminSetupLink } from './admin/routes.js';

const config = loadConfig();
if (config.masterKey) parseMasterKey(config.masterKey); // fail fast on a malformed key
else console.warn('⚠ LOOMI_MASTER_KEY تنظیم نشده؛ ذخیره‌ی کلیدهای API کاربران تا تنظیم آن غیرفعال است.');

const db = await openDb(config);
await migrate(db);
const owner = await ensureOwner(db);
const app = await buildApp({ db, config, logger: true });
await app.listen({ host: config.host, port: config.port });

if ((await countDevices(db)) === 0) {
  const { code, expiresAt } = await createPairCode(db, owner.id, Math.max(config.pairMinutes, 30));
  console.log('\nهنوز هیچ دستگاهی جفت نشده. با اپ لومی این QR را اسکن کنید یا کد را وارد کنید:\n');
  qrcode.generate(pairQr(config, code), { small: true });
  console.log(`آدرس: ${config.publicUrl}\nکد: ${code.slice(0, 4)} ${code.slice(4)}   (معتبر تا ${expiresAt})\n`);
}

if (!(await hasAdminPassword(db))) {
  console.log(`
پنل ادمین هنوز رمز ندارد. این لینک یک‌بارمصرف را (تا ۳۰ دقیقه) باز کنید و رمز بگذارید:
${await adminSetupLink(db, config)}
`);
}

for (const sig of ['SIGINT', 'SIGTERM'] as const) process.on(sig, async () => { await app.close(); await db.close(); process.exit(0); });
