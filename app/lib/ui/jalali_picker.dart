// A Persian (Jalali) date picker: month grid starting on Saturday, Persian digits,
// quick «امروز» / «فردا» / «هفته‌ی بعد». Returns a local midnight DateTime.
import 'package:material_ui/material_ui.dart';

import '../fa/dates.dart';
import 'theme.dart';

Future<DateTime?> showJalaliDatePicker(BuildContext context, {DateTime? initial}) => showDialog<DateTime>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Loomi.ink2,
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380), child: JalaliCalendar(initial: initial ?? DateTime.now())),
      ),
    );

class JalaliCalendar extends StatefulWidget {
  const JalaliCalendar({super.key, required this.initial});
  final DateTime initial;
  @override
  State<JalaliCalendar> createState() => _JalaliCalendarState();
}

class _JalaliCalendarState extends State<JalaliCalendar> {
  late final _sel = toJalali(widget.initial);
  late int _y = _sel.jy, _m = _sel.jm;
  static const _heads = ['ش', 'ی', 'د', 'س', 'چ', 'پ', 'ج'];

  void _shift(int by) => setState(() {
        _m += by;
        if (_m > 12) { _m = 1; _y++; }
        if (_m < 1) { _m = 12; _y--; }
      });

  void _pick(DateTime d) => Navigator.pop(context, DateTime(d.year, d.month, d.day));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final first = toGregorian(_y, _m, 1);
    final lead = (first.weekday + 1) % 7; // Saturday = 0
    final days = jalaliMonthLength(_y, _m);
    final today = DateTime.now();
    final todayJ = toJalali(today);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          IconButton(tooltip: 'ماه قبل', onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_right_rounded)),
          Expanded(child: Text('${jalaliMonths[_m - 1]} ${faDigits(_y)}', textAlign: TextAlign.center, style: t.titleLarge)),
          IconButton(tooltip: 'ماه بعد', onPressed: () => _shift(1), icon: const Icon(Icons.chevron_left_rounded)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          for (final h in _heads)
            Expanded(child: Text(h, textAlign: TextAlign.center, style: TextStyle(color: h == 'ج' ? Loomi.danger.withValues(alpha: .8) : Loomi.muted, fontSize: 13))),
        ]),
        const SizedBox(height: 6),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          children: [
            for (var i = 0; i < lead; i++) const SizedBox(),
            for (var d = 1; d <= days; d++) _day(d, isToday: todayJ.jy == _y && todayJ.jm == _m && todayJ.jd == d,
                isSel: _sel.jy == _y && _sel.jm == _m && _sel.jd == d, friday: (lead + d - 1) % 7 == 6),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
          ActionChip(label: const Text('امروز'), onPressed: () => _pick(today)),
          ActionChip(label: const Text('فردا'), onPressed: () => _pick(today.add(const Duration(days: 1)))),
          ActionChip(label: const Text('هفته‌ی بعد'), onPressed: () => _pick(today.add(const Duration(days: 7)))),
        ]),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        ),
      ]),
    );
  }

  Widget _day(int d, {required bool isToday, required bool isSel, required bool friday}) => InkWell(
        key: ValueKey('jday-$d'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => _pick(toGregorian(_y, _m, d)),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: isSel ? Loomi.gradient : null,
            borderRadius: BorderRadius.circular(12),
            border: isToday && !isSel ? Border.all(color: Loomi.violet, width: 1.4) : null,
          ),
          child: Text(faDigits(d),
              style: TextStyle(
                fontWeight: isSel || isToday ? FontWeight.w700 : FontWeight.w400,
                color: isSel ? Colors.white : friday ? Loomi.danger.withValues(alpha: .85) : Loomi.text,
              )),
        ),
      );
}
