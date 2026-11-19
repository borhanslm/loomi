// «A new version of Loomi is here» — shown at the top of the main screen when an update exists.
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../fa/dates.dart';
import '../local/updater.dart';
import 'theme.dart';

class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(updateProvider);
    final c = ref.read(updateProvider.notifier);
    if (s.phase == UpdatePhase.idle || s.info == null) return const SizedBox.shrink();
    final v = faDigits(s.info!.version);
    bool windows;
    try { windows = Platform.isWindows; } catch (_) { windows = false; }

    final (String title, String body, List<Widget> actions) = switch (s.phase) {
      UpdatePhase.downloading => ('نسخه‌ی تازه‌ی Loomi ($v)', 'در حال دریافت… ${faDigits((s.progress * 100).round())}٪', <Widget>[]),
      UpdatePhase.ready => ('نسخه‌ی تازه‌ی Loomi ($v) آماده است', 'یک کلیک: نصب می‌شود و Loomi دوباره باز می‌شود.', [
          FilledButton.icon(onPressed: c.installNow, icon: const Icon(Icons.system_update_alt_rounded), label: const Text('نصب و باز کردن دوباره')),
        ]),
      UpdatePhase.failed => ('نسخه‌ی تازه‌ی Loomi ($v)', 'دریافت نشد؛ اینترنت را بررسی کنید.', [
          TextButton(onPressed: c.retry, child: const Text('دوباره')),
        ]),
      _ => windows
          ? ('نسخه‌ی تازه‌ی Loomi ($v) آمده', 'در حال آماده شدن…', <Widget>[])
          : ('نسخه‌ی تازه‌ی Loomi ($v) آمده', 'برای به‌روزرسانی، فایل نصب را دریافت و باز کنید.', [
              FilledButton.icon(onPressed: c.openDownload, icon: const Icon(Icons.download_rounded), label: const Text('دریافت و نصب')),
              TextButton(onPressed: c.later, child: const Text('بعداً')),
            ]),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        highlight: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(gradient: Loomi.gradient, borderRadius: BorderRadius.circular(13)),
            child: const Icon(Icons.rocket_launch_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(body, style: const TextStyle(color: Loomi.muted, fontSize: 13)),
              if (s.phase == UpdatePhase.downloading)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ClipRRect(borderRadius: BorderRadius.circular(99), child: LinearProgressIndicator(value: s.progress > 0 ? s.progress : null, minHeight: 5, color: Loomi.cyan, backgroundColor: Loomi.glass)),
                ),
            ]),
          ),
          ...actions.map((a) => Padding(padding: const EdgeInsetsDirectional.only(start: 8), child: a)),
        ]),
      ),
    );
  }
}
