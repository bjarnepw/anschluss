import 'package:flutter/material.dart';

import '../../models/journey.dart';
import '../app_scope.dart';
import '../line_colors.dart';
import '../strings.dart';

/// Horizontal bar: each segment's width = its share of the travel time, colour = the line's own shade.
class JourneyStrip extends StatelessWidget {
  final Journey journey;
  final double height;
  const JourneyStrip({super.key, required this.journey, this.height = 22});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final total = journey.duration <= 0 ? 1 : journey.duration;
    final children = <Widget>[];
    DateTime? prevArr;
    for (final l in journey.legs) {
      if (prevArr != null) {
        final wait = l.dep.difference(prevArr).inMinutes;
        if (wait > 2) children.add(Expanded(flex: (wait * 1000 ~/ total).clamp(1, 100000), child: const SizedBox()));
      }
      final mins = l.minutes < 1 ? 1 : l.minutes;
      final c = lineColor(l, b);
      final label = l.isWalk ? '' : l.line.replaceAll(RegExp(r'\s*\(.*\)'), '');
      children.add(
        Expanded(
          flex: (mins * 1000 ~/ total).clamp(1, 100000),
          child: Tooltip(
            message: '${l.line} ${fmtTime(l.dep)}–${fmtTime(l.arr)}',
            child: Container(
              height: l.isWalk ? height / 3 : height,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: l.isWalk ? c.withValues(alpha: 0.5) : c, borderRadius: BorderRadius.circular(6)),
              child: label.isEmpty
                  ? null
                  : Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: TextStyle(color: onLineColor(c), fontSize: 11, fontWeight: FontWeight.w700),
                    ),
            ),
          ),
        ),
      );
      prevArr = l.arr;
    }
    return SizedBox(
      height: height,
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: children),
    );
  }
}

class DelayText extends StatelessWidget {
  final int? minutes;
  const DelayText(this.minutes, {super.key});

  @override
  Widget build(BuildContext context) {
    final m = minutes;
    if (m == null) return const SizedBox.shrink();
    final late = m > 0;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        late ? '+$m' : (m < 0 ? '$m' : '✓'),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: late ? (m >= 5 ? Colors.red.shade600 : Colors.orange.shade700) : Colors.green.shade600,
        ),
      ),
    );
  }
}

class Tag extends StatelessWidget {
  final String text;
  final Color? color;
  final IconData? icon;
  const Tag(this.text, {super.key, this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: c), const SizedBox(width: 3)],
          Text(
            text,
            style: TextStyle(fontSize: 11.5, color: c, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

List<Widget> journeyTags(BuildContext context, Journey j, {String? highlight, int minTransfer = 0, bool showDominated = true}) {
  final s = context.s;
  final buffer = j.tightestBuffer;
  return [
    if (highlight != null) Tag(highlight, color: Theme.of(context).colorScheme.primary, icon: Icons.star_rounded),
    if (j.cancelled) Tag(s.cancelled, color: Colors.red.shade600, icon: Icons.block),
    if (j.soldOut) Tag(s.soldOut, color: Colors.red.shade600),
    if (buffer != null && buffer < 0)
      Tag(s.missedTransfer, color: Colors.red.shade600, icon: Icons.warning_amber_rounded)
    else if (buffer != null && minTransfer > 0 && buffer < minTransfer)
      Tag(s.tightTransfer(buffer), color: Colors.orange.shade800, icon: Icons.directions_run),
    if (j.dticket) Tag('D-Ticket', color: Colors.teal.shade600),
    if (showDominated && j.dominated) Tag(s.beaten),
    ...j.sources.map((x) => Tag(s.sourceLabel(x))),
  ];
}

class PriceView extends StatelessWidget {
  final Journey journey;
  final bool dticket;
  const PriceView({super.key, required this.journey, required this.dticket});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    if (dticket && journey.dticket) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('0 €', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          Text(s.withDticket, style: t.labelSmall),
        ],
      );
    }
    final p = journey.bestPrice;
    if (p == null) return Text(s.noPrice, style: t.labelMedium?.copyWith(color: Theme.of(context).colorScheme.outline));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '${p.partial ? (s.de ? 'ab ' : 'from ') : ''}${fmtEur(p.amount)}',
          style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        Text(
          '${s.sourceLabel(p.source)}${journey.prices.length > 1 ? ' · ${s.offers(journey.prices.length)}' : ''}${p.seats != null && p.seats! < 10 ? ' · ${p.seats} ${s.de ? 'Plätze' : 'seats'}' : ''}',
          style: t.labelSmall,
        ),
      ],
    );
  }
}

class JourneyCard extends StatelessWidget {
  final Journey journey;
  final String? highlight;
  final bool selected;
  final VoidCallback? onTap;
  final DateTime? firstDay;

  const JourneyCard({super.key, required this.journey, this.highlight, this.selected = false, this.onTap, this.firstDay});

  @override
  Widget build(BuildContext context) {
    final settings = context.store.settings;
    final s = S(settings.language);
    final j = journey;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final dd = dayDiff(j.departure, j.arrival);
    final firstTransit = j.transit.isNotEmpty ? j.transit.first : j.legs.first;
    final otherDay = firstDay != null && dayDiff(firstDay!, j.departure) != 0;
    final depDelay = j.legs.first.depDelay ?? firstTransit.depDelay;
    final arrDelay = j.legs.last.arrDelay;
    final dim = j.dominated && !selected;

    return Opacity(
      opacity: j.cancelled ? 0.55 : (dim ? 0.8 : 1),
      child: Card(
        color: selected ? cs.secondaryContainer : null,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                fmtTime(j.departure),
                                style: t.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  decoration: j.cancelled ? TextDecoration.lineThrough : null,
                                ),
                              ),
                              DelayText(depDelay),
                              Text('  –  ', style: t.titleLarge),
                              Text(fmtTime(j.arrival), style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                              DelayText(arrDelay),
                              if (dd > 0) Text(' +$dd', style: t.labelSmall?.copyWith(color: cs.error)),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              fmtDur(j.duration),
                              j.transfers == 0 ? s.direct : s.changes(j.transfers),
                              firstTransit.line,
                              if (otherDay) fmtDate(j.departure, s.de),
                            ].join(' · '),
                            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    PriceView(journey: j, dticket: settings.dticket),
                  ],
                ),
                const SizedBox(height: 10),
                JourneyStrip(journey: j),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: journeyTags(context, j, highlight: highlight, minTransfer: settings.minTransferMinutes),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
