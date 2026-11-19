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

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final uri = Uri.parse('$baseUrl$path');
    late http.Response r;
    try {
      final req = http.Request(method, uri)..headers.addAll(_headers);
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
