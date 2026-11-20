// Reminder settings: the morning summary and evening review (on/off and hours), plus a test notification.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../fa/dates.dart';
import '../local/items_store.dart';
import '../local/notice_plan.dart';
import '../local/reminders.dart';
import 'theme.dart';

class ReminderSettingsCard extends ConsumerStatefulWidget {
  const ReminderSettingsCard({super.key});
  @override
  ConsumerState<ReminderSettingsCard> createState() => _ReminderSettingsCardState();
}

class _ReminderSettingsCardState extends ConsumerState<ReminderSettingsCard> {
  DigestTimes? _d;

  @override
  void initState() {
    super.initState();
    loadDigest().then((d) => mounted ? setState(() => _d = d) : null);
  }

  Future<void> _set(DigestTimes d) async {
    setState(() => _d = d);
    await saveDigest(d);
    await Reminders.instance.sync(ref.read(itemsProvider).items);
  }

  Widget _hour(String label, int value, List<int> hours, ValueChanged<int> onChanged) => Row(children: [
        Expanded(child: Text(label, style: const TextStyle(color: Loomi.muted))),
        DropdownButton<int>(
          value: value,
          underline: const SizedBox(),
          dropdownColor: Loomi.ink2,
          items: [for (final h in hours) DropdownMenuItem(value: h, child: Text('ساعت ${faDigits(h)}'))],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final t = Theme.of(context).textTheme;
    if (d == null) return const SizedBox(height: 60);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: d.enabled,
          activeThumbColor: Loomi.violet,
          title: Text('خلاصه‌ی صبح و مرور شب', style: t.titleMedium),
          subtitle: const Text('صبح کارهای امروز را می‌گویم؛ شب آنچه مانده را.'),
          onChanged: (v) => _set(DigestTimes(enabled: v, morningHour: d.morningHour, eveningHour: d.eveningHour)),
        ),
        if (d.enabled) ...[
          _hour('خلاصه‌ی صبح', d.morningHour, [5, 6, 7, 8, 9, 10, 11],
              (h) => _set(DigestTimes(enabled: true, morningHour: h, eveningHour: d.eveningHour))),
          _hour('مرور شب', d.eveningHour, [18, 19, 20, 21, 22, 23],
              (h) => _set(DigestTimes(enabled: true, morningHour: d.morningHour, eveningHour: h))),
        ],
        const SizedBox(height: 6),
        if (Reminders.supported)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('اعلان آزمایشی'),
              onPressed: () async {
                await Reminders.instance.askPermission();
                await Reminders.instance.showTest();
              },
            ),
          )
        else
          const Text('اعلان‌ها روی اندروید و ویندوز کار می‌کنند.', style: TextStyle(color: Loomi.muted, fontSize: 13)),
      ]),
    );
  }
}
