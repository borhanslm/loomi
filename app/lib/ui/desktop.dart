// Desktop layout (wide windows): sidebar navigation with counts (type lists are filter chips in Everything), the capture box at
// the top of the page (Ctrl+K), Today in two columns, and item details in a side panel.
// Keyboard: Ctrl+K / Ctrl+N capture · Ctrl+1 Today · Ctrl+2 Everything · Ctrl+3 Devices · Esc closes the panel.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../api/loomi_api.dart';
import '../fa/dates.dart';
import '../local/items_store.dart';
import '../local/session.dart';
import 'items_ui.dart';
import 'theme.dart';
import 'update_banner.dart';

/// What the main area shows: Today, Everything, one item type, or Devices.
class DeskView {
  const DeskView._(this.id, {this.type});
  static const today = DeskView._('today');
  static const all = DeskView._('all');
  static const devices = DeskView._('devices');
  factory DeskView.type(ItemType t) => DeskView._('type:${t.name}', type: t);
  final String id;
  final ItemType? type;
  @override
  bool operator ==(Object other) => other is DeskView && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key, required this.session, required this.live, required this.devicesView, required this.greeting});
  final Session session;
  final bool live;
  final Widget devicesView;
  final String greeting;
  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  DeskView _view = DeskView.today;
  String? _selectedId;
  final _capture = TextEditingController();
  final _captureFocus = FocusNode();

  @override
  void dispose() {
    _capture.dispose();
    _captureFocus.dispose();
    super.dispose();
  }

  void _go(DeskView v) => setState(() { _view = v; _selectedId = null; });
  void _open(Item i) => setState(() => _selectedId = _selectedId == i.id ? null : i.id);
  void _focusCapture() => _captureFocus.requestFocus();
  void _prefill(String text) {
    _capture.text = text;
    _capture.selection = TextSelection.collapsed(offset: text.length);
    _focusCapture();
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(itemsProvider).items;
    final selected = _selectedId == null ? null : items.where((i) => i.id == _selectedId).firstOrNull;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _focusCapture,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _focusCapture,
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () => _go(DeskView.today),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () => _go(DeskView.all),
        const SingleActivator(LogicalKeyboardKey.digit3, control: true): () => _go(DeskView.devices),
        const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _selectedId = null),
      },
      child: Focus(
        autofocus: true,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Sidebar(view: _view, onGo: _go, onCapture: _focusCapture, live: widget.live, server: widget.session.url),
          Expanded(
            child: _view == DeskView.devices
                ? Padding(padding: const EdgeInsets.fromLTRB(24, 18, 24, 0), child: widget.devicesView)
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Padding(padding: EdgeInsets.fromLTRB(32, 14, 32, 0), child: UpdateBanner()),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 10, 32, 14),
                      child: _Header(view: _view, greeting: widget.greeting, count: _countFor(_view, items)),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: _Composer(controller: _capture, focus: _captureFocus),
                    ),
                    Expanded(
                      child: _view == DeskView.today
                          ? _TodayDesk(onOpen: _open, selectedId: _selectedId, onExample: _prefill)
                          : _ListDesk(view: _view, onGo: _go, onOpen: _open, selectedId: _selectedId, onExample: _prefill),
                    ),
                  ]),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (c, a) => SizeTransition(sizeFactor: a, axis: Axis.horizontal, child: c),
            child: selected == null
                ? const SizedBox.shrink()
                : _DetailPanel(key: ValueKey(selected.id), item: selected, onClose: () => setState(() => _selectedId = null)),
          ),
        ]),
      ),
    );
  }
}

int _countFor(DeskView v, List<Item> items) {
  final open = items.where((i) => !i.done);
  if (v.type != null) return open.where((i) => i.type == v.type).length;
  return open.length;
}

