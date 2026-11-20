import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { ensureOwner, migrate, openDb, type Db } from '../src/db.js';
import { createPairCode } from '../src/devices.js';
import { parseMasterKey, seal } from '../src/crypto.js';
import { soundsLikeQuestion, voiceIdOf } from '../src/voice.js';

const MK = 'd'.repeat(64);
const wav = Buffer.alloc(4000, 1);

describe('voice', () => {
  let db: Db, app: FastifyInstance, token = '';
  let heardText = 'فردا ساعت ۱۰ جلسه با علی';
  const calls: { url: string; headers: Record<string, string> }[] = [];
  const fake = (async (url: string, init?: RequestInit) => {
    const u = String(url);
    calls.push({ url: u, headers: Object.fromEntries(Object.entries((init?.headers ?? {}) as Record<string, string>)) });
    if (u.endsWith('/audio/transcriptions') || u.endsWith('/speech-to-text')) return Response.json({ text: heardText });
    if (u.endsWith('/audio/speech') || u.includes('/text-to-speech/')) return new Response(new Uint8Array([0x49, 0x44, 0x33, 1, 2, 3]), { headers: { 'content-type': 'audio/mpeg' } });
    return Response.json({ data: [] });
  }) as unknown as typeof fetch;
  const auth = (extra: Record<string, string> = {}) => ({ authorization: `Bearer ${token}`, ...extra });
  const addKey = async (id: string, provider: string, baseUrl: string | null) =>
    db.query(`INSERT INTO provider_keys (id, provider, label, base_url, key_sealed, key_last4) VALUES ($1, $2, 'x', $3, $4, 'abcd')`,
      [id, provider, baseUrl, seal('sk-test', parseMasterKey(MK))]);
  const route = async (cap: string, keyId: string, model: string) =>
    db.query(`INSERT INTO capability_routes (capability, key_id, model) VALUES ($1, $2, $3)
              ON CONFLICT (capability) DO UPDATE SET key_id = $2, model = $3`, [cap, keyId, model]);
  const voice = (qs = '') => app.inject({ method: 'POST', url: `/v1/voice${qs}`, headers: auth({ 'content-type': 'audio/wav' }), payload: wav });

  beforeAll(async () => {
    const config = { ...loadConfig({}), dataDir: ':memory:', masterKey: MK };
    db = await openDb(config); await migrate(db);
    const owner = await ensureOwner(db);
    app = await buildApp({ db, config, fetcher: fake, reminderEveryMs: 0 });
    const { code } = await createPairCode(db, owner.id, 5);
    token = (await app.inject({ method: 'POST', url: '/v1/pair', payload: { code, name: 'گوشی' } })).json().token;
  });
  afterAll(async () => { await app.close(); await db.close(); });

  it('explains when no ears or voice are set', async () => {
    const r = await voice();
    expect(r.statusCode).toBe(409);
    expect(r.json().error).toContain('شنیدن');
    const s = await app.inject({ method: 'POST', url: '/v1/speak', headers: auth(), payload: { text: 'سلام' } });
    expect(s.statusCode).toBe(409);
  });

  it('hears a capture and saves it', async () => {
    await addKey('k-oa', 'custom', 'https://ai.example/v1');
    await route('stt', 'k-oa', 'gpt-4o-mini-transcribe');
    const r = await voice('?tzOffset=210');
    expect(r.statusCode).toBe(200);
    const j = r.json();
    expect(j).toMatchObject({ text: 'فردا ساعت ۱۰ جلسه با علی', kind: 'capture', sttModel: 'gpt-4o-mini-transcribe', canSpeak: false, answer: null });
    expect(j.capture.items[0].dueAt).not.toBeNull();
    expect(calls.at(-1)!.url).toBe('https://ai.example/v1/audio/transcriptions');
  });

  it('answers a spoken question', async () => {
    heardText = 'فردا چی کار دارم';
    const j = (await voice()).json();
    expect(j.kind).toBe('answer');
    expect(j.answer.answer).toContain('جلسه با علی');
    // forced modes
    expect((await voice('?mode=capture')).json().kind).toBe('capture');
    heardText = 'نان بخرم';
    expect((await voice('?mode=ask')).json().kind).toBe('answer');
  });

  it('handles silence and bad bodies', async () => {
    heardText = '  ';
    expect((await voice()).json()).toMatchObject({ kind: 'empty', capture: null, answer: null });
    const tiny = await app.inject({ method: 'POST', url: '/v1/voice', headers: auth({ 'content-type': 'audio/wav' }), payload: Buffer.alloc(10) });
    expect(tiny.statusCode).toBe(400);
    expect((await app.inject({ method: 'POST', url: '/v1/voice', headers: { 'content-type': 'audio/wav' }, payload: wav })).statusCode).toBe(401);
  });

  it('speaks with an OpenAI-compatible voice', async () => {
    await route('tts', 'k-oa', 'gpt-4o-mini-tts');
    const s = await app.inject({ method: 'POST', url: '/v1/speak', headers: auth(), payload: { text: 'سلام' } });
    expect(s.statusCode).toBe(200);
    expect(s.headers['content-type']).toBe('audio/mpeg');
    expect(s.rawPayload.subarray(0, 3).toString()).toBe('ID3');
    heardText = 'سلام';
    expect((await voice()).json().canSpeak).toBe(true);
  });

  it('uses ElevenLabs’ own API for a direct ElevenLabs key', async () => {
    await addKey('k-el', 'elevenlabs', null);
    await route('tts', 'k-el', 'Rachel (21m00Tcm4TlvDq8ikWAM)');
    await route('stt', 'k-el', 'scribe_v1');
    const s = await app.inject({ method: 'POST', url: '/v1/speak', headers: auth(), payload: { text: 'سلام' } });
    expect(s.statusCode).toBe(200);
    const tts = calls.find(c => c.url.includes('/text-to-speech/'))!;
    expect(tts.url).toBe('https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM?output_format=mp3_44100_128');
    expect(tts.headers['xi-api-key']).toBe('sk-test');
    heardText = 'ایده: کافه کتاب';
    expect((await voice()).json().kind).toBe('capture');
    expect(calls.at(-1)!.url).toBe('https://api.elevenlabs.io/v1/speech-to-text');
  });
});

describe('voice helpers', () => {
  it('guesses spoken questions', () => {
    expect(soundsLikeQuestion('فردا چی کار دارم')).toBe(true);
    expect(soundsLikeQuestion('قرارم با علی کیه')).toBe(true);
    expect(soundsLikeQuestion('چند تا خرید دارم')).toBe(true);
    expect(soundsLikeQuestion('ساعت ۵ جلسه دارم؟')).toBe(true);
    expect(soundsLikeQuestion('فردا ساعت ۵ جلسه دارم')).toBe(false);
    expect(soundsLikeQuestion('شیر و نان بخرم')).toBe(false);
    expect(soundsLikeQuestion('یادم بنداز به چیدمان خونه فکر کنم')).toBe(false);
  });
  it('reads ElevenLabs voice ids', () => {
    expect(voiceIdOf('Rachel (21m00Tcm4TlvDq8ikWAM)')).toBe('21m00Tcm4TlvDq8ikWAM');
    expect(voiceIdOf('21m00Tcm4TlvDq8ikWAM')).toBe('21m00Tcm4TlvDq8ikWAM');
  });
});
