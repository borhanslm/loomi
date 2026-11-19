// First run: connect this device to the user's Loomi Server — scan the server's QR
// (phone) or type the address and the 8-digit code.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api/loomi_api.dart';
import '../local/session.dart';
import 'theme.dart';

class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});
  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  final _url = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController(text: platformName == 'android' ? 'گوشی من' : 'کامپیوتر من');
  bool _busy = false, _manual = platformName != 'android';
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
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Center(child: LoomiLogo(size: 104)),
                const SizedBox(height: 22),
                Text('Loomi', textAlign: TextAlign.center, textDirection: TextDirection.ltr, style: t.headlineMedium?.copyWith(fontSize: 40)),
                const SizedBox(height: 4),
                Text('ذهن دوم شما', textAlign: TextAlign.center, style: t.titleMedium?.copyWith(color: Loomi.violetSoft, fontWeight: FontWeight.w500)),
                const SizedBox(height: 10),
                Text('برای شروع، این دستگاه را به سرور لومی خودتان وصل کنید.', textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: Loomi.muted)),
                const SizedBox(height: 28),
                GlassCard(
                  padding: const EdgeInsets.all(20),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (!_manual) ...[
                        const _Step(icon: Icons.qr_code_2_rounded, text: 'در پنل ادمین سرور، بخش «دستگاه‌ها»، «جفت کردن دستگاه تازه» را بزنید.'),
                        const SizedBox(height: 18),
                        GradientButton(label: 'اسکن QR سرور', icon: Icons.qr_code_scanner_rounded, busy: _busy, onPressed: _scan),
                        const SizedBox(height: 8),
                        TextButton(onPressed: () => setState(() => _manual = true), child: const Text('وارد کردن دستی کد')),
                      ] else ...[
                        TextField(
                          controller: _url,
                          textDirection: TextDirection.ltr,
                          keyboardType: TextInputType.url,
                          autofillHints: const [AutofillHints.url],
                          decoration: const InputDecoration(labelText: 'آدرس سرور', hintText: 'loomi.example.com', prefixIcon: Icon(Icons.dns_outlined)),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _code,
                          textDirection: TextDirection.ltr,
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')), LengthLimitingTextInputFormatter(9)],
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: 6),
                          decoration: const InputDecoration(labelText: 'کد جفت‌سازی (۸ رقم)', counterText: ''),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _name,
                          decoration: const InputDecoration(labelText: 'اسم این دستگاه', prefixIcon: Icon(Icons.devices_rounded)),
                        ),
                        const SizedBox(height: 18),
                        GradientButton(label: 'اتصال', icon: Icons.link_rounded, busy: _busy, onPressed: _connect),
                        if (platformName == 'android') ...[
                          const SizedBox(height: 8),
                          TextButton(onPressed: () => setState(() => _manual = false), child: const Text('اسکن QR به‌جای آن')),
                        ],
                      ],
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: _error == null
                            ? const SizedBox(height: 0)
                            : Padding(
                                key: ValueKey(_error),
                                padding: const EdgeInsets.only(top: 14),
                                child: Row(children: [
                                  const Icon(Icons.error_outline_rounded, color: Loomi.danger, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(_error!, style: const TextStyle(color: Loomi.danger))),
                                ]),
                              ),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 22),
                Text('سرور ندارید؟ با یک خط روی سرور خودتان نصبش کنید:\ngithub.com/borhanslm/loomi',
                    textAlign: TextAlign.center, style: t.bodySmall),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: Loomi.violet.withValues(alpha: .18), borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: Loomi.violetSoft),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
      ]);
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
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('اسکن QR سرور لومی'), backgroundColor: Colors.transparent),
        extendBodyBehindAppBar: true,
        body: Stack(children: [
          MobileScanner(onDetect: (cap) {
            final v = cap.barcodes.isEmpty ? null : cap.barcodes.first.rawValue;
            if (v == null || _done) return;
            _done = true;
            HapticFeedback.mediumImpact();
            Navigator.of(context).pop(v);
          }),
          Center(
            child: Container(
              width: 250, height: 250,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(28), border: Border.all(color: Loomi.cyan, width: 3)),
            ),
          ),
          const Positioned(
            left: 0, right: 0, bottom: 64,
            child: Text('QR داخل پنل ادمین را در کادر بگیرید', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ]),
      );
}
