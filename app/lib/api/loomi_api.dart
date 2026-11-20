// Thin client for Loomi Server's HTTP + WebSocket API (see docs/openapi.json).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class LoomiApiError implements Exception {
  LoomiApiError(this.message, [this.status]);
  final String message;
  final int? status;
  bool get unauthorized => status == 401;
  @override
  String toString() => message;
}

class Device {
  Device({required this.id, required this.name, required this.platform, required this.lastSeen});
  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'] as String,
        name: j['name'] as String,
        platform: j['platform'] as String,
        lastSeen: DateTime.parse(j['lastSeen'] as String),
      );
  final String id, name, platform;
  final DateTime lastSeen;
}

enum ItemType { task, reminder, shopping, idea, note, event }

class Item {
  Item({
    required this.id, required this.type, required this.title, this.notes, this.dueAt, this.allDay = false,
    this.people = const [], this.place, this.done = false, required this.createdAt, this.remindAt,
  });
  factory Item.fromJson(Map<String, dynamic> j) => Item(
        id: j['id'] as String,
        type: ItemType.values.firstWhere((t) => t.name == j['type'], orElse: () => ItemType.note),
        title: j['title'] as String,
        notes: j['notes'] as String?,
        dueAt: j['dueAt'] == null ? null : DateTime.parse(j['dueAt'] as String).toLocal(),
        allDay: j['allDay'] as bool? ?? false,
        people: ((j['people'] as List?) ?? const []).map((e) => e.toString()).toList(),
        place: j['place'] as String?,
        done: j['done'] as bool? ?? false,
        createdAt: DateTime.parse(j['createdAt'] as String).toLocal(),
        remindAt: j['remindAt'] == null ? null : DateTime.parse(j['remindAt'] as String).toLocal(),
      );
  Map<String, dynamic> toJson() => {
        'id': id, 'type': type.name, 'title': title, 'notes': notes, 'dueAt': dueAt?.toUtc().toIso8601String(), 'allDay': allDay,
        'people': people, 'place': place, 'done': done, 'createdAt': createdAt.toUtc().toIso8601String(),
        'remindAt': remindAt?.toUtc().toIso8601String(),
      };
  final String id, title;
  final ItemType type;
  final String? notes, place;
  final DateTime? dueAt;
  final bool allDay, done;
  final List<String> people;
  final DateTime createdAt;

  /// When Loomi reminds: a snoozed time, else [dueAt]. Null when done.
  final DateTime? remindAt;
}

class CaptureResult {
  CaptureResult({required this.items, required this.via, this.warning});
  final List<Item> items;
  final String via;
  final String? warning;
}

class AskResult {
  AskResult({required this.answer, required this.via, required this.items, this.warning});
  final String answer, via;
  final String? warning;
  final List<Item> items;
}

/// What the server's pairing QR holds: `{"loomi":1,"url":…,"code":…}`.
class PairInvite {
  PairInvite(this.url, this.code);
  final String url, code;

  static PairInvite? parse(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is Map && j['loomi'] == 1 && j['url'] is String && j['code'] is String) {
        return PairInvite(normalizeServerUrl(j['url'] as String), (j['code'] as String).replaceAll(RegExp(r'\D'), ''));
      }
    } catch (_) {}
    return null;
  }
}

/// Accepts "loomi.example.com", "1.2.3.4:8787", "https://x/" … and returns a clean base URL.
String normalizeServerUrl(String input) {
  var s = input.trim().replaceAll(RegExp(r'/+$'), '');
  if (s.isEmpty) return s;
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(s)) {
    final local = RegExp(r'^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.)').hasMatch(s);
    s = '${local ? 'http' : 'https'}://$s';
  }
  return s;
}

class LoomiApi {
  LoomiApi(this.baseUrl, {this.token, http.Client? client}) : _http = client ?? http.Client();
  final String baseUrl;
  final String? token;
  final http.Client _http;

