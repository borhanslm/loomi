// Understands everyday Persian time phrases without any AI, so reminders still land at the
// right moment when the brain is unavailable:
//   «یه ساعت دیگه»، «نیم ساعت بعد»، «فردا ساعت ۵ عصر»، «پس‌فردا صبح»، «امشب»، «پنجشنبه»،
//   «شنبه‌ی بعد ساعت ۱۰ و نیم»، «۲۵ آذر»، «آخر هفته»، «ساعت ۸:۳۰»
// All math happens in the user's local wall-clock time (given as a UTC offset in minutes).
import { toGregorian, toJalali, JALALI_MONTHS, WEEKDAYS } from './jalali.js';

/** Persian/Arabic digits → Latin, Arabic letters → Persian, unify spaces and half-spaces. */
export function normalizeFa(s: string): string {
  return s
    .replace(/[۰-۹]/g, d => String('۰۱۲۳۴۵۶۷۸۹'.indexOf(d)))
    .replace(/[٠-٩]/g, d => String('٠١٢٣٤٥٦٧٨٩'.indexOf(d)))
    .replace(/ي/g, 'ی').replace(/ك/g, 'ک').replace(/ة/g, 'ه')
    .replace(/[‌‏‎]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

const NUM_WORDS: Record<string, number> = {
  'یک': 1, 'یه': 1, 'دو': 2, 'سه': 3, 'چهار': 4, 'پنج': 5, 'شش': 6, 'شیش': 6, 'هفت': 7, 'هشت': 8, 'نه': 9, 'ده': 10,
  'یازده': 11, 'دوازده': 12, 'سیزده': 13, 'چهارده': 14, 'پانزده': 15, 'پونزده': 15, 'بیست': 20, 'سی': 30, 'چهل': 40,
};
const NUM = `(\\d{1,3}|${Object.keys(NUM_WORDS).sort((a, b) => b.length - a.length).join('|')})`;
const toNum = (s: string) => (/^\d+$/.test(s) ? Number(s) : NUM_WORDS[s] ?? NaN);

// Persian weekday names → JS day (0 = Sunday)
const WEEKDAY_RE: [RegExp, number][] = [
  [/سه ?شنبه/, 2], [/چهار ?شنبه/, 3], [/پنج ?شنبه/, 4], [/یک ?شنبه/, 0], [/دو ?شنبه/, 1], [/جمعه/, 5], [/(?<![ا-ی])شنبه/, 6],
];

export interface When {
  /** The moment (UTC). */
  at: Date;
  /** True when only a day was given (no clock time). */
  allDay: boolean;
}

interface Local { y: number; m: number; d: number; h: number; min: number }

const MINUTE = 60_000;
function toLocal(utc: Date, offsetMin: number): Local {
  const t = new Date(utc.getTime() + offsetMin * MINUTE);
  return { y: t.getUTCFullYear(), m: t.getUTCMonth() + 1, d: t.getUTCDate(), h: t.getUTCHours(), min: t.getUTCMinutes() };
}
function fromLocal(l: Local, offsetMin: number): Date {
  return new Date(Date.UTC(l.y, l.m - 1, l.d, l.h, l.min) - offsetMin * MINUTE);
}
function addDays(l: Local, n: number): Local {
  const t = new Date(Date.UTC(l.y, l.m - 1, l.d + n, l.h, l.min));
  return { y: t.getUTCFullYear(), m: t.getUTCMonth() + 1, d: t.getUTCDate(), h: l.h, min: l.min };
}
const weekday = (l: Local) => new Date(Date.UTC(l.y, l.m - 1, l.d)).getUTCDay();

/**
 * Find a time in a Persian phrase. Returns null when none is mentioned.
 * @param now        the current moment
 * @param offsetMin  the user's UTC offset in minutes (Tehran = 210)
 */
export function parseWhen(input: string, now: Date, offsetMin = 210): When | null {
  const s = normalizeFa(input);
  const nowL = toLocal(now, offsetMin);

  // 1) relative: «۲ ساعت دیگه»، «نیم ساعت بعد»، «یه ربع دیگه»، «۱۰ دقیقه دیگر»، «۳ روز بعد»
  const rel = s.match(new RegExp(`(?:${NUM}|نیم|یه ربع|یک ربع|ربع)\\s*(دقیقه|ساعت|روز|هفته|ماه)?\\s*(?:دیگه|دیگر|بعد)(?![ا-ی])`));
  if (rel) {
    const whole = rel[0];
    let n: number, unit = rel[2] ?? '';
    if (/^نیم/.test(whole)) { n = 30; unit = 'دقیقه'; if (/ساعت/.test(whole)) n = 30; }
    else if (/ربع/.test(whole)) { n = 15; unit = 'دقیقه'; }
    else n = toNum(rel[1]);
    if (!unit) unit = 'دقیقه';
    if (!Number.isNaN(n)) {
      const mins = unit === 'دقیقه' ? n : unit === 'ساعت' ? n * 60 : unit === 'روز' ? n * 1440 : unit === 'هفته' ? n * 10080 : n * 43200;
      return { at: new Date(now.getTime() + mins * MINUTE), allDay: false };
    }
  }

  // 2) which day
  let day: Local | null = null;
  if (/پس ?فردا/.test(s)) day = addDays(nowL, 2);
  else if (/فردا/.test(s)) day = addDays(nowL, 1);
  else if (/امروز|امشب|امروزی/.test(s)) day = { ...nowL };
  else if (/آخر ?هفته/.test(s)) {
    let n = (5 - weekday(nowL) + 7) % 7; if (n === 0) n = 7; // next Friday
    day = addDays(nowL, n);
  } else {
    for (const [re, wd] of WEEKDAY_RE) {
      if (!re.test(s)) continue;
      let n = (wd - weekday(nowL) + 7) % 7;
      if (n === 0 || /بعد|آینده|دیگه/.test(s.slice(s.search(re)))) n = n === 0 ? 7 : n + (/(هفته ی?|ی) ?بعد|آینده/.test(s) ? 7 : 0);
      day = addDays(nowL, n);
      break;
    }
  }
  // Jalali date: «۲۵ آذر» / «۲۵ آذر ۱۴۰۵»
  if (!day) {
    const jm = s.match(new RegExp(`(\\d{1,2})\\s*(?:ام|م)?\\s*(${JALALI_MONTHS.join('|')})(?:\\s*(?:ماه)?\\s*(\\d{4}))?`));
    if (jm) {
      const today = toJalali(nowL.y, nowL.m, nowL.d);
      const month = JALALI_MONTHS.indexOf(jm[2]) + 1, dd = Number(jm[1]);
      let jy = jm[3] ? Number(jm[3]) : today.jy;
      if (!jm[3] && (month < today.jm || (month === today.jm && dd < today.jd))) jy += 1;
      const g = toGregorian(jy, month, dd);
      day = { y: g.gy, m: g.gm, d: g.gd, h: 0, min: 0 };
    }
  }

  // 3) clock time: «ساعت ۵»، «ساعت ۸:۳۰»، «۱۰ و نیم صبح»، «ساعت ۷ و ربع»
  let h: number | null = null, min = 0;
  const clock = s.match(new RegExp(`(?:ساعت\\s*${NUM}(?:[:.](\\d{2}))?|${NUM}(?:[:.](\\d{2}))?\\s*(?=(?:و (?:نیم|ربع))?\\s*(?:صبح|ظهر|بعد ?از ?ظهر|عصر|شب)))(\\s*و نیم|\\s*و ربع|\\s*و (\\d{1,2}) دقیقه)?`));
  if (clock) {
    h = toNum(clock[1] ?? clock[3]);
    min = Number(clock[2] ?? clock[4] ?? 0);
    if (clock[5]?.includes('نیم')) min = 30;
    else if (clock[5]?.includes('ربع')) min = 15;
    else if (clock[6]) min = Number(clock[6]);
    if (Number.isNaN(h) || h > 24 || min > 59) h = null;
  }
  const period = s.match(/بعد ?از ?ظهر|صبح|ظهر|عصر|شب|امشب/)?.[0]?.replace(/\s/g, '') ?? null;
  if (h != null) {
    if (period && /عصر|شب|بعدازظهر|امشب/.test(period) && h < 12) h += 12;
    else if (period === 'ظهر' && h < 11) h += 12;
    else if (!period && h >= 1 && h <= 6) h += 12; // «ساعت ۵» on its own almost always means 17:00
    if (h === 24) h = 0;
  } else if (period) {
    h = { صبح: 9, ظهر: 12, بعدازظهر: 15, عصر: 17, شب: 21, امشب: 21 }[period] ?? null;
  }

  if (!day && h == null) return null;
  if (!day) {
    // time only → today, or tomorrow if that time has already passed
    let at = fromLocal({ ...nowL, h: h!, min }, offsetMin);
    if (at.getTime() <= now.getTime()) at = fromLocal(addDays({ ...nowL, h: h!, min }, 1), offsetMin);
    return { at, allDay: false };
  }
  if (h == null) return { at: fromLocal({ ...day, h: 9, min: 0 }, offsetMin), allDay: true };
  return { at: fromLocal({ ...day, h, min }, offsetMin), allDay: false };
}

/** «چهارشنبه ۲۷ آبان ۱۴۰۵، ساعت ۱۰:۳۰» — given to the brain so it knows "now". */
export function describeNow(now: Date, offsetMin = 210): string {
  const l = toLocal(now, offsetMin);
  const j = toJalali(l.y, l.m, l.d);
  const hh = String(l.h).padStart(2, '0'), mm = String(l.min).padStart(2, '0');
  return `${WEEKDAYS[weekday(l)]} ${j.jd} ${JALALI_MONTHS[j.jm - 1]} ${j.jy} (میلادی ${l.y}-${String(l.m).padStart(2, '0')}-${String(l.d).padStart(2, '0')})، ساعت ${hh}:${mm}`;
}

/** Start and end (UTC) of the user's local day containing `now`. */
export function localDayRange(now: Date, offsetMin = 210): { start: Date; end: Date } {
  const l = toLocal(now, offsetMin);
  const start = fromLocal({ ...l, h: 0, min: 0 }, offsetMin);
  return { start, end: new Date(start.getTime() + 86_400_000) };
}
