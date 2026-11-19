import 'package:flutter_test/flutter_test.dart';
import 'package:loomi/api/loomi_api.dart';
import 'package:loomi/fa/dates.dart';

void main() {
  test('jalali conversion matches the server', () {
    expect(toJalali(DateTime(2026, 11, 18)), (jy: 1405, jm: 8, jd: 27));
    expect(toJalali(DateTime(2026, 3, 21)), (jy: 1405, jm: 1, jd: 1));
    expect(toJalali(DateTime(2024, 3, 20)), (jy: 1403, jm: 1, jd: 1));
  });

  test('friendly time labels', () {
    final now = DateTime(2026, 11, 18, 10, 30); // Wednesday
    expect(whenLabel(DateTime(2026, 11, 18, 17), allDay: false, now: now), 'امروز ۱۷:۰۰');
    expect(whenLabel(DateTime(2026, 11, 19, 10), allDay: false, now: now), 'فردا ۱۰:۰۰');
    expect(whenLabel(DateTime(2026, 11, 20, 9), allDay: true, now: now), 'پس‌فردا');
    expect(whenLabel(DateTime(2026, 11, 22, 8, 5), allDay: false, now: now), 'یکشنبه ۰۸:۰۵');
    expect(whenLabel(DateTime(2026, 12, 16, 9), allDay: true, now: now), '۲۵ آذر');
    expect(whenLabel(DateTime(2027, 4, 1, 9), allDay: true, now: now), '۱۲ فروردین ۱۴۰۶');
    expect(longDate(now), 'چهارشنبه ۲۷ آبان');
  });

  test('items round-trip through the local cache format', () {
    final i = Item.fromJson({
      'id': 'a1', 'type': 'shopping', 'title': 'نان', 'notes': null, 'dueAt': '2026-11-19T06:30:00.000Z', 'allDay': false,
      'people': ['علی'], 'place': null, 'done': false, 'createdAt': '2026-11-18T07:00:00.000Z',
    });
    final back = Item.fromJson(i.toJson());
    expect(back.type, ItemType.shopping);
    expect(back.title, 'نان');
    expect(back.dueAt!.toUtc(), DateTime.utc(2026, 11, 19, 6, 30));
    expect(back.people, ['علی']);
    expect(Item.fromJson({...i.toJson(), 'type': 'unknown'}).type, ItemType.note);
  });
}
