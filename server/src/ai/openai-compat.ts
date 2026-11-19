// One client for every OpenAI-compatible API (OpenAI, DeepSeek, OpenRouter, Groq, togpt.ir, LM Studio, vLLM, …).
// Providers differ in small ways, so replies are normalized:
//   chat:   choices[0].message.content (OpenAI)  |  text (togpt.ir)  |  output_text (Responses API)
//   usage:  prompt_tokens/completion_tokens       |  input_tokens/output_tokens
//   stream: SSE "data: {choices:[{delta:{content}}]}" | "data: {text}" | "data: {delta}" … "[DONE]"
import type { Fetcher } from '../providers.js';

export class AiError extends Error {
  constructor(message: string, public status?: number) { super(message); }
}

export type Part = { type: 'text'; text: string } | { type: 'image_url'; image_url: { url: string } };
export interface Message { role: 'system' | 'user' | 'assistant' | 'tool'; content: string | Part[]; tool_call_id?: string; tool_calls?: ToolCall[] }
export interface Tool { type: 'function'; function: { name: string; description?: string; parameters: object } }
export interface ToolCall { id: string; type: 'function'; function: { name: string; arguments: string } }
export interface Usage { input: number; output: number }
export interface ChatResult { text: string; toolCalls: ToolCall[]; usage: Usage | null; raw: unknown }

export interface Endpoint { baseUrl: string; apiKey: string | null; fetch?: Fetcher }

const headers = (e: Endpoint, json = true): Record<string, string> => ({
  ...(json ? { 'content-type': 'application/json' } : {}),
  ...(e.apiKey ? { authorization: `Bearer ${e.apiKey}` } : {}),
});

/** Persian message for an HTTP error from any provider. */
export function errorFor(status: number, body: unknown): AiError {
  const msg = (body as { error?: { message?: string } | string; message?: string } | null);
  const detail = typeof msg?.error === 'string' ? msg.error : msg?.error?.message ?? msg?.message ?? '';
  if (status === 401 || status === 403) return new AiError('کلید API رد شد (نامعتبر یا بدون اجازه).', status);
  if (status === 402) return new AiError('اعتبار حساب ارائه‌دهنده کافی نیست؛ حساب را شارژ کنید.', status);
  if (status === 404) return new AiError(`مدل یا مسیر پیدا نشد${detail ? `: ${detail}` : ''}.`, status);
  if (status === 429) return new AiError('محدودیت تعداد درخواست؛ کمی بعد دوباره امتحان کنید.', status);
  if (status >= 500) return new AiError('سرور ارائه‌دهنده خطا داد؛ کمی بعد دوباره امتحان کنید.', status);
  return new AiError(`درخواست رد شد (${status})${detail ? `: ${detail}` : ''}.`, status);
}

async function post(e: Endpoint, path: string, body: unknown, timeoutMs = 120_000): Promise<Response> {
  let res: Response;
  try {
    res = await (e.fetch ?? fetch)(`${e.baseUrl}${path}`, {
      method: 'POST', headers: headers(e), body: JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    throw new AiError('سرور ارائه‌دهنده در دسترس نیست (شبکه یا تحریم).');
  }
  if (!res.ok) throw errorFor(res.status, await res.json().catch(() => null));
  return res;
}

export function normalizeUsage(u: unknown): Usage | null {
  const x = u as Record<string, number> | undefined;
  if (!x) return null;
  const input = x.input_tokens ?? x.prompt_tokens, output = x.output_tokens ?? x.completion_tokens;
  return input == null && output == null ? null : { input: input ?? 0, output: output ?? 0 };
}

/** Text + tool calls from any of the known reply shapes. */
export function normalizeChat(j: unknown): ChatResult {
  const r = (j ?? {}) as Record<string, unknown>;
  const choice = (r.choices as { message?: { content?: unknown; tool_calls?: ToolCall[] } }[] | undefined)?.[0]?.message;
  let text = '';
  if (choice && typeof choice.content === 'string') text = choice.content;
  else if (choice && Array.isArray(choice.content)) text = (choice.content as { text?: string }[]).map(p => p.text ?? '').join('');
  else if (typeof r.text === 'string') text = r.text;
  else if (typeof r.output_text === 'string') text = r.output_text;
  else if (Array.isArray(r.output)) {
    text = (r.output as { content?: { text?: string }[] }[]).flatMap(o => o.content ?? []).map(c => c.text ?? '').join('');
  }
  const toolCalls = (choice?.tool_calls ?? (r.tool_calls as ToolCall[] | undefined) ?? []).filter(t => t?.function?.name);
  return { text, toolCalls, usage: normalizeUsage(r.usage), raw: j };
}

export interface ChatRequest { model: string; messages: Message[]; tools?: Tool[]; temperature?: number; maxTokens?: number; json?: boolean }
const body = (q: ChatRequest, stream: boolean) => ({
  model: q.model, messages: q.messages, stream,
  ...(q.tools?.length ? { tools: q.tools } : {}),
  ...(q.temperature != null ? { temperature: q.temperature } : {}),
  ...(q.maxTokens != null ? { max_tokens: q.maxTokens } : {}),
  ...(q.json ? { response_format: { type: 'json_object' } } : {}),
});

export async function chat(e: Endpoint, q: ChatRequest): Promise<ChatResult> {
  const res = await post(e, '/chat/completions', body(q, false));
  return normalizeChat(await res.json());
}

/** Pull text pieces out of one SSE "data:" payload, whatever the provider's shape. */
export function deltaText(payload: unknown): string {
  const p = (payload ?? {}) as Record<string, unknown>;
  const c = (p.choices as { delta?: { content?: string }; text?: string }[] | undefined)?.[0];
  if (c?.delta?.content) return c.delta.content;
  if (typeof c?.text === 'string') return c.text;
  if (typeof p.text === 'string') return p.text;
  if (typeof p.delta === 'string') return p.delta;
  if (typeof p.content === 'string') return p.content;
  return '';
}

/** Stream text as it arrives. Falls back to a single chunk when the server ignores stream:true. */
export async function* chatStream(e: Endpoint, q: ChatRequest): AsyncGenerator<string, Usage | null> {
  const res = await post(e, '/chat/completions', body(q, true));
  const type = res.headers.get('content-type') ?? '';
  if (!type.includes('text/event-stream') || !res.body) {
    const r = normalizeChat(await res.json());
    if (r.text) yield r.text;
    return r.usage;
  }
  let usage: Usage | null = null, buf = '';
  const dec = new TextDecoder();
  for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
    buf += dec.decode(chunk, { stream: true });
    let nl: number;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
      if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (!data || data === '[DONE]') continue;
      try {
        const j = JSON.parse(data);
        usage = normalizeUsage(j.usage) ?? usage;
        const t = deltaText(j);
        if (t) yield t;
      } catch { /* ignore keep-alives and partial junk */ }
    }
  }
  return usage;
}

