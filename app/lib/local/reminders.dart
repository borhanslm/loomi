// Reminders on this device.
//  • Android: every notice is scheduled with the OS, so it arrives even when Loomi is closed
//    (and after a reboot). «انجام شد» / «۳۰ دقیقه بعد» work from the notification itself.
//  • Windows: notices are shown while the app runs — from the local plan and from the server's
//    live «reminder» events — never twice.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../api/loomi_api.dart';
import 'notice_plan.dart';
import 'session.dart';

const snoozeMinutes = 30;
const _kActions = 'loomi.actions.v1', _kDigest = 'loomi.digest.v1';

/// What the user did with a notification: 'done', 'later' or 'open'.
typedef NoticeAction = ({String action, String? itemId});

NoticeAction parseResponse(String? actionId, String? payload) {
  // Windows sends one string: «action|itemId»; Android sends the action id and the item id apart.
  if (payload != null && payload.contains('|')) {
    final i = payload.indexOf('|');
    return (action: payload.substring(0, i), itemId: payload.substring(i + 1).isEmpty ? null : payload.substring(i + 1));
  }
  return (action: (actionId == null || actionId.isEmpty) ? 'open' : actionId, itemId: payload);
}

/// Send a notification action to the server.
Future<void> applyAction(LoomiApi api, String itemId, String action) async {
  if (action == 'done') await api.updateItem(itemId, {'done': true});
  if (action == 'later') await api.snooze(itemId, snoozeMinutes);
}

// ── actions taken while offline: kept and sent on the next refresh ──
Future<void> queueAction(String itemId, String action) async {
  final p = await SharedPreferences.getInstance();
  await p.reload();
  final list = (jsonDecode(p.getString(_kActions) ?? '[]') as List).cast<Map<String, dynamic>>()
    ..add({'id': itemId, 'a': action});
  await p.setString(_kActions, jsonEncode(list));
}

Future<List<({String itemId, String action})>> takeQueuedActions() async {
  final p = await SharedPreferences.getInstance();
  await p.reload(); // a background isolate may have written
  final raw = p.getString(_kActions);
  if (raw == null) return const [];
  await p.remove(_kActions);
  return (jsonDecode(raw) as List).cast<Map<String, dynamic>>().map((m) => (itemId: m['id'] as String, action: m['a'] as String)).toList();
}

Future<DigestTimes> loadDigest() async {
  final p = await SharedPreferences.getInstance();
  final j = jsonDecode(p.getString(_kDigest) ?? '{}') as Map<String, dynamic>;
  return DigestTimes(enabled: j['on'] as bool? ?? true, morningHour: j['m'] as int? ?? 8, eveningHour: j['e'] as int? ?? 21);
}

Future<void> saveDigest(DigestTimes d) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(_kDigest, jsonEncode({'on': d.enabled, 'm': d.morningHour, 'e': d.eveningHour}));
}

/// A notification button was pressed while Loomi was not in front (Android). Runs in its own isolate.
@pragma('vm:entry-point')
Future<void> onBackgroundNotice(NotificationResponse r) async {
  DartPluginRegistrant.ensureInitialized();
  final a = parseResponse(r.actionId, r.payload);
  final id = a.itemId;
  if (id == null || a.action == 'open') return;
  try {
    final s = await SecureSessionStore().read();
    if (s == null) return;
    await applyAction(s.api, id, a.action);
  } catch (_) {
    await queueAction(id, a.action); // offline: the app sends it later
    if (a.action == 'later') {
      // still remind again in 30 minutes, even without the server
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(settings: Reminders.settings);
      await plugin.zonedSchedule(
        id: noticeIdFor(id), title: 'یادآوری دوباره', body: 'یادآوری‌ای که به بعد موکول کردی',
        scheduledDate: tz.TZDateTime.from(DateTime.now().add(const Duration(minutes: snoozeMinutes)), tz.UTC),
        notificationDetails: Reminders.detailsFor(NoticeKind.reminder, id), androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: id,
      );
    }
  }
}

class Reminders {
  Reminders._();
  static final instance = Reminders._();

