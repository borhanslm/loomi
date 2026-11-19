// The heart of the second brain: one free-form Persian sentence → clean, typed items.
//   «فردا ساعت ۱۰ جلسه با علی، قبلش قرارداد رو چاپ کنم. شیر و نون هم بخرم»
//   → event «جلسه با علی» (tomorrow 10:00), task «چاپ قرارداد», shopping «شیر», shopping «نان»
// Uses the AI brain when available; otherwise (or if it fails) simple Persian rules, so capturing
// never fails and times are still understood.
import { describeNow, normalizeFa, parseWhen } from '../fa/time.js';
import { askBrain, type BrainDeps, extractJson, NoBrainError } from './llm.js';

export const ITEM_TYPES = ['task', 'reminder', 'shopping', 'idea', 'note', 'event'] as const;
export type ItemType = (typeof ITEM_TYPES)[number];

export interface Draft {
  type: ItemType;
  title: string;
  notes: string | null;
  dueAt: Date | null;
  allDay: boolean;
  people: string[];
  place: string | null;
}

export interface Understanding { items: Draft[]; via: 'ai' | 'rules'; model: string | null; warning: string | null }

const SYSTEM = `تو «لومی» هستی، ذهن دوم یک کاربر فارسی‌زبان. کاربر هر چه در ذهنش است را می‌نویسد.
کار تو: متن را به فهرست «مورد»های جدا تبدیل کن. فقط JSON برگردان، بدون هیچ توضیح دیگری، با این شکل:
{"items":[{"type":"task|reminder|shopping|idea|note|event","title":"...","notes":null,"when_text":null,"when":null,"all_day":false,"people":[],"place":null}]}

قواعد:
- type: task = کاری که باید انجام شود؛ reminder = «یادم بنداز…» یا هر چیزی که فقط باید سر وقت یادآوری شود؛ shopping = چیزی برای خریدن (هر جنس یک مورد جدا)؛ idea = ایده؛ note = یادداشت یا فکر یا اطلاعات؛ event = قرار، جلسه، مهمانی، وقت دکتر.
- title: کوتاه، روشن، به فارسی، بدون کلمه‌های زمانی و بدون «یادم بنداز». برای خرید فقط اسم جنس (مثلاً «نان»). فعل‌های محاوره را رسمی و کوتاه کن (مثلاً «قرارداد رو چاپ کنم» ← «چاپ قرارداد»).
- when_text: دقیقاً همان بخش از متن کاربر که زمان را می‌گوید (مثل «فردا ساعت ۱۰»)، یا null.
- when: همان زمان به وقت محلی کاربر به شکل "YYYY-MM-DDTHH:mm"، یا null. اگر فقط روز گفته شده، ساعت 09:00 و all_day=true.
- «قبلش» / «بعدش» یعنی نسبت به مورد قبلی؛ زمان آن را از همان مورد حساب کن.
- people: اسم آدم‌هایی که در مورد آمده‌اند. place: مکان اگر گفته شده.
- چیزی از خودت اضافه نکن و چیزی را جا نینداز.`;

/** Understand a capture. `offsetMin` is the user's UTC offset in minutes. */
export async function understand(text: string, now: Date, offsetMin: number, deps: BrainDeps | null): Promise<Understanding> {
  const clean = text.trim();
  if (deps) {
    try {
      const r = await askBrain(deps, [
        { role: 'system', content: SYSTEM },
        { role: 'user', content: `اکنون: ${describeNow(now, offsetMin)}\n\nمتن کاربر:\n${clean}` },
      ], { json: true });
      const items = fromAi(extractJson(r.text), now, offsetMin);
      if (items.length) return { items, via: 'ai', model: r.model, warning: null };
    } catch (e) {
      const warning = e instanceof NoBrainError ? null : 'هوش مصنوعی در دسترس نبود؛ با قواعد ساده فهمیده شد.';
      return { items: byRules(clean, now, offsetMin), via: 'rules', model: null, warning };
    }
  }
  return { items: byRules(clean, now, offsetMin), via: 'rules', model: null, warning: null };
}

