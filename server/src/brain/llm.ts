// Talk to the "brain" the owner chose in the admin panel (main model, then fallback).
import type { Db } from '../db.js';
import { AiError, chat, type ChatResult, type Message } from '../ai/openai-compat.js';
import { endpointFor, type Fetcher, listRoutes, ProviderError } from '../providers.js';

export class NoBrainError extends Error {
  constructor() { super('هنوز هوش مصنوعی‌ای برای «مغز» انتخاب نشده (پنل ادمین ← هوش مصنوعی و کلیدها).'); }
}

export interface BrainDeps { db: Db; masterKey: Buffer | null; fetcher?: Fetcher }

export async function askBrain(deps: BrainDeps, messages: Message[], opts: { json?: boolean; maxTokens?: number } = {}): Promise<ChatResult & { model: string }> {
  const route = (await listRoutes(deps.db)).find(r => r.capability === 'chat');
  const tries = [[route?.keyId, route?.model], [route?.fallbackKeyId, route?.fallbackModel]].filter(([k, m]) => k && m) as [string, string][];
  if (!tries.length) throw new NoBrainError();
  const errors: string[] = [];
  for (const [keyId, model] of tries) {
    try {
      const ep = await endpointFor(deps.db, deps.masterKey, keyId, deps.fetcher);
      try {
        return { ...(await chat(ep, { model, messages, maxTokens: opts.maxTokens ?? 1200, json: opts.json })), model };
      } catch (e) {
        // Some providers reject response_format; retry once without it.
        if (opts.json && e instanceof AiError && e.status === 400) return { ...(await chat(ep, { model, messages, maxTokens: opts.maxTokens ?? 1200 })), model };
        throw e;
      }
    } catch (e) {
      errors.push(`${model}: ${e instanceof AiError || e instanceof ProviderError ? e.message : 'خطای ناشناخته'}`);
    }
  }
  throw new AiError(errors.join(' — '));
}

/** First JSON object in a model reply (tolerates ```json fences and chatter around it). */
export function extractJson(text: string): unknown {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const body = fenced ? fenced[1] : text;
  const start = body.indexOf('{');
  if (start < 0) throw new Error('no json');
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < body.length; i++) {
    const c = body[i];
    if (inStr) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === '"') inStr = false; continue; }
    if (c === '"') inStr = true;
    else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return JSON.parse(body.slice(start, i + 1));
  }
  throw new Error('unterminated json');
}
