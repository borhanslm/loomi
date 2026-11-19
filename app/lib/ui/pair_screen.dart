// First run: connect this device to the user's Loomi Server, by scanning the
// server's QR (phone) or typing the address and the 8-digit code.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api/loomi_api.dart';
import '../local/session.dart';

class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});
  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  final _url = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController(text: platformName == 'android' ? 'گوشی من' : 'کامپیوتر من');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_url.text.trim().isEmpty || _code.text.replaceAll(RegExp(r'\D'), '').length != 8) {
      setState(() => _error = 'آدرس سرور و کد ۸ رقمی را وارد کنید.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).pair(url: _url.text, code: _code.text, name: _name.text);
    } on LoomiApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _ScanPage()));
    final inv = raw == null ? null : PairInvite.parse(raw);
    if (inv == null) {
      if (raw != null) setState(() => _error = 'این QR مال لومی نیست.');
      return;
    }
    _url.text = inv.url;
    _code.text = inv.code;
    await _connect();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Icon(Icons.auto_awesome, size: 56, color: t.colorScheme.primary),
                const SizedBox(height: 12),
                Text('سلام، من لومی هستم', textAlign: TextAlign.center, style: t.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text('برای شروع، این دستگاه را به سرور لومی خودتان وصل کنید.',
                    textAlign: TextAlign.center, style: t.textTheme.bodyMedium),
                const SizedBox(height: 28),
                if (platformName == 'android') ...[
                  FilledButton.icon(
                    onPressed: _busy ? null : _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('اسکن QR سرور'),
                  ),
                  const SizedBox(height: 16),
                  const Row(children: [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('یا دستی')), Expanded(child: Divider())]),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _url,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: 'آدرس سرور', hintText: 'loomi.example.com', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.number,
                  maxLength: 9,
                  decoration: const InputDecoration(labelText: 'کد جفت‌سازی (۸ رقم)', border: OutlineInputBorder()),
                ),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'اسم این دستگاه', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: TextStyle(color: t.colorScheme.error)),
                  ),
                FilledButton.tonal(
                  onPressed: _busy ? null : _connect,
                  child: _busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('اتصال'),
                ),
                const SizedBox(height: 16),
                Text('کد را سرور لومی هنگام نصب نشان می‌دهد، یا روی سرور بزنید: npm run pair',
                    textAlign: TextAlign.center, style: t.textTheme.bodySmall),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();
  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('اسکن QR سرور لومی')),
        body: MobileScanner(onDetect: (cap) {
          final v = cap.barcodes.isEmpty ? null : cap.barcodes.first.rawValue;
          if (v == null || _done) return;
          _done = true;
          Navigator.of(context).pop(v);
        }),
      );
}
