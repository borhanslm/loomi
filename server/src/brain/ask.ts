// Ask Loomi about your own life: «فردا چی کار دارم؟», «چی باید بخرم؟», «قرارم با علی کیه؟»
// Uses the AI brain over the user's items; without one (or if it fails) answers simple
// questions by rules: a day («فردا»), shopping, or a word search.
import type { Db } from '../db.js';
import { describeAt, describeNow, localDayRange, normalizeFa, parseWhen } from '../fa/time.js';
import { type Item, listItems } from '../items.js';
import { askBrain, type BrainDeps, extractJson, NoBrainError } from './llm.js';

export interface Answer { answer: string; via: 'ai' | 'rules'; model: string | null; items: Item[]; warning: string | null }

const TYPE_FA: Record<string, string> = { task: 'کار', reminder: 'یادآور', shopping: 'خرید', idea: 'ایده', note: 'یادداشت', event: 'قرار' };

const SYSTEM = `تو «لومی» هستی، ذهن دوم کاربر. کاربر درباره‌ی کارها، قرارها، خریدها و یادداشت‌های خودش سؤال می‌پرسد.
فقط بر اساس «فهرست موردها» جواب بده و چیزی از خودت نساز. اگر جواب در فهرست نیست، صادقانه بگو.
جواب کوتاه، گرم و فارسی باشد (حداکثر چند جمله یا یک فهرست کوتاه). زمان‌ها را نسبی و خودمانی بگو (امروز، فردا، پنجشنبه ساعت ۱۰).
فقط JSON برگردان: {"answer":"...","ids":["شناسه‌ی موردهای مرتبط"]}`;

/** One line per item for the brain: «[id] قرار | جلسه با علی | پنجشنبه ۲۸ آبان، ساعت ۱۰:۰۰ | با: علی». */
export function itemLine(it: Item, offsetMin: number): string {
  const parts = [`[${it.id}] ${TYPE_FA[it.type] ?? it.type}`, it.title];
  if (it.dueAt) parts.push(describeAt(new Date(it.dueAt), offsetMin, !it.allDay));
  if (it.people.length) parts.push(`با: ${it.people.join('، ')}`);
  if (it.place) parts.push(`در: ${it.place}`);
  if (it.notes) parts.push(`توضیح: ${it.notes.slice(0, 120)}`);
  if (it.done) parts.push('انجام شده');
  return parts.join(' | ');
}

export async function ask(db: Db, userId: number, question: string, now: Date, offsetMin: number, deps: BrainDeps | null): Promise<Answer> {
  const q = question.trim();
  const all = await listItems(db, userId, { status: 'all', limit: 600 });
  const weekAgo = now.getTime() - 7 * 86_400_000;
  const pool = all.filter(i => !i.done || (i.doneAt && Date.parse(i.doneAt) > weekAgo)).slice(0, 300);
  if (deps) {
    try {
      const list = pool.length ? pool.map(i => itemLine(i, offsetMin)).join('\n') : '(خالی)';
      const r = await askBrain(deps, [
        { role: 'system', content: SYSTEM },
        { role: 'user', content: `اکنون: ${describeNow(now, offsetMin)}\n\nفهرست موردها:\n${list}\n\nسؤال کاربر:\n${q}` },
      ], { json: true, maxTokens: 800 });
      const j = extractJson(r.text) as { answer?: unknown; ids?: unknown };
      if (typeof j.answer === 'string' && j.answer.trim()) {
        const ids = new Set(Array.isArray(j.ids) ? j.ids.map(String) : []);
        return { answer: j.answer.trim(), via: 'ai', model: r.model, items: pool.filter(i => ids.has(i.id)), warning: null };
      }
    } catch (e) {
      if (!(e instanceof NoBrainError)) return { ...byRules(q, pool, now, offsetMin), warning: 'هوش مصنوعی در دسترس نبود؛ جواب ساده داده شد.' };
    }
  }
  return { ...byRules(q, pool, now, offsetMin), warning: null };
}

const faDigits = (s: string) => s.replace(/[0-9]/g, d => '۰۱۲۳۴۵۶۷۸۹'[Number(d)]);

const STOP = new Set(['چی', 'چه', 'چیه', 'کی', 'کیه', 'کجا', 'کجاست', 'کدوم', 'کدام', 'آیا', 'دارم', 'داشتم', 'دارم؟', 'باید', 'بود', 'هست', 'است',
  'من', 'به', 'با', 'از', 'در', 'که', 'را', 'رو', 'و', 'یا', 'برای', 'واسه', 'کار', 'کارهای', 'کارای', 'چیزی', 'چند', 'تا', 'هم', 'این', 'اون', 'آن', 'لومی', 'بگو', 'یادم']);

export function byRules(q: string, pool: Item[], now: Date, offsetMin: number): Omit<Answer, 'warning'> {
  const s = normalizeFa(q).replace(/[؟?!.،,]/g, ' ');
  const open = pool.filter(i => !i.done);
  const done = (answer: string, items: Item[]) => ({ answer: faDigits(answer), via: 'rules' as const, model: null, items });

  if (/خرید|بخرم|بخریم|خریدنی/.test(s)) {
    const list = open.filter(i => i.type === 'shopping');
    return done(list.length ? `${list.length} قلم برای خرید داری: ${list.map(i => i.title).join('، ')}.` : 'فهرست خریدت خالی است.', list);
  }
  const when = parseWhen(s, now, offsetMin);
  if (when) {
    const { start, end } = localDayRange(when.at, offsetMin);
    const list = open.filter(i => i.dueAt && Date.parse(i.dueAt) >= start.getTime() && Date.parse(i.dueAt) < end.getTime());
    const day = describeAt(when.at, offsetMin, false);
    return done(list.length ? `${day} ${list.length} مورد داری:\n${list.map(i => `• ${i.title}${i.allDay || !i.dueAt ? '' : ` (${describeAt(new Date(i.dueAt), offsetMin).split('ساعت ')[1]})`}`).join('\n')}`
      : `${day} چیزی ثبت نکرده‌ای.`, list);
  }
  const words = s.split(/\s+/).filter(w => w.length > 1 && !STOP.has(w));
  const hits = words.length ? pool.filter(i => {
    const hay = normalizeFa([i.title, i.notes ?? '', i.place ?? '', ...i.people].join(' '));
    return words.some(w => hay.includes(w));
  }) : [];
  if (hits.length) return done(`${hits.length} مورد پیدا کردم:\n${hits.slice(0, 10).map(i => `• ${i.title}${i.dueAt ? ` — ${describeAt(new Date(i.dueAt), offsetMin, !i.allDay)}` : ''}`).join('\n')}`, hits.slice(0, 10));
  return done('چیزی درباره‌اش پیدا نکردم. برای جواب‌های دقیق‌تر، در پنل ادمین یک مدل «مغز» انتخاب کنید.', []);
}
