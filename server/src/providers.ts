// AI providers: the server owner's own API keys (sealed with LOOMI_MASTER_KEY),
// and which provider + model serves each capability. Keys never leave the server
// and are never sent back to any client — only their last 4 characters.
import type { Db } from './db.js';
import { newId, open, seal } from './crypto.js';
import { AiError, type Endpoint, verifyKey } from './ai/openai-compat.js';

export type Capability = 'chat' | 'stt' | 'tts' | 'embed' | 'vision';
export const CAPABILITIES: { id: Capability; label: string }[] = [
  { id: 'chat', label: 'مغز (فکر و گفت‌وگو)' },
  { id: 'stt', label: 'شنیدن (گفتار به متن)' },
  { id: 'tts', label: 'صدای لومی (متن به گفتار)' },
  { id: 'embed', label: 'حافظه و جست‌وجوی معنایی' },
  { id: 'vision', label: 'دیدن عکس' },
];

export interface ProviderInfo {
  id: string;
  name: string;
  needsKey: boolean;
  needsUrl: boolean;
  defaultUrl?: string;
  caps: Capability[];
  keyHelp: string;
}

export const PROVIDERS: ProviderInfo[] = [
  { id: 'anthropic', name: 'Claude (Anthropic)', needsKey: true, needsUrl: false, caps: ['chat', 'vision'], keyHelp: 'https://console.anthropic.com/settings/keys' },
  { id: 'openai', name: 'ChatGPT (OpenAI)', needsKey: true, needsUrl: false, caps: ['chat', 'vision', 'stt', 'tts', 'embed'], keyHelp: 'https://platform.openai.com/api-keys' },
  { id: 'gemini', name: 'Gemini (Google)', needsKey: true, needsUrl: false, caps: ['chat', 'vision', 'stt', 'embed'], keyHelp: 'https://aistudio.google.com/apikey' },
  { id: 'deepseek', name: 'DeepSeek', needsKey: true, needsUrl: false, caps: ['chat'], keyHelp: 'https://platform.deepseek.com/api_keys' },
  { id: 'elevenlabs', name: 'ElevenLabs', needsKey: true, needsUrl: false, caps: ['tts', 'stt'], keyHelp: 'https://elevenlabs.io/app/settings/api-keys' },
  { id: 'ollama', name: 'Ollama (مدل محلی)', needsKey: false, needsUrl: true, defaultUrl: 'http://localhost:11434', caps: ['chat', 'vision', 'embed'], keyHelp: 'https://ollama.com/download' },
  { id: 'togpt', name: 'ToGPT (توجی‌پی‌تی)', needsKey: true, needsUrl: false, defaultUrl: 'https://togpt.ir/api/v1', caps: ['chat', 'vision', 'tts', 'stt'], keyHelp: 'https://togpt.ir/api-docs' },
  // Any OpenAI-compatible API: OpenRouter, Groq, Together, Mistral, LM Studio, vLLM, LiteLLM, internal gateways…
  { id: 'custom', name: 'API سفارشی (سازگار با OpenAI)', needsKey: false, needsUrl: true, defaultUrl: 'https://openrouter.ai/api/v1', caps: ['chat', 'vision', 'stt', 'tts', 'embed'], keyHelp: 'https://openrouter.ai/keys' },
];
export const providerInfo = (id: string) => PROVIDERS.find(p => p.id === id);

export interface ProviderKey {
  id: string; provider: string; label: string; baseUrl: string | null; keyLast4: string | null;
  models: string[]; lastTestAt: string | null; lastTestOk: boolean | null; lastTestMsg: string | null;
}
type Row = {
  id: string; provider: string; label: string; base_url: string | null; key_last4: string | null;
  models: string[] | string; last_test_at: Date | string | null; last_test_ok: boolean | null; last_test_msg: string | null;
};
const toKey = (r: Row): ProviderKey => ({
  id: r.id, provider: r.provider, label: r.label, baseUrl: r.base_url, keyLast4: r.key_last4,
  models: typeof r.models === 'string' ? JSON.parse(r.models) : r.models ?? [],
  lastTestAt: r.last_test_at ? new Date(r.last_test_at).toISOString() : null, lastTestOk: r.last_test_ok, lastTestMsg: r.last_test_msg,
});
const COLS = 'id, provider, label, base_url, key_last4, models, last_test_at, last_test_ok, last_test_msg';

export class ProviderError extends Error {}

export async function listKeys(db: Db): Promise<ProviderKey[]> {
  return (await db.query<Row>(`SELECT ${COLS} FROM provider_keys ORDER BY created_at`)).map(toKey);
}