  Map<String, String> _headers(bool json) => {
        if (json) 'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final uri = Uri.parse('$baseUrl$path');
    late http.Response r;
    try {
      final req = http.Request(method, uri)..headers.addAll(_headers(body != null));
      if (body != null) req.body = jsonEncode(body);
      r = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 15)));
    } on TimeoutException {
      throw LoomiApiError('سرور لومی جواب نداد. آدرس و اینترنت را بررسی کنید.');
    } catch (_) {
      throw LoomiApiError('به سرور لومی وصل نشد. آدرس را بررسی کنید.');
    }
    final data = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 400) {
      final msg = data is Map && data['error'] is String ? data['error'] as String : 'خطای سرور (${r.statusCode})';
      throw LoomiApiError(msg, r.statusCode);
    }
    return data;
  }

  Future<Map<String, dynamic>> health() async => (await _send('GET', '/v1/health')) as Map<String, dynamic>;

  /// Returns the new device token.
  Future<String> pair({required String code, required String name, required String platform}) async {
    final j = await _send('POST', '/v1/pair', {'code': code, 'name': name, 'platform': platform}) as Map<String, dynamic>;
    return j['token'] as String;
  }

  Future<List<Device>> devices() async =>
      ((await _send('GET', '/v1/devices')) as List).map((e) => Device.fromJson(e as Map<String, dynamic>)).toList();

  Future<String> myDeviceId() async => ((await _send('GET', '/v1/me')) as Map)['device']['id'] as String;

  Future<void> revoke(String id) => _send('DELETE', '/v1/devices/$id');

  /// A fresh one-time code (and QR payload) to pair another device.
  Future<({String code, String qr, DateTime expiresAt})> invite() async {
    final j = await _send('POST', '/v1/pair/codes') as Map<String, dynamic>;
    return (code: j['code'] as String, qr: j['qr'] as String, expiresAt: DateTime.parse(j['expiresAt'] as String));
  }

  /// Say anything; Loomi turns it into items. [clientId] makes retries safe.
  Future<CaptureResult> capture(String text, {required String clientId}) async {
    final j = await _send('POST', '/v1/capture', {
      'text': text, 'clientId': clientId, 'tzOffset': DateTime.now().timeZoneOffset.inMinutes,
    }) as Map<String, dynamic>;
    return CaptureResult(
      items: (j['items'] as List).map((e) => Item.fromJson(e as Map<String, dynamic>)).toList(),
      via: j['via'] as String,
      warning: j['warning'] as String?,
    );
  }

  Future<List<Item>> items({String status = 'all', String? q, ItemType? type}) async {
    final qs = <String, String>{'status': status, if (q != null && q.trim().isNotEmpty) 'q': q.trim(), if (type != null) 'type': type.name};
    final list = await _send('GET', '/v1/items?${Uri(queryParameters: qs).query}') as List;
    return list.map((e) => Item.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Item> updateItem(String id, Map<String, dynamic> patch) async =>
      Item.fromJson(await _send('PATCH', '/v1/items/$id', patch) as Map<String, dynamic>);

  Future<void> deleteItem(String id) => _send('DELETE', '/v1/items/$id');

  /// «Remind me later»: the reminder moves [minutes] from now; the due time stays.
  Future<Item> snooze(String id, int minutes) async =>
      Item.fromJson(await _send('POST', '/v1/items/$id/snooze', {'minutes': minutes}) as Map<String, dynamic>);

  /// Ask about your own life: «فردا چی کار دارم؟».
  Future<AskResult> ask(String question) async {
    final j = await _send('POST', '/v1/ask', {'question': question, 'tzOffset': DateTime.now().timeZoneOffset.inMinutes}) as Map<String, dynamic>;
    return AskResult(
      answer: j['answer'] as String,
      via: j['via'] as String,
      warning: j['warning'] as String?,
      items: (j['items'] as List).map((e) => Item.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  /// Live events from the server (device changes now; items, reminders, approvals later).
  Stream<Map<String, dynamic>> live() {
    final ws = Uri.parse(baseUrl).replace(
      scheme: baseUrl.startsWith('https') ? 'wss' : 'ws',
      path: '/v1/live',
      queryParameters: {'token': token ?? ''},
    );
    return WebSocketChannel.connect(ws).stream.map((m) => jsonDecode(m as String) as Map<String, dynamic>);
  }
}
