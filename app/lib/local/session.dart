// The connection to the user's Loomi Server: address + this device's token,
// kept in the OS secure store (Android Keystore / Windows DPAPI).
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/loomi_api.dart';

class Session {
  const Session(this.url, this.token);
  final String url, token;
  LoomiApi get api => LoomiApi(url, token: token);
}

abstract class SessionStore {
  Future<Session?> read();
  Future<void> write(Session s);
  Future<void> clear();
}

class SecureSessionStore implements SessionStore {
  static const _s = FlutterSecureStorage();
  @override
  Future<Session?> read() async {
    final url = await _s.read(key: 'server_url'), token = await _s.read(key: 'device_token');
    return url != null && token != null ? Session(url, token) : null;
  }

  @override
  Future<void> write(Session s) async {
    await _s.write(key: 'server_url', value: s.url);
    await _s.write(key: 'device_token', value: s.token);
  }

  @override
  Future<void> clear() => _s.deleteAll();
}

final sessionStoreProvider = Provider<SessionStore>((_) => SecureSessionStore());

String get platformName {
  try {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
  } catch (_) {}
  return 'unknown';
}

class SessionNotifier extends AsyncNotifier<Session?> {
  @override
  Future<Session?> build() => ref.read(sessionStoreProvider).read();

  /// Pair this device with a server using a one-time code.
  Future<void> pair({required String url, required String code, required String name}) async {
    final base = normalizeServerUrl(url);
    final api = LoomiApi(base);
    final h = await api.health();
    if (h['name'] != 'loomi') throw LoomiApiError('این آدرس سرور لومی نیست.');
    final token = await api.pair(code: code.replaceAll(RegExp(r'\D'), ''), name: name, platform: platformName);
    final s = Session(base, token);
    await ref.read(sessionStoreProvider).write(s);
    state = AsyncData(s);
  }

  Future<void> signOut() async {
    await ref.read(sessionStoreProvider).clear();
    state = const AsyncData(null);
  }
}

final sessionProvider = AsyncNotifierProvider<SessionNotifier, Session?>(SessionNotifier.new);
