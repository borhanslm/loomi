// Automatic model choice: look at the models each saved key can reach, recognise what every
// model is good for, and suggest the best main + fallback per capability — in Persian, with reasons.
// Works with plain ids ("gpt-5-mini") and gateway ids ("openai/gpt-5", "google/gemini-3.5-flash").
import type { Capability, ProviderKey } from '../providers.js';
import { providerInfo } from '../providers.js';

export type Kind = 'chat' | 'stt' | 'tts' | 'embed' | 'image' | 'video' | 'other';

export interface ModelInfo { kind: Kind; vision: boolean; score: number; family: string; why: string }

const has = (id: string, re: RegExp) => re.test(id);

/** What a model id is for, and how good a fit it is for Loomi's everyday Persian brain. */
export function classify(rawId: string): ModelInfo {
  const id = rawId.toLowerCase();
  const name = id.includes('/') ? id.slice(id.lastIndexOf('/') + 1) : id;
  const family = id.includes('/') ? id.slice(0, id.indexOf('/')) : guessFamily(name);

  if (has(id, /transcri|whisper|scribe|speech-to-text|(?<![a-z])stt(?![a-z])/)) return { kind: 'stt', vision: false, score: sttScore(name), family, why: 'گفتار به متن' };
  if (has(id, /(?<![a-z])tts|text-to-speech|eleven(?!.*scribe)|sonic/)) return { kind: 'tts', vision: false, score: ttsScore(name), family, why: 'متن به گفتار (صدا)' };
  if (has(id, /embed/)) return { kind: 'embed', vision: false, score: embedScore(name), family, why: 'جست‌وجوی معنایی' };
  if (has(id, /veo|sora|kling|seedance|video|wan-|hailuo|runway/)) return { kind: 'video', vision: false, score: 0, family, why: 'ساخت ویدئو' };
  if (has(id, /image|dall-?e|flux|imagen|stable-diffusion|sdxl|midjourney|banana/)) return { kind: 'image', vision: false, score: 0, family, why: 'ساخت تصویر' };
  if (has(id, /moderation|rerank|guard|realtime|search-preview|computer-use|codex|deep-research/)) return { kind: 'other', vision: false, score: 0, family, why: 'کاربرد خاص' };

  // a chat model: score = fit for a fast, reliable Persian assistant (quality, speed, price)
  let score = 50, why = 'مدل گفت‌وگو';
  const v = versionOf(name);
  if (has(name, /claude/)) {
    if (has(name, /haiku/)) { score = 82; why = 'سریع و ارزان، فارسی خوب'; }
    else if (has(name, /sonnet/)) { score = 90; why = 'فهم بسیار خوب و دقیق، سرعت مناسب'; }
    else if (has(name, /opus/)) { score = 84; why = 'قوی‌ترین، ولی کندتر و گران‌تر'; }
    else score = 80;
  } else if (has(name, /gpt|chatgpt/)) {
    if (has(name, /nano/)) { score = 76; why = 'خیلی سریع و ارزان، برای کارهای ساده'; }
    else if (has(name, /mini/)) { score = 88; why = 'سریع و ارزان، فارسی خوب'; }
    else if (has(name, /gpt-?4o/)) { score = 80; why = 'سریع و همه‌کاره'; }
    else { score = 89; why = 'فهم بسیار خوب'; }
  } else if (has(name, /^o\d|[^a-z]o\d(-|$)/)) { score = 66; why = 'استدلال قوی، ولی کند برای کارهای روزمره'; }
  else if (has(name, /gemini|gemma/)) {
    if (has(name, /flash-lite|lite/)) { score = 80; why = 'خیلی سریع و ارزان'; }
    else if (has(name, /flash/)) { score = 89; why = 'سریع و ارزان، فارسی خوب'; }
    else if (has(name, /pro/)) { score = 87; why = 'فهم بسیار خوب، کمی کندتر'; }
    else if (has(name, /gemma/)) { score = 64; why = 'مدل باز کوچک'; }
    else score = 78;
  } else if (has(name, /deepseek/)) { score = has(name, /reason|r1/) ? 66 : 82; why = has(name, /reason|r1/) ? 'استدلال قوی، ولی کند' : 'ارزان و توانا'; }
  else if (has(name, /grok/)) { score = 78; why = 'توانا'; }
  else if (has(name, /qwen/)) { score = 72; why = 'مدل باز توانا'; }
  else if (has(name, /mistral|mixtral/)) { score = 66; why = 'مدل باز، فارسی متوسط'; }
  else if (has(name, /llama/)) { score = 62; why = 'مدل باز، فارسی متوسط'; }
  if (has(name, /preview|exp|beta/)) score -= 2;
  if (has(name, /fast|turbo/)) score += 1;
  if (has(name, /thinking|reason/)) score -= 8;
  score += Math.min(v, 9) * 0.6; // newer generations are usually better
  const vision = has(name, /claude|gpt-?4o|gpt-?4\.1|gpt-?5|gemini|vision|vl|llava|pixtral|grok-?\d.*vision/) && !has(name, /nano/);
  return { kind: 'chat', vision, score, family, why };
}

