// The second brain on screen: capture bar, «امروز», «همه‌چیز», item tiles and the edit sheet.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../api/loomi_api.dart';
import '../fa/dates.dart';
import '../local/items_store.dart';
import 'theme.dart';

({IconData icon, Color color, String label}) typeStyle(ItemType t) => switch (t) {
      ItemType.task => (icon: Icons.check_circle_outline_rounded, color: Loomi.violetSoft, label: 'کار'),
      ItemType.reminder => (icon: Icons.notifications_active_outlined, color: Loomi.amber, label: 'یادآور'),
      ItemType.shopping => (icon: Icons.shopping_bag_outlined, color: Loomi.ok, label: 'خرید'),
      ItemType.idea => (icon: Icons.lightbulb_outline_rounded, color: Color(0xFFFFD66B), label: 'ایده'),
      ItemType.note => (icon: Icons.sticky_note_2_outlined, color: Loomi.muted, label: 'یادداشت'),
      ItemType.event => (icon: Icons.event_rounded, color: Loomi.cyan, label: 'قرار'),
    };

// ── capture ───────────────────────────────────────────────────────────

/// Send a capture and tell the user what Loomi made of it.
Future<void> submitCapture(BuildContext context, WidgetRef ref, String text) async {
  final m = ScaffoldMessenger.of(context);
  // On wide screens keep the notice compact instead of stretching across the window.
  final width = MediaQuery.sizeOf(context).width >= 900 ? 460.0 : null;
  final r = await ref.read(itemsProvider.notifier).capture(text);
  m.hideCurrentSnackBar();
  String msg;
  if (r == null) {
    msg = 'ذخیره شد؛ به سرور که وصل شد، لومی آن را مرتب می‌کند.';
  } else {
    final kinds = r.items.map((i) => typeStyle(i.type).label).toSet().join('، ');
    final note = r.warning != null ? '\n${r.warning}' : '';
    msg = r.items.isEmpty ? 'چیزی برای ذخیره پیدا نشد.' : '${faDigits(r.items.length)} مورد ساخته شد: $kinds$note';
  }
  m.showSnackBar(SnackBar(content: Text(msg), width: width));
}

/// Example sentences shown when the list is empty — tap to try one.
const captureExamples = [
  'فردا ساعت ۱۰ جلسه با علی، قبلش قرارداد رو چاپ کنم',
  'یه ساعت دیگه یادم بنداز به مامان زنگ بزنم',
  'شیر و نون و تخم‌مرغ بخرم',
  'ایده: یه کافه کتاب کنار دانشگاه',
];

class CaptureBar extends ConsumerStatefulWidget {
  const CaptureBar({super.key});
  @override
  ConsumerState<CaptureBar> createState() => _CaptureBarState();
}

class _CaptureBarState extends ConsumerState<CaptureBar> {
  final _c = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _c.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    HapticFeedback.lightImpact();
    _c.clear();
    await submitCapture(context, ref, text);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: GlassCard(
          padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _c,
                focusNode: _focus,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: 'چی تو ذهنته؟ مثلاً «فردا ساعت ۵ یادم بنداز نون بخرم»',
                  filled: false, border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Semantics(
              button: true,
              label: 'ثبت',
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _busy ? null : _send,
                child: Container(
                  width: 50, height: 50,
                  decoration: BoxDecoration(gradient: Loomi.gradient, borderRadius: BorderRadius.circular(16)),
                  child: _busy
                      ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                      : const Icon(Icons.arrow_upward_rounded, color: Colors.white),
                ),
              ),
            ),
          ]),
        ),
      );
}

// ── one item ─────────────────────────────────────────────────────────