// ── from the AI's JSON ──
function fromAi(j: unknown, now: Date, offsetMin: number): Draft[] {
  const raw = (j as { items?: unknown[] })?.items;
  if (!Array.isArray(raw)) return [];
  const out: Draft[] = [];
  for (const x of raw.slice(0, 30)) {
    const o = (x ?? {}) as Record<string, unknown>;
    const title = String(o.title ?? '').trim().slice(0, 200);
    if (!title) continue;
    const type = (ITEM_TYPES as readonly string[]).includes(String(o.type)) ? (o.type as ItemType) : 'note';
    // Our own Persian parser is exact for the phrases it knows; trust it first, then the model's date.
    let dueAt: Date | null = null, allDay = Boolean(o.all_day);
    const parsed = typeof o.when_text === 'string' && o.when_text ? parseWhen(o.when_text, now, offsetMin) : null;
    if (parsed) { dueAt = parsed.at; allDay = parsed.allDay; }
    else if (typeof o.when === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(o.when)) {
      const [d, t] = o.when.split('T');
      const [y, m, dd] = d.split('-').map(Number), [hh, mm] = t.slice(0, 5).split(':').map(Number);
      dueAt = new Date(Date.UTC(y, m - 1, dd, hh, mm) - offsetMin * 60_000);
    }
    out.push({
      type, title,
      notes: typeof o.notes === 'string' && o.notes.trim() ? o.notes.trim().slice(0, 2000) : null,
      dueAt, allDay: dueAt ? allDay : false,
      people: Array.isArray(o.people) ? o.people.map(String).filter(Boolean).slice(0, 10) : [],
      place: typeof o.place === 'string' && o.place.trim() ? o.place.trim().slice(0, 120) : null,
    });
  }
  return out;
}

// ── simple Persian rules (no AI) ──
const TIME_WORDS = /(یک|یه|نیم|\d+)?\s*(ساعت|دقیقه|روز|هفته|ربع)\s*(دیگه|دیگر|بعد)|پس ?فردا|فردا|امروز|امشب|آخر ?هفته|ساعت\s*\d{1,2}([:.]\d{2})?(\s*و\s*(نیم|ربع))?|\d{1,2}\s*(صبح|ظهر|عصر|شب)|(?<![ا-ی])(صبح|ظهر|عصر|شب)(?![ا-ی])|(سه|چهار|پنج|یک|دو)?\s?شنبه|جمعه/g;

export function byRules(text: string, now: Date, offsetMin: number): Draft[] {
  const s = normalizeFa(text);
  const parts = s.split(/\n|[.؛;!؟?]|،(?=\s*(?:و\s)?(?:قبلش|بعدش|بعد|یادم|فردا|ساعت|[^،]{0,20}(?:بخرم|بخر|کنم|بزنم|بدم|برم)))/).map(p => p.trim()).filter(Boolean);
  const out: Draft[] = [];
  let lastWhen: ReturnType<typeof parseWhen> = null;
  for (const part of parts) {
    let when = parseWhen(part, now, offsetMin);
    if (!when && /قبلش|بعدش/.test(part)) when = lastWhen;
    if (when) lastWhen = when;
    const isShopping = /بخرم|بخر(?![ا-ی])|بخریم|خرید|بگیرم(?=\s*$)/.test(part);
    let title = part
      .replace(TIME_WORDS, ' ')
      .replace(/یادم ?(بنداز|بیار|باشه)|یادآوری کن|لطفا|لطفاً|قبلش|بعدش|هم(?=\s*بخرم)|(?<![ا-ی])رو(?![ا-ی])|(?<![ا-ی])را(?![ا-ی])/g, ' ')
      .replace(/\s+/g, ' ').replace(/^[\s،,:-]+|[\s،,:-]+$/g, '').trim();
    if (isShopping) {
      const things = title.replace(/(بخرم|بخریم|بخر|خرید|بگیرم)$/, '').split(/\s+و\s+|،|,/).map(t => t.trim()).filter(Boolean);
      for (const t of things) out.push(draft('shopping', t, when));
      continue;
    }
    if (!title) continue;
    const type: ItemType =
      /^ایده|ایده[:：]/.test(part) ? 'idea'
        : /جلسه|(?<![ا-ی])قرار(?![ا-ی])|مهمونی|مهمانی|دکتر|کلاس|(?<![ا-ی])وقت (?=دکتر|دندون|آرایشگاه)/.test(part) ? 'event'
          : /یادم|یادآوری/.test(part) ? 'reminder'
            : /^یادداشت|^نکته|^فکر/.test(part) ? 'note'
              : 'task';
    title = title.replace(/^(ایده|یادداشت|نکته)[:：]?\s*/, '');
    out.push(draft(type, title, when));
  }
  return out.length ? out : [draft('note', s.slice(0, 200), null)];
}

const draft = (type: ItemType, title: string, when: ReturnType<typeof parseWhen>): Draft =>
  ({ type, title: title.slice(0, 200), notes: null, dueAt: when?.at ?? null, allDay: when?.allDay ?? false, people: [], place: null });