// ── sidebar ──────────────────────────────────────────────────────────

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.view, required this.onGo, required this.onCapture, required this.live, required this.server});
  final DeskView view;
  final void Function(DeskView) onGo;
  final VoidCallback onCapture;
  final bool live;
  final String server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(itemsProvider).items;
    final now = DateTime.now();
    final open = items.where((i) => !i.done).toList();
    final todayCount = open.where((i) => i.dueAt != null && (sameDay(i.dueAt!, now) || i.dueAt!.isBefore(now))).length;
    final host = Uri.tryParse(server)?.host ?? server;
    return Container(
      width: 252,
      margin: const EdgeInsets.fromLTRB(0, 6, 12, 12),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          GradientButton(label: 'ثبت سریع', icon: Icons.add_rounded, onPressed: onCapture),
          const SizedBox(height: 6),
          const Center(child: _Kbd('Ctrl + K')),
          const SizedBox(height: 18),
          _NavItem(icon: Icons.wb_sunny_outlined, label: 'امروز', count: todayCount, hint: 'Ctrl 1', selected: view == DeskView.today, onTap: () => onGo(DeskView.today)),
          // the type lists (tasks, shopping…) live inside «همه‌چیز» as filters, so the sidebar stays free
          _NavItem(icon: Icons.inventory_2_outlined, label: 'همه‌چیز', count: open.length, hint: 'Ctrl 2', selected: view == DeskView.all || view.type != null, onTap: () => onGo(DeskView.all)),
          const Spacer(),
          _NavItem(icon: Icons.tune_rounded, label: 'تنظیمات', hint: 'Ctrl 3', selected: view == DeskView.devices, onTap: () => onGo(DeskView.devices)),
          const Divider(height: 22),
          Row(children: [
            StatusPill(online: live),
            const SizedBox(width: 8),
            Expanded(child: Text(host, textDirection: TextDirection.ltr, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Loomi.muted, fontSize: 12))),
          ]),
        ]),
      ),
    );
  }
}

String _plural(ItemType t) => switch (t) {
      ItemType.task => 'کارها',
      ItemType.reminder => 'یادآورها',
      ItemType.shopping => 'خرید',
      ItemType.idea => 'ایده‌ها',
      ItemType.note => 'یادداشت‌ها',
      ItemType.event => 'قرارها',
    };

class _NavItem extends StatefulWidget {
  const _NavItem({required this.icon, required this.label, required this.selected, required this.onTap, this.count, this.hint});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;
  final String? hint;
  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Semantics(
          button: true,
          selected: sel,
          label: widget.label,
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                gradient: sel ? LinearGradient(colors: [Loomi.violet.withValues(alpha: .38), Loomi.cyan.withValues(alpha: .12)], begin: AlignmentDirectional.centerStart, end: AlignmentDirectional.centerEnd) : null,
                color: sel ? null : (_hover ? const Color(0x12FFFFFF) : Colors.transparent),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: sel ? Loomi.violetSoft.withValues(alpha: .25) : Colors.transparent),
              ),
              child: Row(children: [
                Icon(widget.icon, size: 20, color: sel ? Colors.white : Loomi.muted),
                const SizedBox(width: 12),
                Expanded(child: Text(widget.label, style: TextStyle(color: sel || _hover ? Loomi.text : Loomi.muted, fontWeight: sel ? FontWeight.w700 : FontWeight.w500, fontSize: 14.5))),
                if (_hover && widget.hint != null && !sel)
                  _Kbd(widget.hint!)
                else if ((widget.count ?? 0) > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                    decoration: BoxDecoration(color: sel ? Colors.white.withValues(alpha: .18) : const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(99)),
                    child: Text(faDigits(widget.count!), style: TextStyle(fontSize: 12, color: sel ? Colors.white : Loomi.muted, fontWeight: FontWeight.w600)),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Kbd extends StatelessWidget {
  const _Kbd(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        decoration: BoxDecoration(border: Border.all(color: Loomi.glassBorder), borderRadius: BorderRadius.circular(6), color: const Color(0x0AFFFFFF)),
        child: Text(text, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 11, color: Loomi.muted, fontFamily: 'Consolas')),
      );
}

// ── header + composer ────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.view, required this.greeting, required this.count});
  final DeskView view;
  final String greeting;
  final int count;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final (title, sub) = view == DeskView.today
        ? (greeting, longDate(DateTime.now()))
        : view == DeskView.all
            ? ('همه‌چیز', '${faDigits(count)} مورد باز')
            : (_plural(view.type!), '${faDigits(count)} مورد باز');
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(sub, style: t.bodyMedium?.copyWith(color: Loomi.violetSoft, fontWeight: FontWeight.w600)),
        Text(title, style: t.headlineMedium?.copyWith(fontSize: 30)),
      ]),
    ]);
  }
}