class ItemTile extends ConsumerWidget {
  const ItemTile({super.key, required this.item, this.onOpen, this.selected = false});
  final Item item;
  /// Desktop opens the side panel; phones (null) open the bottom sheet.
  final VoidCallback? onOpen;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = typeStyle(item.type);
    final t = Theme.of(context).textTheme;
    final overdue = !item.done && item.dueAt != null && item.dueAt!.isBefore(DateTime.now()) && !(item.allDay && sameDay(item.dueAt!, DateTime.now()));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey('item-${item.id}'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: AlignmentDirectional.centerEnd,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          decoration: BoxDecoration(color: Loomi.danger.withValues(alpha: .18), borderRadius: BorderRadius.circular(Loomi.radius)),
          child: const Icon(Icons.delete_outline_rounded, color: Loomi.danger),
        ),
        onDismissed: (_) {
          ref.read(itemsProvider.notifier).remove(item);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('«${item.title}» حذف شد.')));
        },
        child: GlassCard(
          padding: EdgeInsets.zero,
          highlight: selected,
          child: InkWell(
            borderRadius: BorderRadius.circular(Loomi.radius),
            hoverColor: Colors.white.withValues(alpha: .04),
            onTap: onOpen ?? () => showEditSheet(context, item),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
              child: Row(children: [
                IconButton(
                  tooltip: item.done ? 'برگرداندن' : 'انجام شد',
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    ref.read(itemsProvider.notifier).setDone(item, !item.done);
                  },
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: item.done
                        ? const Icon(Icons.check_circle_rounded, key: ValueKey(1), color: Loomi.ok, size: 28)
                        : Icon(Icons.radio_button_unchecked_rounded, key: const ValueKey(0), color: st.color.withValues(alpha: .8), size: 28),
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(item.title,
                        style: t.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          decoration: item.done ? TextDecoration.lineThrough : null,
                          color: item.done ? Loomi.muted : Loomi.text,
                        )),
                    const SizedBox(height: 4),
                    Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      _Chip(icon: st.icon, text: st.label, color: st.color),
                      if (item.dueAt != null)
                        _Chip(icon: Icons.schedule_rounded, text: whenLabel(item.dueAt!, allDay: item.allDay), color: overdue ? Loomi.danger : Loomi.violetSoft),
                      for (final p in item.people) _Chip(icon: Icons.person_outline_rounded, text: p, color: Loomi.muted),
                      if (item.place != null) _Chip(icon: Icons.place_outlined, text: item.place!, color: Loomi.muted),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w500)),
        ]),
      );
}

// ── edit sheet ───────────────────────────────────────────────────────

Future<void> showEditSheet(BuildContext context, Item item) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Loomi.ink2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 14, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 44, height: 5, decoration: BoxDecoration(color: Loomi.glassBorder, borderRadius: BorderRadius.circular(9))),
          const SizedBox(height: 16),
          ItemEditor(item: item, onClose: () => Navigator.pop(ctx)),
        ]),
      ),
    );

