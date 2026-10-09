import 'package:flutter/material.dart';

import '../../core/currency.dart';
import '../../models/journey.dart';
import '../app_scope.dart';
import '../line_colors.dart';
import '../strings.dart';

/// Horizontal bar: each segment is placed at its exact time, colour = the line's own shade.
/// Transfer gaps show the minutes you have; [detailed] adds time labels underneath.
class JourneyStrip extends StatelessWidget {
  final Journey journey;
  final double height;
  final bool detailed;
  const JourneyStrip({super.key, required this.journey, this.height = 22, this.detailed = false});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final cs = Theme.of(context).colorScheme;
    final start = journey.departure;
    final total = journey.arrival.difference(start).inSeconds.clamp(60, 1 << 30).toDouble();
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        double x(DateTime t) => (t.difference(start).inSeconds / total * w).clamp(0, w);
        final children = <Widget>[];
        final labels = <(double, String, bool)>[]; // x, text, bold
        DateTime? prevArr;
        for (final l in journey.legs) {
          // Walks of 0 minutes (same platform) are not worth a segment.
          if (l.isWalk && l.minutes < 1) continue;
          final left = x(l.dep), right = x(l.arr);
          final width = (right - left).clamp(3.0, w);
          if (prevArr != null) {
            final wait = l.dep.difference(prevArr).inMinutes;
            final gapL = x(prevArr), gapW = left - gapL;
            if (wait > 0 && gapW > 16) {
              children.add(
                Positioned(
                  left: gapL,
                  width: gapW,
                  top: 0,
                  height: height,
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        "$wait'",
                        style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              );
            }
          }
          // Walking takes time like a train ride: a full segment with 🚶 and the minutes.
          final col = lineColor(l, b);
          final fg = onLineColor(col);
          final label = l.isWalk ? "${l.minutes}'" : l.line.replaceAll(RegExp(r'\s*\(.*\)'), '');
          children.add(
            Positioned(
              left: left,
              width: width,
              top: 0,
              height: height,
              child: Tooltip(
                message: l.isWalk
                    ? '${context.s.walk} ${fmtTime(l.dep)}–${fmtTime(l.arr)}'
                    : '${l.line} ${fmtTime(l.dep)}–${fmtTime(l.arr)}',
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(6)),
                  child: width < 16
                      ? null
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (l.isWalk) Icon(Icons.directions_walk, size: 13, color: fg),
                            if (!l.isWalk || width >= 40)
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  softWrap: false,
                                  style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w700),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ),
          );
          labels.add((left, fmtTime(l.dep), prevArr == null));
          labels.add((right, fmtTime(l.arr), identical(l, journey.legs.last)));
          prevArr = l.arr;
        }
        final rows = <Widget>[
          SizedBox(
            height: height,
            width: w,
            child: Stack(clipBehavior: Clip.none, children: children),
          ),
        ];
        if (detailed) {
          // Time labels at every departure/arrival; skip ones that would overlap.
          const labelW = 34.0;
          final placed = <Widget>[];
          double lastRight = -100;
          labels.sort((a, b) => a.$1.compareTo(b.$1));
          for (final (lx, text, bold) in labels) {
            final left = (lx - labelW / 2).clamp(0, w - labelW).toDouble();
            if (left < lastRight + 2 && !bold) continue;
            lastRight = left + labelW;
            placed.add(
              Positioned(
                left: left,
                width: labelW,
                top: 2,
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                    color: cs.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            );
          }
          rows.add(
            SizedBox(
              height: 18,
              width: w,
              child: Stack(children: placed),
            ),
          );
        }
        return Column(mainAxisSize: MainAxisSize.min, children: rows);
      },
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = color;
    // Same contrast fix as Capsule: the plain accent is too faint as text on a dark card.
    final c = accent == null
        ? cs.onSurfaceVariant
        : (dark ? Color.lerp(accent, Colors.white, 0.35)! : Color.lerp(accent, Colors.black, 0.15)!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: (accent ?? c).withValues(alpha: dark ? 0.22 : 0.12), borderRadius: BorderRadius.circular(20)),
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
    if (j.trick != null) Tag(s.trick(j.trick!, fmtEur), color: Colors.deepPurple.shade400, icon: Icons.auto_awesome),
    if (showDominated && j.dominated) Tag(s.beaten),
    // Where it came from: background info, so plain small text instead of more pills.
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      child: Text(
        j.sources.map(s.sourceLabel).join(' · '),
        style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.outline),
      ),
    ),
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
    if (journey.walkOnly) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('0 €', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          Text(s.sourceLabel('walk'), style: t.labelSmall),
        ],
      );
    }
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
    // What the price is for: only some trains (partial), or the trains the D-Ticket doesn't cover.
    String trains(Iterable<Leg> ls) => ls.length > 2 ? '${ls.take(2).map((l) => l.line).join(', ')} …' : ls.map((l) => l.line).join(', ');
    final paid = journey.transit.where((l) => !dticketModes.contains(l.mode)).toList();
    final note = p.partial
        ? (p.covers != null ? s.onlyFor(p.covers!) : s.partPrice)
        : (dticket && paid.isNotEmpty && paid.length < journey.transit.length ? s.paidRestDticket(trains(paid)) : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '${p.partial ? '≥ ' : ''}${p.converted ? '≈ ' : ''}${fmtEur(p.amount)}',
          style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        if (note != null) Text(note, style: t.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
        Text(
          '${p.converted ? '${p.originalAmount!.round()} ${currencySymbol(p.originalCurrency!)} · ' : ''}${s.sourceLabel(p.source)}${journey.prices.length > 1 ? ' · ${s.offers(journey.prices.length)}' : ''}${p.seats != null && p.seats! < 10 ? ' · ${p.seats} ${s.de ? 'Plätze' : 'seats'}' : ''}',
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

  /// Fastest and slowest duration among the results shown – colours the duration capsule.
  final (int, int)? durationRange;

  const JourneyCard({
    super.key,
    required this.journey,
    this.highlight,
    this.selected = false,
    this.onTap,
    this.firstDay,
    this.durationRange,
  });

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
    // Equal-width digits so times line up from card to card.
    final timeStyle = t.titleLarge?.copyWith(
      fontWeight: FontWeight.w800,
      fontFeatures: const [FontFeature.tabularFigures()],
      decoration: j.cancelled ? TextDecoration.lineThrough : null,
    );

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
                              Text(fmtTime(j.departure), style: timeStyle),
                              DelayText(depDelay),
                              Text('  –  ', style: t.titleLarge),
                              Text(fmtTime(j.arrival), style: timeStyle),
                              DelayText(arrDelay),
                              if (dd > 0) Text(' +$dd', style: t.labelSmall?.copyWith(color: cs.error)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              Capsule(icon: Icons.schedule, text: fmtDur(j.duration), color: speedColor(j.duration, durationRange)),
                              Capsule(
                                icon: j.walkOnly ? Icons.directions_walk : Icons.swap_horiz,
                                text: j.walkOnly ? s.sourceLabel('walk') : (j.transfers == 0 ? s.direct : s.changes(j.transfers)),
                                color: j.transfers == 0 && !j.walkOnly ? cs.tertiary : null,
                              ),
                              if (otherDay) Capsule(icon: Icons.event, text: fmtDate(j.departure, s.de)),
                            ],
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

/// Material colour for how fast a connection is compared to the others:
/// green = among the fastest … red = among the slowest. Null (neutral) without a comparison.
Color? speedColor(int minutes, (int, int)? range) {
  if (range == null) return null;
  final (min, max) = range;
  if (max - min < 5) return Colors.green.shade600; // all about equally fast
  final t = ((minutes - min) / (max - min)).clamp(0.0, 1.0);
  if (t < 0.15) return Colors.green.shade600;
  if (t < 0.35) return Colors.lightGreen.shade700;
  if (t < 0.6) return Colors.amber.shade700;
  if (t < 0.8) return Colors.orange.shade700;
  return Colors.red.shade600;
}

/// Small rounded label: tinted background, icon + text in the accent colour.
class Capsule extends StatelessWidget {
  final IconData? icon;
  final String text;
  final Color? color;
  const Capsule({super.key, this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = color;
    final fg = accent == null
        ? cs.onSurfaceVariant
        : (dark ? Color.lerp(accent, Colors.white, 0.35)! : Color.lerp(accent, Colors.black, 0.25)!);
    final bg = accent == null ? cs.surfaceContainerHighest : accent.withValues(alpha: dark ? 0.22 : 0.14);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 4)],
          Text(
            text,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: fg, height: 1.2),
          ),
        ],
      ),
    );
  }
}