  static const settings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    windows: WindowsInitializationSettings(appName: 'Loomi', appUserModelId: 'Loomi.App', guid: 'e8a55469-9659-4a0f-ba6d-65f6f514d6bc'),
  );

  final _plugin = FlutterLocalNotificationsPlugin();
  final _responses = StreamController<NoticeAction>.broadcast();
  bool _ready = false, _exact = false;
  NoticeAction? _launch;
  List<Notice> _plan = const [];
  final _shown = <String>{};
  Timer? _tick;

  /// Notification taps and buttons (while the app runs).
  Stream<NoticeAction> get responses => _responses.stream;

  /// The notification that opened the app, if any (read once).
  NoticeAction? takeLaunch() {
    final l = _launch;
    _launch = null;
    return l;
  }

  static bool get supported {
    if (kIsWeb) return false;
    try {
      return (Platform.isAndroid || Platform.isWindows) && !Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }

  bool get _android => Platform.isAndroid;

  Future<void> init() async {
    if (_ready || !supported) return;
    try {
      tzdata.initializeTimeZones();
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (r) => _responses.add(parseResponse(r.actionId, r.payload)),
        onDidReceiveBackgroundNotificationResponse: onBackgroundNotice,
      );
      _ready = true;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final r = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && r != null) _launch = parseResponse(r.actionId, r.payload);
      if (!_android) _tick = Timer.periodic(const Duration(seconds: 20), (_) => _fireDue());
    } catch (_) {
      _ready = false; // notifications are a bonus; never block the app
    }
  }

  /// Android 13+ asks the user once; also checks whether exact timing is allowed.
  Future<void> askPermission() async {
    if (!_ready || !_android) return;
    final a = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      await a?.requestNotificationsPermission();
      _exact = await a?.canScheduleExactNotifications() ?? false;
    } catch (_) {}
  }

  static NotificationDetails detailsFor(NoticeKind kind, String? itemId) {
    final reminder = kind == NoticeKind.reminder;
    return NotificationDetails(
      android: reminder
          ? const AndroidNotificationDetails('reminders', 'یادآورها',
              channelDescription: 'یادآوری کارها، قرارها و خریدها سر وقت',
              importance: Importance.high, priority: Priority.high, category: AndroidNotificationCategory.reminder,
              actions: [AndroidNotificationAction('done', 'انجام شد'), AndroidNotificationAction('later', '۳۰ دقیقه بعد')])
          : const AndroidNotificationDetails('digest', 'خلاصه‌ی روز',
              channelDescription: 'خلاصه‌ی صبح و مرور شب', importance: Importance.defaultImportance),
      windows: WindowsNotificationDetails(actions: [
        if (reminder && itemId != null) ...[
          WindowsAction(content: 'انجام شد', arguments: 'done|$itemId'),
          WindowsAction(content: '۳۰ دقیقه بعد', arguments: 'later|$itemId'),
        ],
      ]),
    );
  }

  /// Re-plan everything from the current items. Cheap; call after every change.
  Future<void> sync(List<Item> items) async {
    if (!_ready) return;
    // Windows keeps the last 10 minutes too, so a re-plan right at the due time doesn't drop one
    final from = _android ? DateTime.now() : DateTime.now().subtract(const Duration(minutes: 10));
    final plan = planNotices(items, from, digest: await loadDigest());
    _plan = plan;
    if (!_android) return; // Windows: the ticker shows them on time
    try {
      await _plugin.cancelAllPendingNotifications();
      for (final n in plan) {
        await _plugin.zonedSchedule(
          id: n.id, title: n.title, body: n.body,
          scheduledDate: tz.TZDateTime.from(n.at, tz.UTC),
          notificationDetails: detailsFor(n.kind, n.itemId),
          androidScheduleMode: _exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
          payload: n.itemId,
        );
      }
    } catch (_) {}
  }

  /// The server says an item is due now (live event).
  Future<void> fromServer(Item item) async {
    if (!_ready || _android) return; // Android already has it scheduled
    final at = item.remindAt ?? DateTime.now();
    final n = planNotices([item], at.subtract(const Duration(seconds: 1)), digest: const DigestTimes(enabled: false))
        .where((n) => n.kind == NoticeKind.reminder)
        .firstOrNull;
    if (n != null) await _show(n);
  }

  Future<void> _fireDue() async {
    final now = DateTime.now();
    for (final n in _plan) {
      if (!n.at.isAfter(now) && now.difference(n.at).inMinutes < 10) await _show(n);
    }
  }

  Future<void> _show(Notice n) async {
    final key = '${n.id}@${n.at.millisecondsSinceEpoch ~/ 60000}';
    if (!_shown.add(key)) return;
    try {
      await _plugin.show(
        id: n.id, title: n.title, body: n.body, notificationDetails: detailsFor(n.kind, n.itemId),
        payload: _android ? n.itemId : 'open|${n.itemId ?? ''}',
      );
    } catch (_) {}
  }

  /// «It works!» — so the user can check notifications are allowed.
  Future<void> showTest() async {
    if (!_ready) return;
    try {
      await _plugin.show(id: 999, title: 'لومی اینجاست ✨', body: 'یادآورها همین‌طوری سر وقت می‌رسند.',
          notificationDetails: detailsFor(NoticeKind.morning, null));
    } catch (_) {}
  }

  void dispose() => _tick?.cancel();
}