/// Edit one item: title, type, time; or delete it. Used in the phone sheet and the desktop panel.
class ItemEditor extends ConsumerStatefulWidget {
  const ItemEditor({super.key, required this.item, required this.onClose});
  final Item item;
  final VoidCallback onClose;
  @override
  ConsumerState<ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends ConsumerState<ItemEditor> {
  late final _title = TextEditingController(text: widget.item.title);

  @override
  void didUpdateWidget(ItemEditor old) {
    super.didUpdateWidget(old);
    if (old.item.id != widget.item.id) {
      _title.text = widget.item.title;
      _type = widget.item.type;
      _due = widget.item.dueAt;
      _allDay = widget.item.allDay;
    }
  }
  late ItemType _type = widget.item.type;
  late DateTime? _due = widget.item.dueAt;
  late bool _allDay = widget.item.allDay;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: _due ?? now, firstDate: now.subtract(const Duration(days: 365)), lastDate: now.add(const Duration(days: 3650)));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: _due != null && !_allDay ? TimeOfDay.fromDateTime(_due!) : const TimeOfDay(hour: 9, minute: 0));
    setState(() {
      _allDay = t == null;
      _due = DateTime(d.year, d.month, d.day, t?.hour ?? 9, t?.minute ?? 0);
    });
  }

  Future<void> _save() async {
    final n = ref.read(itemsProvider.notifier);
    final it = widget.item;
    final title = _title.text.trim();
    await n.edit(it,
        title: title.isNotEmpty && title != it.title ? title : null,
        type: _type != it.type ? _type : null,
        dueAt: _due != it.dueAt ? _due : null,
        clearDue: _due == null && it.dueAt != null,
        allDay: _allDay != it.allDay ? _allDay : null);
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('ویرایش', style: t.titleLarge),
        const SizedBox(height: 14),
        TextField(controller: _title, decoration: const InputDecoration(labelText: 'عنوان'), maxLength: 200),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final ty in ItemType.values)
            ChoiceChip(
              label: Text(typeStyle(ty).label),
              avatar: Icon(typeStyle(ty).icon, size: 18, color: typeStyle(ty).color),
              selected: _type == ty,
              onSelected: (_) => setState(() => _type = ty),
            ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _pickDue,
              icon: const Icon(Icons.schedule_rounded),
              label: Text(_due == null ? 'زمان ندارد' : whenLabel(_due!, allDay: _allDay)),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50), foregroundColor: Loomi.text, side: const BorderSide(color: Loomi.glassBorder)),
            ),
          ),
          if (_due != null)
            IconButton(tooltip: 'بدون زمان', onPressed: () => setState(() => _due = null), icon: const Icon(Icons.close_rounded, color: Loomi.muted)),
        ]),
        const SizedBox(height: 18),
        GradientButton(label: 'ذخیره', icon: Icons.check_rounded, onPressed: _save),
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: () {
            ref.read(itemsProvider.notifier).remove(widget.item);
            widget.onClose();
          },
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('حذف'),
          style: TextButton.styleFrom(foregroundColor: Loomi.danger),
        ),
      ]);
  }
}

// ── views ────────────────────────────────────────────────────────────

class ItemSection extends StatelessWidget {
  const ItemSection(this.title, this.items, {super.key, this.icon, this.color, this.onOpen, this.selectedId});
  final String title;
  final List<Item> items;
  final IconData? icon;
  final Color? color;
  final void Function(Item)? onOpen;
  final String? selectedId;
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 18, 6, 10),
        child: Row(children: [
          if (icon != null) ...[Icon(icon, size: 18, color: color ?? Loomi.violetSoft), const SizedBox(width: 8)],
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 8),
          Text(faDigits(items.length), style: const TextStyle(color: Loomi.muted)),
        ]),
      ),
      for (final i in items) ItemTile(item: i, onOpen: onOpen == null ? null : () => onOpen!(i), selected: i.id == selectedId),
    ]);
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, required this.body, this.extra});
  final Widget? extra;
  final String title, body;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(children: [
          const LoomiLogo(size: 64, glow: false),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(body, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
          if (extra != null) ...[const SizedBox(height: 18), extra!],
        ]),
      );
}

class PendingList extends ConsumerWidget {
  const PendingList({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(itemsProvider.select((s) => s.pending));
    if (pending.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Loomi.amber)),
            SizedBox(width: 10),
            Text('در صف مرتب شدن', style: TextStyle(color: Loomi.amber, fontWeight: FontWeight.w600)),
          ]),
          for (final p in pending) Padding(padding: const EdgeInsets.only(top: 6), child: Text('«${p.text}»', style: const TextStyle(color: Loomi.muted))),
        ]),
      ),
    );
  }
}

