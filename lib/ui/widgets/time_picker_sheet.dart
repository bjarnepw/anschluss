import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';

/// Result of the time picker: `when == null` means "now".
typedef TimeChoice = ({DateTime? when, bool arriveBy});

/// Bottom sheet with depart/arrive, quick day chips, a 1-minute time wheel and ±15 min / +1 h steps.
Future<TimeChoice?> showTimePickerSheet(BuildContext context, {DateTime? initial, required bool arriveBy}) {
  return showModalBottomSheet<TimeChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _TimeSheet(initial: initial, arriveBy: arriveBy),
  );
}

class _TimeSheet extends StatefulWidget {
  final DateTime? initial;
  final bool arriveBy;
  const _TimeSheet({this.initial, required this.arriveBy});

  @override
  State<_TimeSheet> createState() => _TimeSheetState();
}

class _TimeSheetState extends State<_TimeSheet> {
  late DateTime _t = widget.initial ?? DateTime.now();
  late bool _arriveBy = widget.arriveBy;
  var _wheelKey = 0; // rebuild the wheel when the time is changed by the buttons

  DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  void _set(DateTime t) => setState(() {
    _t = t;
    _wheelKey++;
  });

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final cs = Theme.of(context).colorScheme;
    final today = _day(DateTime.now());
    final days = List.generate(7, (i) => today.add(Duration(days: i)));
    String dayLabel(DateTime d, int i) => switch (i) {
      0 => s.de ? 'Heute' : 'Today',
      1 => s.de ? 'Morgen' : 'Tomorrow',
      _ => fmtDate(d, s.de),
    };

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: false, label: Text(s.de ? 'Abfahrt' : 'Depart'), icon: const Icon(Icons.logout)),
                ButtonSegment(value: true, label: Text(s.de ? 'Ankunft' : 'Arrive'), icon: const Icon(Icons.login)),
              ],
              selected: {_arriveBy},
              onSelectionChanged: (v) => setState(() => _arriveBy = v.first),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < days.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(dayLabel(days[i], i)),
                        selected: _day(_t) == days[i],
                        onSelected: (_) => _set(DateTime(days[i].year, days[i].month, days[i].day, _t.hour, _t.minute)),
                      ),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.calendar_month, size: 18),
                    label: Text(s.de ? 'Datum…' : 'Date…'),
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _t,
                        firstDate: today.subtract(const Duration(days: 1)),
                        lastDate: today.add(const Duration(days: 365)),
                      );
                      if (d != null) _set(DateTime(d.year, d.month, d.day, _t.hour, _t.minute));
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 180,
              child: CupertinoTheme(
                data: CupertinoThemeData(
                  brightness: Theme.of(context).brightness,
                  textTheme: CupertinoTextThemeData(dateTimePickerTextStyle: TextStyle(fontSize: 24, color: cs.onSurface)),
                ),
                child: CupertinoDatePicker(
                  key: ValueKey(_wheelKey),
                  mode: CupertinoDatePickerMode.time,
                  use24hFormat: true,
                  initialDateTime: _t,
                  onDateTimeChanged: (v) => _t = DateTime(_t.year, _t.month, _t.day, v.hour, v.minute),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final (label, mins) in [('−15', -15), ('+15', 15), ('+1 h', 60)])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: OutlinedButton(
                        onPressed: () => _set(_t.add(Duration(minutes: mins))),
                        child: Text(label),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop<TimeChoice>(context, (when: null, arriveBy: _arriveBy)),
                    child: Text(s.now),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () => Navigator.pop<TimeChoice>(context, (when: _t, arriveBy: _arriveBy)),
                    child: Text(s.de ? 'Übernehmen' : 'Done'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
