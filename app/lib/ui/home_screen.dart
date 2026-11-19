// Phase 0 home: connection status, live link, and this user's devices
// (invite another device, revoke one). "Today" arrives in phase 2.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../api/loomi_api.dart';
import '../local/session.dart';

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

  Future<void> _invite() async {
    try {
      final inv = await _api.invite();
      if (!mounted) return;
      final c = inv.code;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('جفت کردن دستگاه دیگر'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('در اپ لومی روی دستگاه دیگر، آدرس سرور و این کد را وارد کنید:'),
            const SizedBox(height: 12),
            SelectableText('${c.substring(0, 4)} ${c.substring(4)}',
                textDirection: TextDirection.ltr, style: Theme.of(context).textTheme.headlineMedium),
            SelectableText(widget.session.url, textDirection: TextDirection.ltr),
            const SizedBox(height: 8),
            const Text('این کد فقط یک بار و تا چند دقیقه کار می‌کند.'),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('بستن'))],
        ),
      );
    } on LoomiApiError catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _revoke(Device d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('دسترسی «${d.name}» قطع شود؟'),
        content: const Text('این دستگاه دیگر به لومی وصل نمی‌شود، مگر دوباره جفت شود.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('قطع دسترسی')),
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
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('لومی'),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: Chip(
              avatar: Icon(Icons.circle, size: 10, color: _live ? Colors.green : t.colorScheme.outline),
              label: Text(_live ? 'وصل' : 'در حال اتصال…'),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('سرور لومی'),
              subtitle: Text(widget.session.url, textDirection: TextDirection.ltr),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            color: t.colorScheme.primaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Text('«امروز»، گرفتن ایده‌ها و کارها، و یادآورها در مرحله‌های بعد این‌جا می‌آیند.'),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Text('دستگاه‌های من', style: t.textTheme.titleMedium)),
            TextButton.icon(onPressed: _invite, icon: const Icon(Icons.add), label: const Text('دستگاه تازه')),
          ]),
          if (_error != null) Text(_error!, style: TextStyle(color: t.colorScheme.error)),
          if (_devices == null && _error == null) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
          for (final d in _devices ?? <Device>[])
            Card(
              child: ListTile(
                leading: Icon(d.platform == 'android' ? Icons.smartphone : Icons.computer),
                title: Text(d.id == _myId ? '${d.name} (همین دستگاه)' : d.name),
                subtitle: Text(d.platform, textDirection: TextDirection.ltr),
                trailing: d.id == _myId
                    ? null
                    : IconButton(tooltip: 'قطع دسترسی', icon: const Icon(Icons.link_off), onPressed: () => _revoke(d)),
              ),
            ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => ref.read(sessionProvider.notifier).signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('جدا کردن این دستگاه از سرور'),
          ),
        ]),
      ),
    );
  }
}