class TodayView extends ConsumerWidget {
  const TodayView({super.key, required this.header});
  final Widget header;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(itemsProvider);
    final now = DateTime.now();
    final endOfToday = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final open = s.items.where((i) => !i.done).toList();
    final overdue = open.where((i) => i.dueAt != null && i.dueAt!.isBefore(now) && !sameDay(i.dueAt!, now)).toList();
    final today = open.where((i) => i.dueAt != null && sameDay(i.dueAt!, now)).toList();
    final soon = open.where((i) => i.dueAt != null && !i.dueAt!.isBefore(endOfToday) && i.dueAt!.isBefore(endOfToday.add(const Duration(days: 7)))).toList();
    final shopping = open.where((i) => i.type == ItemType.shopping && i.dueAt == null).toList();
    final todo = open.where((i) => i.dueAt == null && (i.type == ItemType.task || i.type == ItemType.reminder)).toList();
    final doneToday = s.items.where((i) => i.done && sameDay(i.createdAt, now)).toList();
    final nothing = [overdue, today, soon, shopping, todo].every((l) => l.isEmpty);
    return RefreshIndicator(
      onRefresh: ref.read(itemsProvider.notifier).refresh,
      color: Loomi.violet,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        header,
        const PendingList(),
        if (s.error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(s.error!, style: const TextStyle(color: Loomi.danger))),
        if (nothing && s.pending.isEmpty)
          const EmptyState(title: 'ذهنت آزاد است', body: 'هر چیزی که باید یادت بماند را پایین بنویس؛\nلومی مرتبش می‌کند.'),
        ItemSection('عقب افتاده', overdue, icon: Icons.priority_high_rounded, color: Loomi.danger),
        ItemSection('امروز', today, icon: Icons.today_rounded, color: Loomi.cyan),
        ItemSection('خرید', shopping, icon: Icons.shopping_bag_outlined, color: Loomi.ok),
        ItemSection('کارها', todo, icon: Icons.checklist_rounded),
        ItemSection('هفت روز آینده', soon, icon: Icons.date_range_rounded, color: Loomi.violetSoft),
        ItemSection('امروز انجام شد', doneToday, icon: Icons.done_all_rounded, color: Loomi.ok),
      ]),
    );
  }
}

class AllView extends ConsumerStatefulWidget {
  const AllView({super.key});
  @override
  ConsumerState<AllView> createState() => _AllViewState();
}

class _AllViewState extends ConsumerState<AllView> {
  String _q = '';
  ItemType? _type;
  bool _showDone = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(itemsProvider);
    final q = _q.trim().toLowerCase();
    final list = s.items.where((i) {
      if (!_showDone && i.done) return false;
      if (_type != null && i.type != _type) return false;
      if (q.isEmpty) return true;
      return '${i.title} ${i.notes ?? ''} ${i.people.join(' ')} ${i.place ?? ''}'.toLowerCase().contains(q);
    }).toList();
    return RefreshIndicator(
      onRefresh: ref.read(itemsProvider.notifier).refresh,
      color: Loomi.violet,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Text('همه‌چیز', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 12),
        TextField(
          onChanged: (v) => setState(() => _q = v),
          decoration: const InputDecoration(hintText: 'جست‌وجو… مثلاً «کافه» یا «علی»', prefixIcon: Icon(Icons.search_rounded)),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            FilterChip(label: const Text('همه'), selected: _type == null, onSelected: (_) => setState(() => _type = null)),
            for (final ty in ItemType.values)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 8),
                child: FilterChip(
                  avatar: Icon(typeStyle(ty).icon, size: 18, color: typeStyle(ty).color),
                  label: Text(typeStyle(ty).label),
                  selected: _type == ty,
                  onSelected: (_) => setState(() => _type = _type == ty ? null : ty),
                ),
              ),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 8),
              child: FilterChip(label: const Text('انجام‌شده‌ها'), selected: _showDone, onSelected: (v) => setState(() => _showDone = v)),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        if (list.isEmpty) const EmptyState(title: 'چیزی پیدا نشد', body: 'جست‌وجو یا فیلتر را عوض کنید.'),
        for (final i in list) ItemTile(item: i),
      ]),
    );
  }
}