function guessFamily(name: string): string {
  if (/claude/.test(name)) return 'anthropic';
  if (/gpt|^o\d|whisper|tts|dall/.test(name)) return 'openai';
  if (/gemini|gemma|imagen|veo/.test(name)) return 'google';
  if (/deepseek/.test(name)) return 'deepseek';
  if (/eleven|scribe/.test(name)) return 'elevenlabs';
  return name.split(/[-:]/)[0];
}
function versionOf(name: string): number {
  const m = name.match(/(\d+(?:\.\d+)?)/);
  return m ? Number(m[1]) : 0;
}
const sttScore = (n: string) => (/scribe/.test(n) ? 85 : /gpt-?4o-transcribe/.test(n) ? 88 : /mini-transcribe/.test(n) ? 86 : /whisper/.test(n) ? 80 : 70);
const ttsScore = (n: string) => (/eleven/.test(n) ? 90 : /gpt-?4o-mini-tts/.test(n) ? 84 : /tts-1-hd/.test(n) ? 80 : /tts/.test(n) ? 76 : 60);
const embedScore = (n: string) => (/text-embedding-3-large/.test(n) ? 90 : /text-embedding-3-small/.test(n) ? 86 : /gemini-embedding|text-embedding-004/.test(n) ? 86 : /bge-m3|e5|nomic/.test(n) ? 78 : 70);

/** Does a model (on a provider) fit a capability? */
export function fits(cap: Capability, provider: string, model: string): boolean {
  const c = classify(model);
  // A direct ElevenLabs key lists voices, not models; any of them can speak.
  if (provider === 'elevenlabs') return cap === 'tts' ? !/scribe/i.test(model) : cap === 'stt' ? /scribe/i.test(model) : false;
  if (cap === 'chat') return c.kind === 'chat';
  if (cap === 'vision') return c.kind === 'chat' && c.vision;
  return c.kind === cap;
}

export interface Pick { keyId: string; keyLabel: string; model: string; why: string; score: number }
export interface Suggestion {
  capability: Capability;
  main: Pick | null;
  fallback: Pick | null;
  /** the best few, for «which ones are suitable?» */
  options: Pick[];
  /** why nothing could be suggested */
  missing: string | null;
}

const CAP_NEEDS: Record<Capability, string> = {
  chat: 'هیچ‌کدام از کلیدها مدل گفت‌وگو ندارند.',
  stt: 'هیچ مدل «گفتار به متن» پیدا نشد (مثل gpt-4o-mini-transcribe، whisper یا ElevenLabs Scribe).',
  tts: 'هیچ مدل «متن به گفتار» پیدا نشد (مثل ElevenLabs یا gpt-4o-mini-tts).',
  embed: 'هیچ مدل embedding پیدا نشد (مثل text-embedding-3-small). این توانایی فعلاً لازم نیست.',
  vision: 'هیچ مدلی که عکس بفهمد پیدا نشد.',
};

export function suggest(cap: Capability, keys: ProviderKey[]): Suggestion {
  const all: Pick[] = [];
  for (const k of keys) {
    if (k.lastTestOk === false) continue; // a key that failed its test is not a good suggestion
    if (!providerInfo(k.provider)?.caps.includes(cap)) continue;
    for (const m of k.models) {
      if (!fits(cap, k.provider, m)) continue;
      const c = classify(m);
      let score = k.provider === 'elevenlabs' ? 88 : c.score;
      if (cap === 'vision' && c.kind === 'chat') score = c.score; // same scale
      all.push({ keyId: k.id, keyLabel: k.label, model: m, why: k.provider === 'elevenlabs' && cap === 'tts' ? 'صدای ElevenLabs' : c.why, score });
    }
  }
  all.sort((a, b) => b.score - a.score || a.model.length - b.model.length);
  // one option per model name (the same model may be reachable through two keys)
  const seen = new Set<string>();
  const options = all.filter(p => (seen.has(p.model) ? false : (seen.add(p.model), true)));
  const main = options[0] ?? null;
  // fallback: prefer a different family/key, so one outage does not take both down
  const fam = (p: Pick) => classify(p.model).family;
  const fallback = main ? options.find(p => p !== main && (fam(p) !== fam(main) || p.keyId !== main.keyId)) ?? options[1] ?? null : null;
  return { capability: cap, main, fallback, options: options.slice(0, 6), missing: main ? null : CAP_NEEDS[cap] };
}

/** Is the saved choice sensible? Returns a Persian warning, or null when fine. */
export function checkChoice(cap: Capability, key: ProviderKey | undefined, model: string | null): string | null {
  if (!key || !model) return null;
  if (fits(cap, key.provider, model)) return null;
  const c = classify(model);
  return `«${model}» برای این کار مناسب نیست؛ این مدل برای ${c.why} است.`;
}
