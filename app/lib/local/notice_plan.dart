// What Loomi should announce, and when — pure, so it is easy to test.
// Each open item with a reminder time gets one notice; every morning a summary of the day,
// every evening a look at what is still left.
import '../api/loomi_api.dart';
import '../fa/dates.dart';

enum NoticeKind { reminder, morning, evening }

class Notice {
  const Notice({required this.id, required this.at, required this.title, required this.body, required this.kind, this.itemId});
  final int id;
  final DateTime at;
  final String title, body;
  final NoticeKind kind;
  final String? itemId;
  @override
  String toString() => 'Notice($kind $at $title)';
}

class DigestTimes {
  const DigestTimes({this.morningHour = 8, this.eveningHour = 21, this.enabled = true});
  final int morningHour, eveningHour;
  final bool enabled;
}

/// A stable notification id for an item (positive, below the digest range).
int noticeIdFor(String itemId) {
  var h = 0x811c9dc5;
  for (final c in itemId.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0x7fffffff;
  }
  return 1000 + h % 0x3fffffff;
}

/// Digest ids: 1..20 (morning = 1 + day, evening = 11 + day).
const _morningBase = 1, _eveningBase = 11;

const typeLabel = {
  ItemType.task: 'کار', ItemType.reminder: 'یادآور', ItemType.shopping: 'خرید',
  ItemType.idea: 'ایده', ItemType.note: 'یادداشت', ItemType.event: 'قرار',
};

String _list(Iterable<Item> items, {int max = 4}) {
  final l = items.toList();
  final names = l.take(max).map((i) => i.title).join('، ');
  return l.length > max ? '$names و ${faDigits('${l.length - max}')} مورد دیگر' : names;
}

/// Plan notices from [now] for the next [days] days. Platforms limit pending alarms,
/// so at most [maxReminders] item reminders (the soonest) are kept.
List<Notice> planNotices(List<Item> items, DateTime now, {DigestTimes digest = const DigestTimes(), int days = 7, int maxReminders = 40}) {
  final horizon = now.add(Duration(days: days));
  final open = items.where((i) => !i.done).toList();
  final out = <Notice>[];

  final timed = open.where((i) => i.remindAt != null && i.remindAt!.isAfter(now) && i.remindAt!.isBefore(horizon)).toList()
    ..sort((a, b) => a.remindAt!.compareTo(b.remindAt!));
  for (final i in timed.take(maxReminders)) {
    final due = i.dueAt;
    final snoozed = due != null && i.remindAt!.difference(due).inMinutes.abs() > 1;
    final when = due == null ? '' : whenLabel(due, allDay: i.allDay, now: i.remindAt);
    out.add(Notice(
      id: noticeIdFor(i.id), at: i.remindAt!, kind: NoticeKind.reminder, itemId: i.id,
      title: i.title,
      body: [typeLabel[i.type], if (when.isNotEmpty) when, if (snoozed) '(یادآوری دوباره)', ?i.place].join(' · '),
    ));
  }

  if (!digest.enabled) return out;
  final today = DateTime(now.year, now.month, now.day);
  for (var d = 0; d < days; d++) {
    final day = today.add(Duration(days: d));
    final next = day.add(const Duration(days: 1));
    bool onDay(Item i) => i.dueAt != null && !i.dueAt!.isBefore(day) && i.dueAt!.isBefore(next);

    final morning = DateTime(day.year, day.month, day.day, digest.morningHour);
    if (morning.isAfter(now)) {
      final list = open.where(onDay).toList()..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
      final shopping = open.where((i) => i.type == ItemType.shopping).length;
      if (list.isNotEmpty) {
        out.add(Notice(
          id: _morningBase + d, at: morning, kind: NoticeKind.morning,
          title: 'صبح بخیر! امروز ${faDigits('${list.length}')} مورد داری',
          body: _list(list) + (shopping > 0 ? ' — و ${faDigits('$shopping')} قلم خرید' : ''),
        ));
      }
    }

    final evening = DateTime(day.year, day.month, day.day, digest.eveningHour);
    if (evening.isAfter(now)) {
      // still open at night: things due today (or earlier) that need doing
      final left = open.where((i) =>
          i.dueAt != null && i.dueAt!.isBefore(next) && const {ItemType.task, ItemType.reminder}.contains(i.type)).toList();
      if (left.isNotEmpty) {
        out.add(Notice(
          id: _eveningBase + d, at: evening, kind: NoticeKind.evening,
          title: '${faDigits('${left.length}')} کار هنوز مانده',
          body: '${_list(left)} — برای فردا برنامه‌ریزی کن.',
        ));
      }
    }
  }
  return out;
}