class _Composer extends ConsumerStatefulWidget {
  const _Composer({required this.controller, required this.focus});
  final TextEditingController controller;
  final FocusNode focus;
  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  bool _busy = false, _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(() { if (mounted) setState(() => _focused = widget.focus.hasFocus); });
  }

  Future<void> _send() async {
    final text = widget.controller.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    widget.controller.clear();
    await submitCapture(context, ref, text);
    if (mounted) setState(() => _busy = false);
    widget.focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: _focused ? [BoxShadow(color: Loomi.violet.withValues(alpha: .28), blurRadius: 28, spreadRadius: 1)] : const [],
        ),
        child: GlassCard(
          highlight: _focused,
          padding: const EdgeInsets.fromLTRB(10, 8, 18, 8),
          child: Row(children: [
            const Icon(Icons.auto_awesome_rounded, color: Loomi.violetSoft, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: CallbackShortcuts(
                bindings: {const SingleActivator(LogicalKeyboardKey.enter): _send},
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focus,
                  minLines: 1,
                  maxLines: 4,
                  style: const TextStyle(fontSize: 16),
                  decoration: const InputDecoration(
                    hintText: 'چی تو ذهنته؟ هر چیزی بنویس — لومی مرتبش می‌کند',
                    filled: false, border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),
            if (!_busy) ...[const _Kbd('Enter'), const SizedBox(width: 10)],
            Tooltip(
              message: 'ثبت (Enter) · خط تازه: Shift+Enter',
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _busy ? null : _send,
                child: Container(
                  width: 46, height: 46,
                  decoration: BoxDecoration(gradient: Loomi.gradient, borderRadius: BorderRadius.circular(14)),
                  child: _busy
                      ? const Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                      : const Icon(Icons.arrow_upward_rounded, color: Colors.white),
                ),
              ),
            ),
          ]),
        ),
      );
}

// ── views ────────────────────────────────────────────────────────────

class _Examples extends StatelessWidget {
  const _Examples({required this.onPick});
  final void Function(String) onPick;
  @override
  Widget build(BuildContext context) => Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
        for (final e in captureExamples)
          ActionChip(
            avatar: const Icon(Icons.north_west_rounded, size: 16, color: Loomi.violetSoft),
            label: Text(e),
            onPressed: () => onPick(e),
          ),
      ]);
}

class _TodayDesk extends ConsumerWidget {
  const _TodayDesk({required this.onOpen, required this.selectedId, required this.onExample});
  final void Function(Item) onOpen;
  final String? selectedId;
  final void Function(String) onExample;

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
    final ideas = open.where((i) => i.type == ItemType.idea).take(5).toList();
    final doneToday = s.items.where((i) => i.done && sameDay(i.createdAt, now)).toList();
    final nothing = [overdue, today, soon, shopping, todo, ideas].every((l) => l.isEmpty) && s.pending.isEmpty;
    ItemSection sec(String t, List<Item> l, IconData ic, Color c) => ItemSection(t, l, icon: ic, color: c, onOpen: onOpen, selectedId: selectedId);

    return RefreshIndicator(
      onRefresh: ref.read(itemsProvider.notifier).refresh,
      color: Loomi.violet,
      child: LayoutBuilder(builder: (context, c) {
        final twoCols = c.maxWidth >= 860;
        // Non-empty sections in priority order, placed into whichever column is shorter so the page stays balanced.
        final sections = <(ItemSection, int)>[
          (sec('عقب افتاده', overdue, Icons.priority_high_rounded, Loomi.danger), overdue.length),
          (sec('امروز', today, Icons.today_rounded, Loomi.cyan), today.length),
          (sec('خرید', shopping, Icons.shopping_bag_outlined, Loomi.ok), shopping.length),
          (sec('کارها', todo, Icons.checklist_rounded, Loomi.violetSoft), todo.length),
          (sec('هفت روز آینده', soon, Icons.date_range_rounded, Loomi.violetSoft), soon.length),
          (sec('ایده‌های تازه', ideas, Icons.lightbulb_outline_rounded, const Color(0xFFFFD66B)), ideas.length),
          (sec('امروز انجام شد', doneToday, Icons.done_all_rounded, Loomi.ok), doneToday.length),
        ].where((e) => e.$2 > 0).toList();
        final left = <Widget>[], right = <Widget>[];
        var hl = 0, hr = 0;
        for (final (w, n) in sections) {
          if (hl <= hr) { left.add(w); hl += n + 1; } else { right.add(w); hr += n + 1; }
        }
        return ListView(padding: const EdgeInsets.fromLTRB(32, 6, 32, 32), children: [
          const PendingList(),
          if (s.error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(s.error!, style: const TextStyle(color: Loomi.danger))),
          if (nothing)
            EmptyState(
              title: 'ذهنت آزاد است',
              body: 'هر چیزی که باید یادت بماند را بالا بنویس؛ لومی مرتبش می‌کند.\nیکی از این‌ها را امتحان کن:',
              extra: _Examples(onPick: onExample),
            )
          else if (twoCols)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left)),
              const SizedBox(width: 24),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
            ])
          else
            ...[...left, ...right],
        ]);
      }),
    );
  }
}

