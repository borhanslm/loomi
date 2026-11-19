import { describe, expect, it } from 'vitest';
import { checkChoice, classify, suggest } from '../src/ai/recommend.js';
import type { ProviderKey } from '../src/providers.js';

// The real togpt.ir model list (as of this writing), plus a few others.
const TOGPT = [
  'anthropic/claude-opus-4.7', 'anthropic/claude-sonnet-4.6', 'anthropic/claude-opus-4.8-fast',
  'deepseek/deepseek-v4-flash', 'deepseek/deepseek-v4-pro', 'deepseek/deepseek-v4.1-flash',
  'elevenlabs/eleven-v4',
  'google/gemini-3-flash-preview', 'google/gemini-3.1-flash-lite-preview', 'google/gemini-3.1-pro-preview',
  'google/gemini-3.6-flash', 'google/gemini-3.7-flash', 'google/gemini-3.1-flash-image', 'google/gemini-3.5-flash',
  'google/gemini-3.5-flash-lite', 'google/gemini-4-hydrogen', 'google/gemini-3-pro-image', 'google/veo-3.1-fast', 'google/veo-3.1-lite',
  'openai/gpt-5', 'openai/gpt-5-mini', 'openai/gpt-5-nano', 'openai/gpt-5.4-image-2', 'openai/gpt-5.5', 'openai/sora-2-pro',
  'openai/gpt-4o-mini-transcribe', 'kwaivgi/kling-v3.0-pro', 'bytedance/seedance-1-5-pro',
];
const key = (over: Partial<ProviderKey>): ProviderKey => ({
  id: 'k1', provider: 'togpt', label: 'voice', baseUrl: null, keyLast4: '1234', models: TOGPT,
  lastTestAt: null, lastTestOk: true, lastTestMsg: null, ...over,
});

describe('classify', () => {
  it.each([
    ['elevenlabs/eleven-v4', 'tts'], ['openai/gpt-4o-mini-transcribe', 'stt'], ['whisper-1', 'stt'], ['scribe_v1', 'stt'],
    ['text-embedding-3-small', 'embed'], ['google/veo-3.1-fast', 'video'], ['openai/sora-2-pro', 'video'],
    ['google/gemini-3.1-flash-image', 'image'], ['openai/gpt-5.4-image-2', 'image'], ['dall-e-3', 'image'],
    ['openai/gpt-5-mini', 'chat'], ['anthropic/claude-sonnet-4.6', 'chat'], ['google/gemini-3.5-flash', 'chat'], ['deepseek-chat', 'chat'],
  ])('%s → %s', (m, kind) => expect(classify(m).kind).toBe(kind));

  it('prefers fast, capable models for the everyday brain over slow or tiny ones', () => {
    const s = (m: string) => classify(m).score;
    expect(s('openai/gpt-5-mini')).toBeGreaterThan(s('openai/gpt-5-nano'));
    expect(s('anthropic/claude-sonnet-4.6')).toBeGreaterThan(s('anthropic/claude-opus-4.7'));
    expect(s('google/gemini-3.5-flash')).toBeGreaterThan(s('google/gemini-3.5-flash-lite'));
    expect(s('o3')).toBeLessThan(s('gpt-5-mini'));
  });
});

describe('suggest', () => {
  it('picks a chat brain with a fallback from another family, and lists suitable options', () => {
    const r = suggest('chat', [key({})]);
    expect(r.main).not.toBeNull();
    expect(classify(r.main!.model).kind).toBe('chat');
    expect(classify(r.fallback!.model).family).not.toBe(classify(r.main!.model).family);
    expect(r.options.length).toBeGreaterThan(2);
    for (const o of r.options) expect(o.model).not.toMatch(/image|veo|sora|kling|seedance|eleven|transcribe/);
  });

  it('chooses real listening and voice models', () => {
    expect(suggest('stt', [key({})]).main?.model).toBe('openai/gpt-4o-mini-transcribe');
    expect(suggest('tts', [key({})]).main?.model).toBe('elevenlabs/eleven-v4');
  });

  it('explains what is missing', () => {
    const r = suggest('embed', [key({})]);
    expect(r.main).toBeNull();
    expect(r.missing).toContain('embedding');
  });

  it('ignores keys that failed their test', () => {
    expect(suggest('chat', [key({ lastTestOk: false })]).main).toBeNull();
  });

  it('flags a voice model chosen for listening (the mistake in the screenshot)', () => {
    expect(checkChoice('stt', key({}), 'elevenlabs/eleven-v4')).toContain('مناسب نیست');
    expect(checkChoice('stt', key({}), 'openai/gpt-4o-mini-transcribe')).toBeNull();
    expect(checkChoice('chat', key({}), 'google/veo-3.1-fast')).toContain('ویدئو');
  });
});
