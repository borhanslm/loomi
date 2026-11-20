import 'package:flutter_test/flutter_test.dart';
import 'package:loomi/api/loomi_api.dart';
import 'package:loomi/fa/dates.dart';
import 'package:loomi/local/notice_plan.dart';
import 'package:loomi/local/reminders.dart';
import 'package:loomi/ui/items_ui.dart';

// Wednesday 18 Nov 2026 (27 Aban 1405), 10:30 local
final now = DateTime(2026, 11, 18, 10, 30);

Item item(String id, {ItemType type = ItemType.task, DateTime? due, DateTime? remind, bool done = false, bool allDay = false}) => Item(
      id: id, type: type, title: 'مورد $id', dueAt: due, allDay: allDay, done: done, createdAt: now,
      remindAt: done ? null : remind ?? due,
    );

void main() {
  group('planNotices', () {
    test('one reminder per open, future item; labels relative to when it fires', () {
      final plan = planNotices([
        item('a', due: DateTime(2026, 11, 19, 10)),
        item('past', due: DateTime(2026, 11, 18, 9)),
        item('done', due: DateTime(2026, 11, 19, 11), done: true),
        item('far', due: DateTime(2027, 1, 1)),
        item('none'),
      ], now, digest: const DigestTimes(enabled: false));
      expect(plan.map((n) => n.itemId), ['a']);
      expect(plan.single.at, DateTime(2026, 11, 19, 10));
      expect(plan.single.body, 'کار · امروز ۱۰:۰۰');
      expect(plan.single.id, noticeIdFor('a'));
    });

    test('a snoozed reminder fires at the snooze time', () {
      final n = planNotices([item('s', due: DateTime(2026, 11, 18, 10), remind: DateTime(2026, 11, 18, 11))], now,
              digest: const DigestTimes(enabled: false))
          .single;
      expect(n.at, DateTime(2026, 11, 18, 11));
      expect(n.body, contains('یادآوری دوباره'));
    });

    test('keeps only the soonest reminders', () {
      final many = [for (var i = 0; i < 60; i++) item('$i', due: now.add(Duration(hours: i + 1)))];
      final plan = planNotices(many, now, digest: const DigestTimes(enabled: false));
      expect(plan.length, 40);
      expect(plan.first.itemId, '0');
    });

    test('morning summary and evening review', () {
      final items = [
        item('m', type: ItemType.event, due: DateTime(2026, 11, 19, 10)),
        item('t', due: DateTime(2026, 11, 18, 18)),
        item('shop', type: ItemType.shopping),
      ];
      final plan = planNotices(items, now);
      final mornings = plan.where((n) => n.kind == NoticeKind.morning).toList();
      final evenings = plan.where((n) => n.kind == NoticeKind.evening).toList();
      // today's morning has passed; tomorrow has the meeting
      expect(mornings.map((n) => n.at), [DateTime(2026, 11, 19, 8)]);
      expect(mornings.single.title, 'صبح بخیر! امروز ۱ مورد داری');
      expect(mornings.single.body, 'مورد m — و ۱ قلم خرید');
      // the task stays open every evening until it's done
      expect(evenings.first.at, DateTime(2026, 11, 18, 21));
      expect(evenings.first.body, startsWith('مورد t'));
      expect(evenings.length, 7);
      expect(plan.map((n) => n.id).toSet().length, plan.length); // ids never clash
    });

    test('digest can be turned off', () {
      expect(planNotices([item('t', due: DateTime(2026, 11, 18, 18))], now, digest: const DigestTimes(enabled: false)).length, 1);
    });
  });

  test('notification responses from Android and Windows', () {
    expect(parseResponse('done', 'item1'), (action: 'done', itemId: 'item1'));
    expect(parseResponse(null, 'item1'), (action: 'open', itemId: 'item1'));
    expect(parseResponse('later|item2', 'later|item2'), (action: 'later', itemId: 'item2'));
    expect(parseResponse('open|', 'open|'), (action: 'open', itemId: null));
  });

  test('Jalali ↔ Gregorian', () {
    expect(toGregorian(1405, 8, 27), DateTime(2026, 11, 18));
    expect(toGregorian(1405, 1, 1), DateTime(2026, 3, 21));
    for (var d = DateTime(2025, 1, 1); d.isBefore(DateTime(2027, 1, 1)); d = d.add(const Duration(days: 13))) {
      final j = toJalali(d);
      expect(toGregorian(j.jy, j.jm, j.jd), DateTime(d.year, d.month, d.day));
    }
    expect(jalaliMonthLength(1405, 1), 31);
    expect(jalaliMonthLength(1405, 7), 30);
    expect(jalaliMonthLength(1403, 12), 30); // 1403 is a leap year
    expect(jalaliMonthLength(1404, 12), 29);
  });

  test('questions are asked, not saved', () {
    expect(looksLikeQuestion('فردا چی کار دارم؟'), isTrue);
    expect(looksLikeQuestion('what now? '), isTrue);
    expect(looksLikeQuestion('فردا نون بخرم'), isFalse);
  });
}
