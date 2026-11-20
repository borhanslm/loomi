// Loomi's ears and voice: speech → text («شنیدن») and text → speech («صدای لومی»), each with the
// provider the owner chose in the admin panel (main, then fallback). OpenAI-compatible APIs
// (OpenAI, togpt.ir, custom…) use /audio/*; a direct ElevenLabs key uses ElevenLabs' own API.
import type { Db } from './db.js';
import { AiError, errorFor, speech, transcribe } from './ai/openai-compat.js';
import { endpointFor, type Fetcher, listRoutes, ProviderError, secretFor } from './providers.js';

export class NoVoiceError extends Error {
  constructor(public cap: 'stt' | 'tts') {
    super(cap === 'stt'
      ? 'هنوز برای «شنیدن» مدلی انتخاب نشده (پنل ادمین ← هوش مصنوعی و کلیدها).'
      : 'هنوز برای «صدای لومی» مدلی انتخاب نشده (پنل ادمین ← هوش مصنوعی و کلیدها).');
  }
}

export interface VoiceDeps { db: Db; masterKey: Buffer | null; fetcher?: Fetcher }

async function tries(db: Db, cap: 'stt' | 'tts'): Promise<[string, string][]> {
  const r = (await listRoutes(db)).find(x => x.capability === cap);
  const list = [[r?.keyId, r?.model], [r?.fallbackKeyId, r?.fallbackModel]].filter(([k, m]) => k && m) as [string, string][];
  if (!list.length) throw new NoVoiceError(cap);
  return list;
}

export async function canSpeak(db: Db): Promise<boolean> {
  return (await listRoutes(db)).some(r => r.capability === 'tts' && r.keyId && r.model);
}

/** ElevenLabs lists voices as «Name (voice_id)»; a bare id works too. */
export const voiceIdOf = (model: string) => model.match(/\(([A-Za-z0-9]+)\)\s*$/)?.[1] ?? model.trim();

const ELEVEN = 'https://api.elevenlabs.io/v1';

async function elevenFetch(f: Fetcher, url: string, init: RequestInit): Promise<Response> {
  let res: Response;
  try {
    res = await f(url, { ...init, signal: AbortSignal.timeout(120_000) });
  } catch { throw new AiError('سرور ارائه‌دهنده در دسترس نیست (شبکه یا تحریم).'); }
  if (!res.ok) throw errorFor(res.status, await res.json().catch(() => null));
  return res;
}

/** Speech → text. `audio` is a whole recording (wav, m4a, mp3, webm…). */
export async function hear(deps: VoiceDeps, audio: Buffer, filename: string, mime: string): Promise<{ text: string; model: string }> {
  const errors: string[] = [];
  for (const [keyId, model] of await tries(deps.db, 'stt')) {
    try {
      const s = await secretFor(deps.db, deps.masterKey, keyId);
      if (s?.provider === 'elevenlabs') {
        const form = new FormData();
        form.append('file', new Blob([new Uint8Array(audio)], { type: mime }), filename);
        form.append('model_id', /scribe/i.test(model) ? model : 'scribe_v1');
        form.append('language_code', 'fas');
        const res = await elevenFetch(deps.fetcher ?? fetch, `${ELEVEN}/speech-to-text`, { method: 'POST', headers: { 'xi-api-key': s.apiKey ?? '' }, body: form });
        return { text: String(((await res.json()) as { text?: string }).text ?? '').trim(), model };
      }
      const ep = await endpointFor(deps.db, deps.masterKey, keyId, deps.fetcher);
      return { text: (await transcribe(ep, { model, audio, filename, language: 'fa' })).trim(), model };
    } catch (e) {
      errors.push(`${model}: ${e instanceof AiError || e instanceof ProviderError ? e.message : 'خطای ناشناخته'}`);
    }
  }
  throw new AiError(errors.join(' — '));
}

/** Text → speech (mp3). */
export async function speak(deps: VoiceDeps, text: string): Promise<{ audio: Buffer; contentType: string }> {
  const errors: string[] = [];
  for (const [keyId, model] of await tries(deps.db, 'tts')) {
    try {
      const s = await secretFor(deps.db, deps.masterKey, keyId);
      if (s?.provider === 'elevenlabs') {
        const res = await elevenFetch(deps.fetcher ?? fetch, `${ELEVEN}/text-to-speech/${encodeURIComponent(voiceIdOf(model))}?output_format=mp3_44100_128`, {
          method: 'POST',
          headers: { 'xi-api-key': s.apiKey ?? '', 'content-type': 'application/json', accept: 'audio/mpeg' },
          body: JSON.stringify({ text, model_id: 'eleven_v3' }),
        });
        return { audio: Buffer.from(await res.arrayBuffer()), contentType: 'audio/mpeg' };
      }
      const ep = await endpointFor(deps.db, deps.masterKey, keyId, deps.fetcher);
      return await speech(ep, { model, input: text, format: 'mp3' });
    } catch (e) {
      errors.push(`${model}: ${e instanceof AiError || e instanceof ProviderError ? e.message : 'خطای ناشناخته'}`);
    }
  }
  throw new AiError(errors.join(' — '));
}

const QUESTION_WORDS = /(^|\s)(چی|چیه|چه|چطور|چطوری|کی|کیه|کجا|کجاست|کدوم|کدام|آیا|چند|چندتا|چرا)(?=\s|$|[؟?،.!])/;

/** Spoken text has no «؟», so guess: a question mark, or a question word. */
export function soundsLikeQuestion(text: string): boolean {
  const t = text.trim();
  return /[؟?]\s*$/.test(t) || QUESTION_WORDS.test(t.replace(/[ي]/g, 'ی'));
}