export async function addKey(db: Db, masterKey: Buffer | null, input: { provider: string; label?: string; apiKey?: string; baseUrl?: string }): Promise<ProviderKey> {
  const info = providerInfo(input.provider);
  if (!info) throw new ProviderError('ارائه‌دهنده‌ی ناشناخته.');
  const apiKey = (input.apiKey ?? '').trim();
  if (info.needsKey && !apiKey) throw new ProviderError('کلید API را وارد کنید.');
  if (apiKey) {
    if (!masterKey) throw new ProviderError('LOOMI_MASTER_KEY روی سرور تنظیم نشده؛ بدون آن کلیدها امن ذخیره نمی‌شوند.');
    if (apiKey.length > 500 || /\s/.test(apiKey)) throw new ProviderError('کلید API معتبر به نظر نمی‌رسد.');
  }
  let baseUrl: string | null = info.defaultUrl && !info.needsUrl ? info.defaultUrl : null;
  if (info.needsUrl) {
    baseUrl = (input.baseUrl || info.defaultUrl || '').trim().replace(/\/+$/, '');
    if (!/^https?:\/\/[^\s]+$/.test(baseUrl)) throw new ProviderError('آدرس سرور مدل معتبر نیست.');
  }
  const rows = await db.query<Row>(
    `INSERT INTO provider_keys (id, provider, label, base_url, key_sealed, key_last4) VALUES ($1, $2, $3, $4, $5, $6) RETURNING ${COLS}`,
    [newId(), info.id, (input.label ?? '').trim().slice(0, 40) || info.name, baseUrl,
      apiKey && masterKey ? seal(apiKey, masterKey) : null, apiKey ? apiKey.slice(-4) : null]);
  return toKey(rows[0]);
}

export async function deleteKey(db: Db, id: string): Promise<boolean> {
  return (await db.query(`DELETE FROM provider_keys WHERE id = $1 RETURNING id`, [id])).length > 0;
}

/** The decrypted key, for server-side calls only. */
export async function secretFor(db: Db, masterKey: Buffer | null, id: string): Promise<{ provider: string; apiKey: string | null; baseUrl: string | null } | null> {
  const r = await db.query<{ provider: string; key_sealed: string | null; base_url: string | null }>(
    `SELECT provider, key_sealed, base_url FROM provider_keys WHERE id = $1`, [id]);
  if (!r.length) return null;
  if (r[0].key_sealed && !masterKey) throw new ProviderError('LOOMI_MASTER_KEY روی سرور نیست.');
  return { provider: r[0].provider, apiKey: r[0].key_sealed ? open(r[0].key_sealed, masterKey!) : null, baseUrl: r[0].base_url };
}

// ── testing a key: a cheap, read-only "list models" call to the provider ──

export type Fetcher = typeof fetch;

async function getJson(f: Fetcher, url: string, headers: Record<string, string>): Promise<unknown> {
  let res: Response;
  try {
    res = await f(url, { headers, signal: AbortSignal.timeout(12_000) });
  } catch {
    throw new ProviderError('سرور ارائه‌دهنده در دسترس نیست (شبکه یا تحریم).');
  }
  if (res.status === 401 || res.status === 403) throw new ProviderError('کلید رد شد (نامعتبر یا بدون اجازه).');
  if (res.status === 429) throw new ProviderError('محدودیت تعداد درخواست یا اعتبار تمام شده.');
  if (!res.ok) throw new ProviderError(`خطای ارائه‌دهنده (${res.status}).`);
  return res.json();
}

