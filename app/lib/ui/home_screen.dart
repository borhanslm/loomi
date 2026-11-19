// Home: greeting, connection, what Loomi can do (and what is coming), and this user's devices.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../api/loomi_api.dart';
import '../local/session.dart';
import 'theme.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, required this.session});
  final Session session;
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  List<Device>? _devices;
  String? _myId, _error;
  bool _live = false;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _retry;

  LoomiApi get _api => widget.session.api;

  @override
  void initState() {
    super.initState();
    _load();
    _connectLive();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _retry?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await _api.devices();
      _myId ??= await _api.myDeviceId();
      if (mounted) setState(() { _devices = d; _error = null; });
    } on LoomiApiError catch (e) {
      if (e.unauthorized) return ref.read(sessionProvider.notifier).signOut(); // this device was revoked
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _connectLive() {
    _sub?.cancel();
    _sub = _api.live().listen(
      (ev) {
        if (ev['type'] == 'hello') setState(() => _live = true);
        if (ev['type'] == 'devices') _load();
      },
      onError: (_) => _lost(),
      onDone: _lost,
    );
  }

  void _lost() {
    if (!mounted) return;
    setState(() => _live = false);
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), () { _connectLive(); _load(); });
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 5) return 'شب بخیر';
    if (h < 12) return 'صبح بخیر';
    if (h < 17) return 'روز بخیر';
    if (h < 21) return 'عصر بخیر';
    return 'شب بخیر';
  }

  Future<void> _invite() async {
    try {
      final inv = await _api.invite();
      if (!mounted) return;
      final c = inv.code;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('جفت کردن دستگاه دیگر'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('در اپ Loomi روی دستگاه دیگر، آدرس سرور و این کد را وارد کنید:'),
            const SizedBox(height: 18),
            ShaderMask(
              shaderCallback: (r) => Loomi.gradient.createShader(r),
              child: SelectableText('${c.substring(0, 4)}  ${c.substring(4)}',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: 4, color: Colors.white)),
            ),
            const SizedBox(height: 8),
            SelectableText(widget.session.url, textDirection: TextDirection.ltr, style: const TextStyle(color: Loomi.muted)),
            const SizedBox(height: 12),
            const Text('فقط یک بار و تا چند دقیقه کار می‌کند.', style: TextStyle(color: Loomi.muted, fontSize: 13)),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('بستن'))],
        ),
      );
    } on LoomiApiError catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _revoke(Device d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('دسترسی «${d.name}» قطع شود؟'),
        content: const Text('این دستگاه دیگر به لومی وصل نمی‌شود، مگر دوباره جفت شود.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), style: TextButton.styleFrom(foregroundColor: Loomi.danger), child: const Text('قطع دسترسی')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.revoke(d.id);
      await _load();
    } on LoomiApiError catch (e) {
      _toast(e.message);
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final wide = MediaQuery.sizeOf(context).width > 760;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          color: Loomi.violet,
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: wide ? 40 : 18, vertical: 16),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // top bar
                    Row(children: [
                      const LoomiLogo(size: 40, glow: false),
                      const SizedBox(width: 10),
                      Text('Loomi', textDirection: TextDirection.ltr, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                      const Spacer(),
                      StatusPill(online: _live),
                    ]),
                    const SizedBox(height: 28),
                    // greeting
                    Text(_greeting, style: t.headlineMedium),
                    const SizedBox(height: 4),
                    Text('لومی آماده است. به‌زودی هر چیزی که بگویید را این‌جا مرتب می‌کند.', style: t.bodyMedium?.copyWith(color: Loomi.muted)),
                    const SizedBox(height: 20),
                    GlassCard(
                      highlight: true,
                      child: Row(children: [
                        Container(
                          width: 52, height: 52,
                          decoration: BoxDecoration(gradient: Loomi.gradient, borderRadius: BorderRadius.circular(16)),
                          child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
                        ),
                        const SizedBox(width: 14),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('به سرور خودتان وصل هستید', style: t.titleMedium),
                          Text(widget.session.url, textDirection: TextDirection.ltr, style: t.bodySmall, overflow: TextOverflow.ellipsis),
                        ])),
                      ]),
                    ),
                    const SectionTitle('لومی به‌زودی برایتان'),
                    GridView.count(
                      crossAxisCount: wide ? 4 : 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: wide ? 1.05 : 1.1,
                      children: const [
                        _Feature(icon: Icons.edit_note_rounded, title: 'گرفتن و فهمیدن', body: 'بگویید یا بنویسید؛ کار، خرید، ایده', color: Loomi.violet),
                        _Feature(icon: Icons.notifications_active_rounded, title: 'یادآوری', body: 'سر وقت، حتی با اپ بسته', color: Loomi.amber),
                        _Feature(icon: Icons.graphic_eq_rounded, title: 'حرف زدن', body: 'با صدای دلخواه شما', color: Loomi.cyan),
                        _Feature(icon: Icons.bolt_rounded, title: '«هی لومی»', body: 'حتی با صفحه‌ی خاموش', color: Color(0xFFF472B6)),
                      ],
                    ),
                    SectionTitle('دستگاه‌های من',
                        trailing: TextButton.icon(onPressed: _invite, icon: const Icon(Icons.add_rounded), label: const Text('دستگاه تازه'))),
                    if (_error != null)
                      GlassCard(child: Row(children: [
                        const Icon(Icons.cloud_off_rounded, color: Loomi.danger),
                        const SizedBox(width: 10),
                        Expanded(child: Text(_error!, style: const TextStyle(color: Loomi.danger))),
                      ])),
                    if (_devices == null && _error == null)
                      const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator(color: Loomi.violet))),
                    for (final d in _devices ?? <Device>[])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: GlassCard(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(children: [
                            Container(
                              width: 44, height: 44,
                              decoration: BoxDecoration(color: Loomi.glass, borderRadius: BorderRadius.circular(14), border: Border.all(color: Loomi.glassBorder)),
                              child: Icon(d.platform == 'android' ? Icons.smartphone_rounded : Icons.laptop_windows_rounded, color: Loomi.violetSoft),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Flexible(child: Text(d.name, style: t.titleMedium, overflow: TextOverflow.ellipsis)),
                                if (d.id == _myId) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(color: Loomi.cyan.withValues(alpha: .15), borderRadius: BorderRadius.circular(99)),
                                    child: const Text('همین دستگاه', style: TextStyle(color: Loomi.cyan, fontSize: 12)),
                                  ),
                                ],
                              ]),
                              Text(d.platform, textDirection: TextDirection.ltr, style: t.bodySmall),
                            ])),
                            if (d.id != _myId)
                              IconButton(tooltip: 'قطع دسترسی', icon: const Icon(Icons.link_off_rounded, color: Loomi.muted), onPressed: () => _revoke(d)),
                          ]),
                        ),
                      ),
                    const SizedBox(height: 18),
                    Center(
                      child: TextButton.icon(
                        onPressed: () => ref.read(sessionProvider.notifier).signOut(),
                        icon: const Icon(Icons.logout_rounded, size: 20),
                        label: const Text('جدا کردن این دستگاه از سرور'),
                        style: TextButton.styleFrom(foregroundColor: Loomi.muted),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.body, required this.color});
  final IconData icon;
  final String title, body;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(color: color.withValues(alpha: .16), borderRadius: BorderRadius.circular(13)),
            child: Icon(icon, color: color),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(border: Border.all(color: Loomi.glassBorder), borderRadius: BorderRadius.circular(99)),
            child: const Text('به‌زودی', style: TextStyle(fontSize: 11, color: Loomi.muted)),
          ),
        ]),
        const Spacer(),
        Text(title, style: t.titleMedium),
        const SizedBox(height: 2),
        Text(body, style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}
