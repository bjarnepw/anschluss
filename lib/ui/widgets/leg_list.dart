import 'package:flutter/material.dart';

import '../../models/journey.dart';
import '../app_scope.dart';
import '../line_colors.dart';
import 'journey_card.dart';

/// Timeline of all legs with transfer info in between.
class LegList extends StatelessWidget {
  final Journey journey;
  const LegList({super.key, required this.journey});

  @override
  Widget build(BuildContext context) {
    final minTransfer = context.store.settings.minTransferMinutes;
    final transfers = Map<Leg, Transfer>.identity()..addEntries(journey.transferList.map((t) => MapEntry(t.departing, t)));
    final children = <Widget>[];
    for (final l in journey.legs) {
      final t = transfers[l];
      if (t != null) children.add(_TransferRow(t: t, minTransfer: minTransfer));
      children.add(l.isWalk ? _WalkRow(leg: l) : _LegRow(leg: l));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

class _TransferRow extends StatelessWidget {
  final Transfer t;
  final int minTransfer;
  const _TransferRow({required this.t, required this.minTransfer});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final bad = t.buffer < 0;
    final tight = !bad && ((minTransfer > 0 && t.buffer < minTransfer) || t.buffer < 3);
    final color = bad ? Colors.red.shade600 : (tight ? Colors.orange.shade800 : Theme.of(context).colorScheme.onSurfaceVariant);
    final platformChange = t.arriving.arrPlatform != null && t.departing.depPlatform != null
        ? ' · ${s.platform(t.arriving.arrPlatform!)} → ${s.platform(t.departing.depPlatform!)}'
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 52),
          Icon(bad ? Icons.warning_amber_rounded : Icons.transfer_within_a_station, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${s.transferAt(t.departing.from.name, t.minutes)}$platformChange${bad ? ' – ${s.missedTransfer}' : ''}',
              style: TextStyle(color: color, fontWeight: bad || tight ? FontWeight.w700 : FontWeight.w500, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _WalkRow extends StatelessWidget {
  final Leg leg;
  const _WalkRow({required this.leg});

  @override
  Widget build(BuildContext context) {
    if (leg.minutes <= 0 && (leg.walkDistance ?? 0) <= 0) return const SizedBox.shrink();
    final c = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(width: 52),
          Icon(Icons.directions_walk, size: 18, color: c),
          const SizedBox(width: 8),
          Text(context.s.walkMin(leg.minutes, leg.walkDistance), style: TextStyle(color: c, fontSize: 13)),
        ],
      ),
    );
  }
}

class _LegRow extends StatelessWidget {
  final Leg leg;
  const _LegRow({required this.leg});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final l = leg;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final c = lineColor(l, Theme.of(context).brightness);
    final fam = familyOf(l);

    Widget stationLine(DateTime time, int? delay, String name, String? platform) => Row(
      children: [
        SizedBox(
          width: 52,
          child: Row(
            children: [Text(fmtTime(time), style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700))],
          ),
        ),
        Expanded(
          child: Text(name, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        ),
        DelayText(delay),
        if (platform != null)
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: cs.outline),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(s.platform(platform), style: t.labelSmall),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          stationLine(l.dep, l.depDelay, l.from.name, l.depPlatform),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 52,
                  child: Center(
                    child: Container(
                      width: 6,
                      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(6)),
                              child: Text(
                                l.line,
                                style: TextStyle(color: onLineColor(c), fontWeight: FontWeight.w800, fontSize: 13),
                              ),
                            ),
                            if (l.direction.isNotEmpty) Text(s.towards(l.direction), style: t.bodySmall),
                          ],
                        ),
                        if (l.operator.isNotEmpty || fam.key != 'other')
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              [fam.label, if (l.operator.isNotEmpty) l.operator].join(' · '),
                              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ),
                        if (l.cancelled)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              s.cancelled,
                              style: TextStyle(color: cs.error, fontWeight: FontWeight.w700),
                            ),
                          ),
                        for (final r in l.remarks)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.info_outline, size: 15, color: Colors.orange.shade800),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(r, style: t.bodySmall?.copyWith(color: Colors.orange.shade900)),
                                ),
                              ],
                            ),
                          ),
                        if (l.stops.isNotEmpty)
                          Theme(
                            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              title: Text(s.stopsBetween(l.stops.length), style: t.bodySmall),
                              children: [
                                for (final st in l.stops)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 48,
                                          child: Text((st.dep ?? st.arr) != null ? fmtTime((st.dep ?? st.arr)!) : '', style: t.bodySmall),
                                        ),
                                        Expanded(
                                          child: Text(
                                            st.name,
                                            style: t.bodySmall?.copyWith(decoration: st.cancelled ? TextDecoration.lineThrough : null),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          stationLine(l.arr, l.arrDelay, l.to.name, l.arrPlatform),
        ],
      ),
    );
  }
}