class _ListDesk extends ConsumerStatefulWidget {
  const _ListDesk({required this.view, required this.onGo, required this.onOpen, required this.selectedId, required this.onExample});
  final DeskView view;
  final void Function(DeskView) onGo;
  final void Function(Item) onOpen;
  final String? selectedId;
  final void Function(String) onExample;
  @override
  ConsumerState<_ListDesk> createState() => _ListDeskState();
}

class _ListDeskState extends ConsumerState<_ListDesk> {
  String _q = '';
  bool _showDone = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(itemsProvider);
    final type = widget.view.type;
    final q = _q.trim().toLowerCase();
    final list = s.items.where((i) {
      if (!_showDone && i.done) return false;
      if (type != null && i.type != type) return false;
      if (q.isEmpty) return true;
      return '${i.title} ${i.notes ?? ''} ${i.people.join(' ')} ${i.place ?? ''}'.toLowerCase().contains(q);
    }).toList();
    return RefreshIndicator(
      onRefresh: ref.read(itemsProvider.notifier).refresh,
      color: Loomi.violet,
      child: ListView(padding: const EdgeInsets.fromLTRB(32, 6, 32, 32), children: [
        Row(children: [
          Expanded(
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(hintText: type == null ? 'جست‌وجو در همه‌چیز… (مثلاً «علی» یا «کافه»)' : 'جست‌وجو در ${_plural(type)}…', prefixIcon: const Icon(Icons.search_rounded)),
            ),
          ),
          const SizedBox(width: 12),
          FilterChip(label: const Text('نمایش انجام‌شده‌ها'), selected: _showDone, onSelected: (v) => setState(() => _showDone = v)),
        ]),
        const SizedBox(height: 12),
        _TypeFilter(selected: type, onPick: (t) => widget.onGo(t == null ? DeskView.all : DeskView.type(t))),
        const SizedBox(height: 16),
        if (list.isEmpty)
          EmptyState(
            title: q.isEmpty ? 'این فهرست خالی است' : 'چیزی پیدا نشد',
            body: q.isEmpty ? 'هر چیزی بنویسی، لومی خودش در فهرست درست می‌گذارد.' : 'جست‌وجو را عوض کنید.',
            extra: q.isEmpty ? _Examples(onPick: widget.onExample) : null,
          ),
        for (final i in list) ItemTile(item: i, onOpen: () => widget.onOpen(i), selected: i.id == widget.selectedId),
      ]),
    );
  }
}

/// «همه / کارها / یادآورها / خرید / …» with open counts — one row instead of six sidebar entries.
class _TypeFilter extends ConsumerWidget {
  const _TypeFilter({required this.selected, required this.onPick});
  final ItemType? selected;
  final void Function(ItemType?) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(itemsProvider).items.where((i) => !i.done).toList();
    Widget chip(ItemType? t) {
      final st = t == null ? null : typeStyle(t);
      final n = t == null ? open.length : open.where((i) => i.type == t).length;
      final on = selected == t;
      return ChoiceChip(
        key: ValueKey('filter-${t?.name ?? 'all'}'),
        avatar: Icon(st?.icon ?? Icons.inventory_2_outlined, size: 18, color: on ? Colors.white : st?.color ?? Loomi.violetSoft),
        label: Text(n > 0 ? '${t == null ? 'همه' : _plural(t)}  ${faDigits(n)}' : (t == null ? 'همه' : _plural(t))),
        selected: on,
        showCheckmark: false,
        selectedColor: Loomi.violet.withValues(alpha: .55),
        onSelected: (_) => onPick(t),
      );
    }

    return Wrap(spacing: 8, runSpacing: 8, children: [chip(null), for (final t in ItemType.values) chip(t)]);
  }
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({super.key, required this.item, required this.onClose});
  final Item item;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final st = typeStyle(item.type);
    return Container(
      width: 380,
      margin: const EdgeInsets.fromLTRB(12, 6, 0, 12),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(color: st.color.withValues(alpha: .16), borderRadius: BorderRadius.circular(12)),
                child: Icon(st.icon, color: st.color, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(st.label, style: const TextStyle(color: Loomi.muted, fontWeight: FontWeight.w600))),
              IconButton(tooltip: 'بستن (Esc)', onPressed: onClose, icon: const Icon(Icons.close_rounded, color: Loomi.muted)),
            ]),
            const SizedBox(height: 12),
            ItemEditor(item: item, onClose: onClose),
            const SizedBox(height: 18),
            Text('ساخته شده: ${whenLabel(item.createdAt, allDay: false)}', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}