/** Text to speech (/audio/speech) — returns the audio bytes and their type. */
export async function speech(e: Endpoint, q: { model: string; input: string; voice?: string; format?: 'mp3' | 'wav' | 'opus' }): Promise<{ audio: Buffer; contentType: string }> {
  const res = await post(e, '/audio/speech', { model: q.model, input: q.input, voice: q.voice ?? 'alloy', response_format: q.format ?? 'mp3' });
  return { audio: Buffer.from(await res.arrayBuffer()), contentType: res.headers.get('content-type') ?? 'audio/mpeg' };
}

/** Speech to text (/audio/transcriptions). */
export async function transcribe(e: Endpoint, q: { model: string; audio: Buffer; filename?: string; language?: string }): Promise<string> {
  const form = new FormData();
  form.append('file', new Blob([new Uint8Array(q.audio)]), q.filename ?? 'audio.wav');
  form.append('model', q.model);
  if (q.language) form.append('language', q.language);
  let res: Response;
  try {
    res = await (e.fetch ?? fetch)(`${e.baseUrl}/audio/transcriptions`, { method: 'POST', headers: headers(e, false), body: form, signal: AbortSignal.timeout(120_000) });
  } catch { throw new AiError('سرور ارائه‌دهنده در دسترس نیست (شبکه یا تحریم).'); }
  if (!res.ok) throw errorFor(res.status, await res.json().catch(() => null));
  const j = await res.json() as { text?: string };
  return j.text ?? '';
}

/** Upload a file (/files) — returns the provider's id and, if given, its URL (togpt.ir returns one). */
export async function uploadFile(e: Endpoint, q: { data: Buffer; filename: string; type: string; purpose?: string }): Promise<{ id: string; url: string | null }> {
  const form = new FormData();
  form.append('file', new Blob([new Uint8Array(q.data)], { type: q.type }), q.filename);
  form.append('purpose', q.purpose ?? 'assistants');
  let res: Response;
  try {
    res = await (e.fetch ?? fetch)(`${e.baseUrl}/files`, { method: 'POST', headers: headers(e, false), body: form, signal: AbortSignal.timeout(120_000) });
  } catch { throw new AiError('سرور ارائه‌دهنده در دسترس نیست (شبکه یا تحریم).'); }
  if (!res.ok) throw errorFor(res.status, await res.json().catch(() => null));
  const j = await res.json() as { id?: string; url?: string };
  if (!j.id) throw new AiError('پاسخ آپلود فایل شناسه نداشت.');
  const url = j.url ? (/^https?:/.test(j.url) ? j.url : new URL(j.url, e.baseUrl).toString()) : null;
  return { id: j.id, url };
}

/**
 * Check that a key is accepted WITHOUT spending credit: an intentionally invalid chat request
 * (no messages). A rejected key answers 401/403; an accepted one gets a validation error (400/422).
 * Needed because some gateways (e.g. togpt.ir) list models publicly, without checking the key.
 */
export async function verifyKey(e: Endpoint): Promise<void> {
  let res: Response;
  try {
    res = await (e.fetch ?? fetch)(`${e.baseUrl}/chat/completions`, {
      method: 'POST', headers: headers(e), body: JSON.stringify({ model: '', messages: [] }), signal: AbortSignal.timeout(15_000),
    });
  } catch { throw new AiError('سرور ارائه‌دهنده در دسترس نیست (شبکه یا تحریم).'); }
  if (res.status === 401 || res.status === 403) throw errorFor(res.status, null);
  if (res.status === 402) throw errorFor(402, null);
}
