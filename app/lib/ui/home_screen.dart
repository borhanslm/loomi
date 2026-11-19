// Main screen: «امروز» (today) · «همه‌چیز» (everything) · «دستگاه‌ها» (devices), with the capture bar
// always at hand. Keeps a live connection to the server and syncs items as they change.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../api/loomi_api.dart';
import '../fa/dates.dart';
import '../local/items_store.dart';
import '../local/session.dart';
import 'desktop.dart';
import 'items_ui.dart';
import 'theme.dart';
import 'update_banner.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, required this.session});
  final Session session;
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;
  bool _live = false;
  int _devicesTick = 0;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _retry;

  LoomiApi get _api => widget.session.api;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(itemsProvider.notifier).refresh());
    _connectLive();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _retry?.cancel();
    super.dispose();
  }

  void _connectLive() {
    _sub?.cancel();
    _sub = _api.live().listen(
      (ev) {
        switch (ev['type']) {
          case 'hello':
            setState(() => _live = true);
            ref.read(itemsProvider.notifier).refresh(); // also sends anything typed while offline
          case 'items':
            ref.read(itemsProvider.notifier).refresh();
          case 'devices':
            setState(() => _devicesTick++);
        }
      },
      onError: (_) => _lost(),
      onDone: _lost,
    );
  }

  void _lost() {
    if (!mounted) return;
    setState(() => _live = false);
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), _connectLive);
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 5) return 'شب بخیر';
    if (h < 12) return 'صبح بخیر';
    if (h < 17) return 'روز بخیر';
    if (h < 21) return 'عصر بخیر';
    return 'شب بخیر';
  }

  Widget _todayHeader(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(longDate(DateTime.now()), style: t.bodyMedium?.copyWith(color: Loomi.violetSoft, fontWeight: FontWeight.w600)),
        Text(_greeting, style: t.headlineMedium),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    // Desktop-sized windows get the desktop layout; narrow windows and phones the phone layout.
    if (width >= 980) {
      return Scaffold(
        body: DesktopShell(
          session: widget.session,
          live: _live,
          greeting: _greeting,
          devicesView: DevicesView(session: widget.session, tick: _devicesTick),
        ),
      );
    }
    final wide = width > 760;
    final pages = [
      TodayView(header: _todayHeader(context)),
      const AllView(),
      DevicesView(session: widget.session, tick: _devicesTick),
    ];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(children: [
              Padding(
                padding: EdgeInsets.fromLTRB(wide ? 24 : 18, 12, wide ? 24 : 18, 4),
                child: Row(children: [
                  const LoomiLogo(size: 36, glow: false),
                  const SizedBox(width: 10),
                  Text('Loomi', textDirection: TextDirection.ltr, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  const Spacer(),
                  StatusPill(online: _live),
                ]),
              ),
              Padding(padding: EdgeInsets.symmetric(horizontal: wide ? 24 : 16), child: const UpdateBanner()),
              Expanded(child: AnimatedSwitcher(duration: const Duration(milliseconds: 220), child: KeyedSubtree(key: ValueKey(_tab), child: pages[_tab]))),
              if (_tab != 2) const CaptureBar(),
            ]),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: Loomi.ink2.withValues(alpha: .92),
        indicatorColor: Loomi.violet.withValues(alpha: .3),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.wb_sunny_outlined), selectedIcon: Icon(Icons.wb_sunny_rounded), label: 'امروز'),
          NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2_rounded), label: 'همه‌چیز'),
          NavigationDestination(icon: Icon(Icons.devices_outlined), selectedIcon: Icon(Icons.devices_rounded), label: 'دستگاه‌ها'),
        ],
      ),
    );
  }
}

/// Paired devices: invite another, revoke one, and disconnect this one.
class DevicesView extends ConsumerStatefulWidget {
  const DevicesView({super.key, required this.session, required this.tick});
  final Session session;
  final int tick;
  @override
  ConsumerState<DevicesView> createState() => _DevicesViewState();
}

class _DevicesViewState extends ConsumerState<DevicesView> {
  List<Device>? _devices;
  String? _myId, _error;

  LoomiApi get _api => widget.session.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DevicesView old) {
    super.didUpdateWidget(old);
    if (old.tick != widget.tick) _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.devices();
      _myId ??= await _api.myDeviceId();
      if (mounted) setState(() { _devices = d; _error = null; });
    } on LoomiApiError catch (e) {
      if (e.unauthorized) return _signOut(); // this device was revoked
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _signOut() async {
    await ref.read(itemsProvider.notifier).clearLocal();
    await ref.read(sessionProvider.notifier).signOut();
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
    return RefreshIndicator(
      onRefresh: _load,
      color: Loomi.violet,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Text('دستگاه‌ها', style: t.headlineMedium),
        const SizedBox(height: 12),
        GlassCard(
          highlight: true,
          child: Row(children: [
            Container(
              width: 50, height: 50,
              decoration: BoxDecoration(gradient: Loomi.gradient, borderRadius: BorderRadius.circular(16)),
              child: const Icon(Icons.dns_rounded, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('سرور لومی شما', style: t.titleMedium),
              Text(widget.session.url, textDirection: TextDirection.ltr, style: t.bodySmall, overflow: TextOverflow.ellipsis),
            ])),
          ]),
        ),
        SectionTitle('دستگاه‌های جفت‌شده',
            trailing: TextButton.icon(onPressed: _invite, icon: const Icon(Icons.add_rounded), label: const Text('دستگاه تازه'))),
        if (_error != null) Text(_error!, style: const TextStyle(color: Loomi.danger)),
        if (_devices == null && _error == null) const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator(color: Loomi.violet))),
        for (final d in _devices ?? <Device>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                Icon(d.platform == 'android' ? Icons.smartphone_rounded : Icons.laptop_windows_rounded, color: Loomi.violetSoft),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.id == _myId ? '${d.name}  ·  همین دستگاه' : d.name, style: t.titleMedium, overflow: TextOverflow.ellipsis),
                  Text('آخرین اتصال: ${whenLabel(d.lastSeen.toLocal(), allDay: false)}', style: t.bodySmall),
                ])),
                if (d.id != _myId)
                  IconButton(tooltip: 'قطع دسترسی', icon: const Icon(Icons.link_off_rounded, color: Loomi.muted), onPressed: () => _revoke(d)),
              ]),
            ),
          ),
        const SizedBox(height: 18),
        Center(
          child: TextButton.icon(
            onPressed: _signOut,
            icon: const Icon(Icons.logout_rounded, size: 20),
            label: const Text('جدا کردن این دستگاه از سرور'),
            style: TextButton.styleFrom(foregroundColor: Loomi.muted),
          ),
        ),
      ]),
    );
  }
}
