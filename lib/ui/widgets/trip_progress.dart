import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/util.dart';
import '../../models/journey.dart';
import '../../services/location.dart';
import '../app_scope.dart';
import '../line_colors.dart';
import '../strings.dart';
import 'countdown.dart';

class TripStatus {
  final IconData icon;
  final String title;
  final String? subtitle;
  final DateTime? target;
  final String? targetLabel;
  final Leg? leg;
  final double? progress;
  const TripStatus(this.icon, this.title, {this.subtitle, this.target, this.targetLabel, this.leg, this.progress});
}

/// Where in the journey we are right now, based on (realtime) times and, if available, the position.
TripStatus tripStatus(Journey j, S s, DateTime now, {double? lat, double? lon}) {
  final transit = j.transit;
  if (j.walkOnly) {
    if (now.isBefore(j.departure)) return TripStatus(Icons.directions_walk, s.de ? 'Losgehen' : 'Start walking', target: j.departure);
    if (now.isBefore(j.arrival)) {
      return TripStatus(
        Icons.directions_walk,
        s.de ? 'Zu Fuß unterwegs' : 'Walking',
        target: j.arrival,
        targetLabel: s.de ? 'Ankunft' : 'Arrival',
      );
    }
  }
  if (transit.isEmpty || !now.isBefore(j.arrival)) {
    return TripStatus(Icons.flag, s.de ? 'Angekommen in ${j.legs.last.to.name}' : 'Arrived at ${j.legs.last.to.name}');
  }
  final first = transit.first;
  if (now.isBefore(first.dep)) {
    final walkFirst = j.legs.first.isWalk && now.isBefore(j.legs.first.dep);
    return TripStatus(
      walkFirst ? Icons.directions_walk : Icons.schedule,
      walkFirst
          ? (s.de ? 'Losgehen zu ${first.from.name}' : 'Walk to ${first.from.name}')
          : '${first.line} ${s.de ? 'ab' : 'from'} ${first.from.name}',
      subtitle: [
        if (first.depPlatform != null) s.platform(first.depPlatform!),
        if (first.direction.isNotEmpty) s.towards(first.direction),
      ].join(' · '),
      target: walkFirst ? j.legs.first.dep : first.dep,
      targetLabel: walkFirst ? (s.de ? 'Losgehen' : 'Leave') : (s.de ? 'Abfahrt' : 'Departure'),
      leg: first,
    );
  }
  for (var i = 0; i < transit.length; i++) {
    final l = transit[i];
    if (!now.isBefore(l.dep) && now.isBefore(l.arr)) {
      final next = l.stops.where((st) => (st.arr ?? st.dep)?.isAfter(now) ?? false).firstOrNull;
      String? near;
      if (lat != null && lon != null) {
        final candidates = [l.from, ...l.stops.map((st) => Place(name: st.name, lat: st.lat, lon: st.lon)), l.to].where((p) => p.hasCoords);
        final best = candidates.fold<(Place, double)?>(null, (m, p) {
          final d = distKm(lat, lon, p.lat, p.lon);
          return m == null || d < m.$2 ? (p, d) : m;
        });
        if (best != null && best.$2 < 8) {
          near = best.$2 < 0.5
              ? (s.de ? 'In ${best.$1.name}' : 'At ${best.$1.name}')
              : (s.de
                    ? 'Bei ${best.$1.name} (${best.$2.toStringAsFixed(1)} km)'
                    : 'Near ${best.$1.name} (${best.$2.toStringAsFixed(1)} km)');
        }
      }
      return TripStatus(
        Icons.train,
        '${s.de ? 'Im' : 'On'} ${l.line} → ${l.direction.isNotEmpty ? l.direction : l.to.name}',
        subtitle: [
          ?near,
          if (next != null) '${s.de ? 'Nächster Halt' : 'Next stop'}: ${next.name} ${fmtTime((next.arr ?? next.dep)!)}',
          '${s.de ? 'Aussteigen' : 'Get off at'} ${l.to.name}${l.arrPlatform != null ? ' (${s.platform(l.arrPlatform!)})' : ''}',
        ].join('\n'),
        target: l.arr,
        targetLabel: s.de ? 'Ankunft' : 'Arrival',
        leg: l,
        progress: now.difference(l.dep).inSeconds / l.arr.difference(l.dep).inSeconds.clamp(1, 1 << 30),
      );
    }
    if (i + 1 < transit.length && !now.isBefore(l.arr) && now.isBefore(transit[i + 1].dep)) {
      final n = transit[i + 1];
      final mins = n.dep.difference(l.arr).inMinutes;
      return TripStatus(
        Icons.transfer_within_a_station,
        '${s.de ? 'Umstieg in' : 'Change at'} ${n.from.name}',
        subtitle: [
          '${n.line}${n.direction.isNotEmpty ? ' → ${n.direction}' : ''}',
          if (l.arrPlatform != null && n.depPlatform != null)
            '${s.platform(l.arrPlatform!)} → ${s.platform(n.depPlatform!)}'
          else if (n.depPlatform != null)
            s.platform(n.depPlatform!),
          '$mins min ${s.de ? 'Umstiegszeit' : 'to change'}',
        ].join(' · '),
        target: n.dep,
        targetLabel: s.de ? 'Abfahrt' : 'Departure',
        leg: n,
      );
    }
  }
  final last = j.legs.last;
  return TripStatus(Icons.directions_walk, s.de ? 'Weg zum Ziel' : 'On the way to the destination', target: last.arr);
}

/// Card at the top of a trip: what's happening now, with a live countdown. Re-evaluates as time passes.
class TripProgressCard extends StatefulWidget {
  final Journey journey;
  const TripProgressCard({super.key, required this.journey});

  @override
  State<TripProgressCard> createState() => _TripProgressCardState();
}

class _TripProgressCardState extends State<TripProgressCard> {
  Timer? _timer;
  final _loc = LocationService.instance;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => mounted ? setState(() {}) : null);
    _loc.position.addListener(_rebuild);
  }

  void _rebuild() => mounted ? setState(() {}) : null;

  @override
  void dispose() {
    _timer?.cancel();
    _loc.position.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final pos = _loc.position.value;
    final st = tripStatus(widget.journey, s, DateTime.now(), lat: pos?.latitude, lon: pos?.longitude);
    final c = st.leg != null ? lineColor(st.leg!, Theme.of(context).brightness) : cs.primary;
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(backgroundColor: c, foregroundColor: onLineColor(c), child: Icon(st.icon)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    st.title,
                    style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: cs.onPrimaryContainer),
                  ),
                ),
                if (st.target != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (st.targetLabel != null) Text(st.targetLabel!, style: t.labelSmall?.copyWith(color: cs.onPrimaryContainer)),
                      Countdown(
                        target: st.target!,
                        de: s.de,
                        showWithin: const Duration(hours: 24),
                        style: t.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: cs.onPrimaryContainer,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(fmtTime(st.target!), style: t.labelSmall?.copyWith(color: cs.onPrimaryContainer)),
                    ],
                  ),
              ],
            ),
            if (st.subtitle != null && st.subtitle!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(st.subtitle!, style: t.bodyMedium?.copyWith(color: cs.onPrimaryContainer)),
            ],
            if (st.progress != null) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: st.progress!.clamp(0, 1),
                  minHeight: 6,
                  color: c,
                  backgroundColor: c.withValues(alpha: 0.2),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
