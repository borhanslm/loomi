// Talk to Loomi: tap the mic, say anything, stop talking. Loomi saves it — or, for a question,
// answers out loud (when a voice is chosen in the admin panel).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../api/loomi_api.dart';
import '../fa/dates.dart';
import '../local/items_store.dart';
import '../local/session.dart';
import '../local/voice.dart';
import 'items_ui.dart';
import 'theme.dart';

Future<void> showVoice(BuildContext context) => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Loomi.ink2,
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640), child: const VoiceView()),
      ),
    );

/// A round mic button for the capture bars.
class MicButton extends StatelessWidget {
  const MicButton({super.key, this.size = 46});
  final double size;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'با صدا بگو (Ctrl+M)',
        child: InkWell(
          borderRadius: BorderRadius.circular(size),
          onTap: () {
            HapticFeedback.lightImpact();
            showVoice(context);
          },
          child: Container(
            width: size, height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Loomi.violet.withValues(alpha: .16),
              border: Border.all(color: Loomi.violet.withValues(alpha: .5)),
            ),
            child: const Icon(Icons.mic_rounded, color: Loomi.violetSoft),
          ),
        ),
      );
}

enum _Stage { starting, listening, thinking, done, error }

class VoiceView extends ConsumerStatefulWidget {
  const VoiceView({super.key});
  @override
  ConsumerState<VoiceView> createState() => _VoiceViewState();
}

class _VoiceViewState extends ConsumerState<VoiceView> with SingleTickerProviderStateMixin {
  final _rec = VoiceRecorder();
  final _player = VoicePlayer();
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  _Stage _stage = _Stage.starting;
  double _level = 0;
  String? _error;
  VoiceResult? _result;
  bool _speaking = false;
  StreamSubscription<dynamic>? _playerSub;

