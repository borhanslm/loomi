// Persian dates for the UI: Jalali calendar (same algorithm as the server's fa/jalali.ts)
// and friendly labels like «امروز ۱۷:۰۰»، «فردا ۱۰:۳۰»، «پنجشنبه»، «۲۵ آذر».
const _breaks = [-61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210, 1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178];
int _div(int a, int b) => a ~/ b;
int _mod(int a, int b) => a - (a ~/ b) * b;

({int leap, int gy, int march}) _jalCal(int jy) {
  final gy = jy + 621;
  var leapJ = -14, jp = _breaks[0], jump = 0;
  for (var i = 1; i < _breaks.length; i++) {
    final jm = _breaks[i];
    jump = jm - jp;
    if (jy < jm) break;
    leapJ += _div(jump, 33) * 8 + _div(_mod(jump, 33), 4);
    jp = jm;
  }
  var n = jy - jp;
  leapJ += _div(n, 33) * 8 + _div(_mod(n, 33) + 3, 4);
  if (_mod(jump, 33) == 4 && jump - n == 4) leapJ += 1;
  final leapG = _div(gy, 4) - _div((_div(gy, 100) + 1) * 3, 4) - 150;
  final march = 20 + leapJ - leapG;
  if (jump - n < 6) n = n - jump + _div(jump + 4, 33) * 33;
  var leap = _mod(_mod(n + 1, 33) - 1, 4);
  if (leap == -1) leap = 4;
  return (leap: leap, gy: gy, march: march);
}

int _g2d(int gy, int gm, int gd) {
  var d = _div((gy + _div(gm - 8, 6) + 100100) * 1461, 4) + _div(153 * _mod(gm + 9, 12) + 2, 5) + gd - 34840408;
  return d - _div(_div(gy + 100100 + _div(gm - 8, 6), 100) * 3, 4) + 752;
}

({int gy, int gm, int gd}) _d2g(int jdn) {
  var j = 4 * jdn + 139361631;
  j = j + _div(_div(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908;
  final i = _div(_mod(j, 1461), 4) * 5 + 308;
  final gd = _div(_mod(i, 153), 5) + 1;
  final gm = _mod(_div(i, 153), 12) + 1;
  final gy = _div(j, 1461) - 100100 + _div(8 - gm, 6);
  return (gy: gy, gm: gm, gd: gd);
}

({int jy, int jm, int jd}) toJalali(DateTime d) {
  final jdn = _g2d(d.year, d.month, d.day);
  final gy = _d2g(jdn).gy;
  var jy = gy - 621;
  final r = _jalCal(jy);
  final jdn1f = _g2d(gy, 3, r.march);
  var k = jdn - jdn1f;
  if (k >= 0) {
    if (k <= 185) return (jy: jy, jm: 1 + _div(k, 31), jd: _mod(k, 31) + 1);
    k -= 186;
  } else {
    jy -= 1;
    k += 179;
    if (r.leap == 1) k += 1;
  }
  return (jy: jy, jm: 7 + _div(k, 30), jd: _mod(k, 30) + 1);
}

const jalaliMonths = ['فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور', 'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند'];
// DateTime.weekday: Monday = 1 … Sunday = 7
const weekdays = {1: 'دوشنبه', 2: 'سه‌شنبه', 3: 'چهارشنبه', 4: 'پنجشنبه', 5: 'جمعه', 6: 'شنبه', 7: 'یکشنبه'};

String faDigits(Object v) => v.toString().replaceAllMapped(RegExp(r'\d'), (m) => '۰۱۲۳۴۵۶۷۸۹'[int.parse(m[0]!)]);

String _hm(DateTime t) => faDigits('${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');

/// «چهارشنبه ۲۷ آبان»
String longDate(DateTime d) {
  final j = toJalali(d);
  return '${weekdays[d.weekday]} ${faDigits(j.jd)} ${jalaliMonths[j.jm - 1]}';
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Friendly label for an item's time, relative to [now] (both local).
String whenLabel(DateTime at, {required bool allDay, DateTime? now}) {
  final n = now ?? DateTime.now();
  final days = _day(at).difference(_day(n)).inDays;
  final time = allDay ? '' : ' ${_hm(at)}';
  if (days == 0) return 'امروز$time';
  if (days == 1) return 'فردا$time';
  if (days == 2) return 'پس‌فردا$time';
  if (days == -1) return 'دیروز$time';
  if (days > 2 && days < 7) return '${weekdays[at.weekday]}$time';
  final j = toJalali(at);
  final year = toJalali(n).jy == j.jy ? '' : ' ${faDigits(j.jy)}';
  return '${faDigits(j.jd)} ${jalaliMonths[j.jm - 1]}$year$time';
}

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
