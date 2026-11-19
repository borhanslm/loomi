// Keeps the app up to date from GitHub Releases.
//   Android: tells the user a new version is out, with a one-tap download (Android then installs it).
//   Windows: downloads the new installer in the background, then installs it with one click and reopens.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const releasesApi = 'https://api.github.com/repos/borhanslm/loomi/releases/latest';

class UpdateInfo {
  UpdateInfo({required this.version, required this.apkUrl, required this.exeUrl, required this.pageUrl});
  final String version;
  final String? apkUrl, exeUrl;
  final String pageUrl;
}

/// -1 if a < b, 0 if equal, 1 if a > b ("0.10.0" > "0.9.3").
int compareVersions(String a, String b) {
  List<int> p(String v) => v.replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[.+-]')).take(3).map((x) => int.tryParse(x) ?? 0).toList();
  final x = p(a), y = p(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

UpdateInfo? parseRelease(Map<String, dynamic> j) {
  final tag = j['tag_name'] as String?;
  if (tag == null || j['draft'] == true || j['prerelease'] == true) return null;
  String? asset(String name) {
    for (final a in (j['assets'] as List? ?? const [])) {
      if (a is Map && a['name'] == name) return a['browser_download_url'] as String?;
    }
    return null;
  }
  return UpdateInfo(version: tag.replaceFirst('v', ''), apkUrl: asset('Loomi.apk'), exeUrl: asset('Loomi-Setup.exe'), pageUrl: j['html_url'] as String? ?? 'https://github.com/borhanslm/loomi/releases/latest');
}

enum UpdatePhase { idle, available, downloading, ready, failed }

class UpdateState {
  const UpdateState({this.phase = UpdatePhase.idle, this.info, this.progress = 0, this.file, this.current});
  final UpdatePhase phase;
  final UpdateInfo? info;
  final double progress;
  final String? file, current;
}

class UpdateController extends Notifier<UpdateState> {
  static const _kDismissed = 'loomi.update.dismissed';
  Timer? _timer;

  bool get _android { try { return Platform.isAndroid; } catch (_) { return false; } }
  bool get _windows { try { return Platform.isWindows; } catch (_) { return false; } }

  @override
  UpdateState build() {
    if (_android || _windows) {
      Future.delayed(const Duration(seconds: 4), check);
      _timer = Timer.periodic(const Duration(hours: 6), (_) => check());
      ref.onDispose(() => _timer?.cancel());
    }
    return const UpdateState();
  }

  Future<void> check() async {
    if (state.phase == UpdatePhase.downloading || state.phase == UpdatePhase.ready) return;
    try {
      final current = (await PackageInfo.fromPlatform()).version;
      final res = await http.get(Uri.parse(releasesApi), headers: {'accept': 'application/vnd.github+json', 'user-agent': 'Loomi-App'}).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return;
      final info = parseRelease(jsonDecode(res.body) as Map<String, dynamic>);
      if (info == null || compareVersions(info.version, current) <= 0) return;
      final p = await SharedPreferences.getInstance();
      if (_android && p.getString(_kDismissed) == info.version) return; // the user said «later» to this one
      state = UpdateState(phase: UpdatePhase.available, info: info, current: current);
      if (_windows && info.exeUrl != null) await _download(info);
    } catch (_) {
      // offline or GitHub unreachable — try again later
    }
  }

  /// Windows: fetch the installer quietly in the background.
  Future<void> _download(UpdateInfo info) async {
    state = UpdateState(phase: UpdatePhase.downloading, info: info, current: state.current);
    final client = http.Client();
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}loomi-update');
      await dir.create(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}Loomi-Setup-${info.version}.exe');
      final res = await client.send(http.Request('GET', Uri.parse(info.exeUrl!)));
      if (res.statusCode != 200) throw const HttpException('download failed');
      final total = res.contentLength ?? 0;
      var got = 0;
      final sink = file.openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) state = UpdateState(phase: UpdatePhase.downloading, info: info, progress: got / total, current: state.current);
      }
      await sink.close();
      if (total > 0 && got != total) throw const HttpException('incomplete download');
      state = UpdateState(phase: UpdatePhase.ready, info: info, file: file.path, current: state.current);
    } catch (_) {
      state = UpdateState(phase: UpdatePhase.failed, info: info, current: state.current);
    } finally {
      client.close();
    }
  }

  /// Windows: run the new installer silently; it closes Loomi, updates it, and opens it again.
  Future<void> installNow() async {
    final f = state.file;
    if (f == null) return;
    await Process.start(f, ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/CURRENTUSER'], mode: ProcessStartMode.detached);
    exit(0);
  }

  Future<void> retry() async {
    final info = state.info;
    if (info != null && _windows && info.exeUrl != null) await _download(info);
  }

  /// Android: open the APK link; the browser downloads it and Android offers to install it.
  Future<void> openDownload() async {
    final i = state.info;
    if (i == null) return;
    await launchUrl(Uri.parse(i.apkUrl ?? i.pageUrl), mode: LaunchMode.externalApplication);
  }

  Future<void> later() async {
    final v = state.info?.version;
    if (v != null) (await SharedPreferences.getInstance()).setString(_kDismissed, v);
    state = const UpdateState();
  }
}

final updateProvider = NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
