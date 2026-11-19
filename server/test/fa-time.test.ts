import { describe, expect, it } from 'vitest';
import { describeNow, normalizeFa, parseWhen } from '../src/fa/time.js';
import { toGregorian, toJalali } from '../src/fa/jalali.js';

// Wednesday 18 Nov 2026, 10:30 in Tehran (UTC+3:30) = 27 Aban 1405
const NOW = new Date('2026-11-18T07:00:00Z');
const TEH = 210;
const local = (s: string) => {
  const w = parseWhen(s, NOW, TEH);
  if (!w) return null;
  const t = new Date(w.at.getTime() + TEH * 60_000);
  return `${t.toISOString().slice(0, 16).replace('T', ' ')}${w.allDay ? ' (all day)' : ''}`;
};

describe('jalali', () => {
  it('converts both ways', () => {
    expect(toJalali(2026, 11, 18)).toEqual({ jy: 1405, jm: 8, jd: 27 });
    expect(toGregorian(1405, 1, 1)).toEqual({ gy: 2026, gm: 3, gd: 21 });
    expect(toJalali(2024, 3, 20)).toEqual({ jy: 1403, jm: 1, jd: 1 });
  });
  it('describes now in Persian', () => {
    expect(describeNow(NOW, TEH)).toContain('چهارشنبه 27 آبان 1405');
    expect(describeNow(NOW, TEH)).toContain('10:30');
  });
});

describe('persian time phrases', () => {
  it('normalizes digits and letters', () => {
    expect(normalizeFa('ساعت ۵ و نيم')).toBe('ساعت 5 و نیم');
  });

  it.each([
    ['یک ساعت دیگه یادم بنداز نون بخرم', '2026-11-18 11:30'],
    ['یه ساعت دیگه', '2026-11-18 11:30'],
    ['نیم ساعت بعد', '2026-11-18 11:00'],
    ['یه ربع دیگه', '2026-11-18 10:45'],
    ['۱۰ دقیقه دیگر', '2026-11-18 10:40'],
    ['۳ روز بعد', '2026-11-21 10:30'],
    ['فردا ساعت ۵ عصر', '2026-11-19 17:00'],
    ['فردا ساعت ۸ صبح جلسه', '2026-11-19 08:00'],
    ['پس‌فردا صبح', '2026-11-20 09:00'],
    ['پس فردا ساعت ۱۰ و نیم', '2026-11-20 10:30'],
    ['امشب', '2026-11-18 21:00'],
    ['ساعت ۵', '2026-11-18 17:00'],
    ['ساعت ۸:۳۰', '2026-11-19 08:30'], // already past today → tomorrow
    ['ساعت ۱۱ و ربع', '2026-11-18 11:15'],
    ['۱۰ و نیم شب', '2026-11-18 22:30'],
    ['فردا', '2026-11-19 09:00 (all day)'],
    ['پنجشنبه', '2026-11-19 09:00 (all day)'],
    ['جمعه ساعت ۱۰', '2026-11-20 10:00'],
    ['شنبه', '2026-11-21 09:00 (all day)'],
    ['سه‌شنبه', '2026-11-24 09:00 (all day)'],
    ['چهارشنبه', '2026-11-25 09:00 (all day)'], // today's weekday → next week
    ['آخر هفته', '2026-11-20 09:00 (all day)'],
    ['۲۵ آذر', '2026-12-16 09:00 (all day)'],
    ['۱ فروردین', '2027-03-21 09:00 (all day)'],
    ['۱۰ آبان', '2027-11-01 09:00 (all day)'], // already passed this year → next year
  ])('%s', (phrase, want) => {
    expect(local(phrase)).toBe(want);
  });

  it('returns null when no time is mentioned', () => {
    expect(parseWhen('شیر و نون بخرم', NOW, TEH)).toBeNull();
    expect(parseWhen('ایده: یه کافه کتاب', NOW, TEH)).toBeNull();
  });
});
