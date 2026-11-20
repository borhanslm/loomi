// Listening and speaking on the device.
//  • VoiceRecorder records 16 kHz mono WAV and notices when you stop talking
//    (a quiet moment after speech), so you just talk — no button to hold.
//  • VoicePlayer plays Loomi's answer.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Decides when speech has ended from loudness samples (dBFS, -160 … 0). Pure, for tests.
class EndOfSpeech {
  EndOfSpeech({this.speechDb = -38, this.silenceDb = -46, this.quiet = const Duration(milliseconds: 1600),
      this.waitForSpeech = const Duration(seconds: 8), this.maxLength = const Duration(seconds: 60)});
  final double speechDb, silenceDb;
  final Duration quiet, waitForSpeech, maxLength;

  bool heardSpeech = false;
  Duration? _quietSince;

  /// Feed one sample taken [at] since recording started; true = stop now.
  bool add(double db, Duration at) {
    if (at >= maxLength) return true;
    if (db >= speechDb) {
      heardSpeech = true;
      _quietSince = null;
      return false;
    }
    if (!heardSpeech) return at >= waitForSpeech;
    if (db <= silenceDb) {
      _quietSince ??= at;
      return at - _quietSince! >= quiet;
    }
    return false;
  }
}

class VoiceRecorder {
  final _rec = AudioRecorder();
  StreamSubscription<Amplitude>? _amp;
  String? _path;

  Future<bool> hasPermission() => _rec.hasPermission();

  /// Start listening. [onLevel] gets 0…1 for the animation; [onEnd] fires once speech has ended.
  Future<void> start({required void Function(double level) onLevel, required void Function(bool heardSpeech) onEnd}) async {
    final dir = await getTemporaryDirectory();
    _path = '${dir.path}${Platform.pathSeparator}loomi-voice-${DateTime.now().millisecondsSinceEpoch}.wav';
    await _rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1, noiseSuppress: true, autoGain: true), path: _path!);
    final eos = EndOfSpeech();
    final started = DateTime.now();
    var ended = false;
    _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
      final db = a.current.isFinite ? a.current : -160.0;
      onLevel(((db + 60) / 60).clamp(0.0, 1.0));
      if (!ended && eos.add(db, DateTime.now().difference(started))) {
        ended = true;
        onEnd(eos.heardSpeech);
      }
    });
  }

  /// Stop and return the recording (null if nothing was recorded).
  Future<Uint8List?> stop() async {
    await _amp?.cancel();
    _amp = null;
    final path = await _rec.stop() ?? _path;
    if (path == null) return null;
    final f = File(path);
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    unawaited(f.delete().catchError((_) => f));
    return bytes;
  }

  Future<void> cancel() async {
    await _amp?.cancel();
    _amp = null;
    await _rec.cancel();
  }

  Future<void> dispose() async {
    await _amp?.cancel();
    await _rec.dispose();
  }
}

class VoicePlayer {
  final _player = AudioPlayer();
  Stream<PlayerState> get state => _player.onPlayerStateChanged;

  /// Play mp3 bytes (through a temp file: works the same on Android and Windows).
  Future<void> play(Uint8List mp3) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}loomi-say.mp3');
    await f.writeAsBytes(mp3, flush: true);
    await _player.stop();
    await _player.play(DeviceFileSource(f.path, mimeType: 'audio/mpeg'));
  }

  Future<void> stop() => _player.stop();
  Future<void> dispose() => _player.dispose();
}