export async function listModels(f: Fetcher, provider: string, apiKey: string | null, baseUrl: string | null): Promise<string[]> {
  const k = apiKey ?? '';
  const ids = (arr: unknown, pick: (x: Record<string, unknown>) => unknown) =>
    (Array.isArray(arr) ? arr : []).map(x => String(pick(x as Record<string, unknown>))).filter(Boolean);
  switch (provider) {
    case 'anthropic': {
      const j = await getJson(f, 'https://api.anthropic.com/v1/models?limit=100', { 'x-api-key': k, 'anthropic-version': '2023-06-01' }) as { data?: unknown };
      return ids(j.data, x => x.id);
    }
    case 'openai': {
      const j = await getJson(f, 'https://api.openai.com/v1/models', { authorization: `Bearer ${k}` }) as { data?: unknown };
      return ids(j.data, x => x.id).sort();
    }
    case 'deepseek': {
      const j = await getJson(f, 'https://api.deepseek.com/models', { authorization: `Bearer ${k}` }) as { data?: unknown };
      return ids(j.data, x => x.id);
    }
    case 'gemini': {
      const j = await getJson(f, 'https://generativelanguage.googleapis.com/v1beta/models?pageSize=200', { 'x-goog-api-key': k }) as { models?: unknown };
      return ids(j.models, x => String(x.name ?? '').replace(/^models\//, ''));
    }
    case 'elevenlabs': {
      const j = await getJson(f, 'https://api.elevenlabs.io/v1/voices', { 'xi-api-key': k }) as { voices?: unknown };
      return ids(j.voices, x => `${x.name} (${x.voice_id})`);
    }
    case 'ollama': {
      const j = await getJson(f, `${baseUrl}/api/tags`, {}) as { models?: unknown };
      return ids(j.models, x => x.name);
    }
    case 'custom':
    case 'togpt': {
      const j = await getJson(f, `${baseUrl}/models`, k ? { authorization: `Bearer ${k}` } : {}) as { data?: unknown; models?: unknown };
      // Some gateways list models publicly, so the list alone does not prove the key works.
      if (k) await verifyKey({ baseUrl: baseUrl!, apiKey: k, fetch: f });
      return ids(Array.isArray(j.data) ? j.data : j.models, x => x.id ?? x.name).sort();
    }
    default:
      throw new ProviderError('ارائه‌دهنده‌ی ناشناخته.');
  }
}

export async function testKey(db: Db, masterKey: Buffer | null, id: string, f: Fetcher = fetch): Promise<ProviderKey> {
  const s = await secretFor(db, masterKey, id);
  if (!s) throw new ProviderError('این کلید پیدا نشد.');
  let ok = false, msg = '', models: string[] = [];
  try {
    models = (await listModels(f, s.provider, s.apiKey, s.baseUrl)).slice(0, 300);
    ok = true;
    msg = `سالم — ${models.length.toLocaleString('fa-IR')} مدل/صدا`;
  } catch (e) {
    msg = e instanceof ProviderError || e instanceof AiError ? e.message : 'خطای ناشناخته در آزمون.';
  }
  const rows = await db.query<Row>(
    `UPDATE provider_keys SET last_test_at = now(), last_test_ok = $2, last_test_msg = $3, models = CASE WHEN $2 THEN $4::jsonb ELSE models END
     WHERE id = $1 RETURNING ${COLS}`, [id, ok, msg, JSON.stringify(models)]);
  return toKey(rows[0]);
}

// ── which provider serves each capability ──

export interface Route { capability: Capability; keyId: string | null; model: string | null; fallbackKeyId: string | null; fallbackModel: string | null }

export async function listRoutes(db: Db): Promise<Route[]> {
  const rows = await db.query<{ capability: Capability; key_id: string | null; model: string | null; fallback_key_id: string | null; fallback_model: string | null }>(
    `SELECT capability, key_id, model, fallback_key_id, fallback_model FROM capability_routes`);
  return CAPABILITIES.map(c => {
    const r = rows.find(x => x.capability === c.id);
    return { capability: c.id, keyId: r?.key_id ?? null, model: r?.model ?? null, fallbackKeyId: r?.fallback_key_id ?? null, fallbackModel: r?.fallback_model ?? null };
  });
}

export async function setRoute(db: Db, r: Route): Promise<void> {
  if (!CAPABILITIES.some(c => c.id === r.capability)) throw new ProviderError('توانایی ناشناخته.');
  const keys = await listKeys(db);
  for (const [kid, label] of [[r.keyId, 'اصلی'], [r.fallbackKeyId, 'پشتیبان']] as const) {
    if (!kid) continue;
    const k = keys.find(x => x.id === kid);
    if (!k) throw new ProviderError(`کلید ${label} پیدا نشد.`);
    if (!providerInfo(k.provider)?.caps.includes(r.capability)) throw new ProviderError(`${providerInfo(k.provider)?.name} این توانایی را ندارد.`);
  }
  await db.query(
    `INSERT INTO capability_routes (capability, key_id, model, fallback_key_id, fallback_model) VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (capability) DO UPDATE SET key_id = $2, model = $3, fallback_key_id = $4, fallback_model = $5`,
    [r.capability, r.keyId, r.model?.trim() || null, r.fallbackKeyId, r.fallbackModel?.trim() || null]);
}

// ── calling a provider ──

/** OpenAI-compatible base URL for each provider (all of them speak /chat/completions). */
const COMPAT_BASE: Record<string, string> = {
  openai: 'https://api.openai.com/v1',
  deepseek: 'https://api.deepseek.com',
  gemini: 'https://generativelanguage.googleapis.com/v1beta/openai',
  anthropic: 'https://api.anthropic.com/v1',
};

/** Ready-to-call endpoint for a saved key (decrypted only in memory, only on the server). */
export async function endpointFor(db: Db, masterKey: Buffer | null, keyId: string, f?: Fetcher): Promise<Endpoint & { provider: string }> {
  const s = await secretFor(db, masterKey, keyId);
  if (!s) throw new ProviderError('این کلید پیدا نشد.');
  const base = s.provider === 'ollama' ? `${s.baseUrl}/v1` : COMPAT_BASE[s.provider] ?? s.baseUrl;
  if (!base) throw new ProviderError('این ارائه‌دهنده برای گفت‌وگو قابل استفاده نیست.');
  return { provider: s.provider, baseUrl: base, apiKey: s.apiKey, fetch: f };
}