  @override
  void initState() {
    super.initState();
    _playerSub = _player.state.listen((s) {
      if (mounted) setState(() => _speaking = s.name == 'playing');
    });
    _listen();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _playerSub?.cancel();
    _rec.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _listen() async {
    setState(() { _stage = _Stage.starting; _error = null; _result = null; });
    try {
      if (!await _rec.hasPermission()) {
        return await _fail('اجازه‌ی میکروفون داده نشد. از تنظیمات دستگاه به Loomi اجازه‌ی میکروفون بدهید.');
      }
      await _rec.start(
        onLevel: (l) { if (mounted) setState(() => _level = l); },
        onEnd: (heard) => heard ? _finish() : _fail('صدایی نشنیدم. دوباره امتحان کنید.', stop: true),
      );
      if (mounted) setState(() => _stage = _Stage.listening);
    } catch (_) {
      _fail('میکروفون در دسترس نیست.');
    }
  }

  Future<void> _fail(String m, {bool stop = false}) async {
    if (stop) await _rec.cancel();
    if (mounted) setState(() { _stage = _Stage.error; _error = m; });
  }

  Future<void> _finish() async {
    if (_stage != _Stage.listening) return;
    setState(() => _stage = _Stage.thinking);
    final api = ref.read(sessionProvider).value?.api;
    final audio = await _rec.stop();
    if (api == null || audio == null) return _fail('ضبط نشد. دوباره امتحان کنید.');
    try {
      final r = await api.voice(audio, clientId: newClientId());
      if (r.capture != null) await ref.read(itemsProvider.notifier).absorb(r.capture!.items);
      if (!mounted) return;
      setState(() { _result = r; _stage = r.kind == 'empty' ? _Stage.error : _Stage.done; _error = r.kind == 'empty' ? 'چیزی نفهمیدم. دوباره بگو.' : null; });
      if (r.canSpeak && r.answer != null) unawaited(_say(r.answer!.answer));
    } on LoomiApiError catch (e) {
      _fail(e.message);
    }
  }

  Future<void> _say(String text) async {
    final api = ref.read(sessionProvider).value?.api;
    if (api == null) return;
    try {
      await _player.play(await api.speak(text));
    } catch (_) {} // the text is on screen anyway
  }

  Future<void> _close() async {
    if (_stage == _Stage.listening || _stage == _Stage.starting) await _rec.cancel();
    await _player.stop();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final r = _result;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.space): () => _stage == _Stage.listening ? _finish() : null,
      },
      child: Focus(
        autofocus: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const LoomiLogo(size: 28),
              const SizedBox(width: 10),
              Expanded(child: Text(switch (_stage) {
                _Stage.starting || _Stage.listening => 'دارم گوش می‌دم…',
                _Stage.thinking => 'دارم می‌فهمم…',
                _Stage.done => r?.kind == 'answer' ? 'جواب لومی' : 'ذخیره شد',
                _Stage.error => 'نشد',
              }, style: t.titleMedium)),
              IconButton(tooltip: 'بستن', onPressed: _close, icon: const Icon(Icons.close_rounded)),
            ]),
            const SizedBox(height: 10),
            if (_stage == _Stage.starting || _stage == _Stage.listening || _stage == _Stage.thinking) ...[
              const SizedBox(height: 8),
              Center(child: _Orb(pulse: _pulse, level: _stage == _Stage.thinking ? .25 : _level, thinking: _stage == _Stage.thinking, onTap: _finish)),
              const SizedBox(height: 18),
              Text(
                _stage == _Stage.thinking ? 'یک لحظه…' : 'هر چه در ذهنت است بگو؛ وقتی ساکت شدی، خودم می‌فهمم.\nیا روی دایره بزن.',
                textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: Loomi.muted, height: 1.7),
              ),
              const SizedBox(height: 12),
            ],
            if (_stage == _Stage.error) ...[
              Text(_error ?? 'خطا', style: const TextStyle(color: Loomi.danger)),
              const SizedBox(height: 12),
              Align(alignment: AlignmentDirectional.centerStart, child: GradientButton(label: 'دوباره', icon: Icons.mic_rounded, onPressed: _listen)),
              const SizedBox(height: 8),
            ],
            if (_stage == _Stage.done && r != null) Flexible(child: _resultView(r, t)),
          ]),
        ),
      ),
    );
  }

  Widget _resultView(VoiceResult r, TextTheme t) {
    final local = ref.watch(itemsProvider).items;
    Item fresh(Item i) => local.where((l) => l.id == i.id).firstOrNull ?? i;
    final items = (r.answer?.items ?? r.capture?.items ?? const <Item>[]).map(fresh).toList();
    final warning = r.answer?.warning ?? r.capture?.warning;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('«${r.text}»', style: t.bodyMedium?.copyWith(color: Loomi.violetSoft, height: 1.6)),
      const SizedBox(height: 12),
      Flexible(
        child: ListView(shrinkWrap: true, children: [
          if (r.answer != null) SelectableText(r.answer!.answer, style: t.bodyLarge?.copyWith(height: 1.7)),
          if (r.capture != null)
            Text(r.capture!.items.isEmpty ? 'چیزی برای ذخیره پیدا نشد.' : '${faDigits(r.capture!.items.length)} مورد ساخته شد:', style: t.bodyLarge),
          if (warning != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(warning, style: t.bodySmall)),
          const SizedBox(height: 10),
          for (final i in items) ItemTile(item: i),
        ]),
      ),
      const SizedBox(height: 6),
      Row(children: [
        TextButton.icon(onPressed: _listen, icon: const Icon(Icons.mic_rounded), label: const Text('دوباره بگو')),
        if (r.answer != null && r.canSpeak)
          TextButton.icon(
            onPressed: _speaking ? _player.stop : () => _say(r.answer!.answer),
            icon: Icon(_speaking ? Icons.stop_rounded : Icons.volume_up_rounded),
            label: Text(_speaking ? 'بس است' : 'بخوان'),
          ),
        const Spacer(),
        TextButton(onPressed: _close, child: const Text('بستن')),
      ]),
    ]);
  }
}

/// The listening orb: breathes, and swells with your voice.
class _Orb extends StatelessWidget {
  const _Orb({required this.pulse, required this.level, required this.thinking, required this.onTap});
  final Animation<double> pulse;
  final double level;
  final bool thinking;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'تمام شد',
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedBuilder(
            animation: pulse,
            builder: (_, _) {
              final p = pulse.value;
              final grow = 1 + level * .35;
              return SizedBox(
                width: 170, height: 170,
                child: Stack(alignment: Alignment.center, children: [
                  for (var k = 0; k < 2; k++)
                    Opacity(
                      opacity: (1 - ((p + k * .5) % 1)) * .35,
                      child: Container(
                        width: 96 + 74 * ((p + k * .5) % 1), height: 96 + 74 * ((p + k * .5) % 1),
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Loomi.cyan, width: 2)),
                      ),
                    ),
                  Transform.rotate(
                    angle: thinking ? p * 2 * math.pi : 0,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 110),
                      width: 96 * grow, height: 96 * grow,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: Loomi.gradient,
                        boxShadow: [BoxShadow(color: Loomi.violet.withValues(alpha: .45 + level * .3), blurRadius: 30 + level * 30)],
                      ),
                      child: Icon(thinking ? Icons.auto_awesome_rounded : Icons.mic_rounded, color: Colors.white, size: 40),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      );
}
