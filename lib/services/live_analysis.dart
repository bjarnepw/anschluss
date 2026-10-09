// Live check of a trip: where you should be now (timetable + official delay) vs. where you are (GPS),
// the delay that follows from your position, and which transfers break because of it.
import 'dart:math';

import '../core/util.dart';
import '../models/journey.dart';

class TransferRisk {
  final Transfer transfer;

  /// Minutes left for the change with the estimated delay (negative = missed).
  final int buffer;
  const TransferRisk(this.transfer, this.buffer);
}

class LiveAnalysis {
  /// The train you are on (or boarding next).
  final Leg? leg;

  /// Position according to the timetable incl. official delay.
  final (double, double)? expected;

  /// Distance between that and your GPS position, in km.
  final double? offsetKm;

  /// Delay in minutes derived from where you are on the track (+ = behind the timetable). Null without GPS
  /// or when you're not on the train.
  final int? gpsDelay;

  /// Official delay of the current/next train (arrival while riding, departure before).
  final int officialDelay;

  /// GPS far away from the route – probably not on the train (or GPS is off).
  final bool offRoute;

  /// Before departure: minutes you'd need to walk to the station vs. minutes left.
  final (int, int)? reachStation;

  final List<TransferRisk> risks;

  /// A train still ahead of you (or the one you're on) is cancelled.
  final Leg? cancelled;

  const LiveAnalysis({
    this.leg,
    this.expected,
    this.offsetKm,
    this.gpsDelay,
    this.officialDelay = 0,
    this.offRoute = false,
    this.reachStation,
    this.risks = const [],
    this.cancelled,
  });

  /// The delay that counts: official, unless your position says it's worse.
  int get effectiveDelay => max(officialDelay, gpsDelay ?? officialDelay);

  bool get atRisk =>
      cancelled != null || risks.any((r) => r.buffer < 0) || (reachStation != null && reachStation!.$1 > reachStation!.$2);
}

/// Timeline of a leg: each stop with its time and its distance along the leg's path.
List<(DateTime, double, double, double)> _timeline(Leg l) {
  // (time, lat, lon, km along path)
  final pts = <(DateTime, double?, double?)>[
    (l.dep, l.from.lat, l.from.lon),
    for (final s in l.stops) ((s.dep ?? s.arr)!, s.lat, s.lon),
    (l.arr, l.to.lat, l.to.lon),
  ].where((p) => p.$2 != null).toList();
  final path = l.path;
  final cum = _cumulative(path);
  return [for (final p in pts) (p.$1, p.$2!, p.$3!, path.length < 2 ? 0 : cum[_nearestIndex(path, p.$2!, p.$3!)])];
}

List<double> _cumulative(List<List<double>> path) {
  final out = <double>[0];
  for (var i = 1; i < path.length; i++) {
    out.add(out.last + distKm(path[i - 1][0], path[i - 1][1], path[i][0], path[i][1]));
  }
  return out;
}

int _nearestIndex(List<List<double>> path, double lat, double lon) {
  var best = 0;
  var bd = double.infinity;
  for (var i = 0; i < path.length; i++) {
    final d = distKm(lat, lon, path[i][0], path[i][1]);
    if (d < bd) {
      bd = d;
      best = i;
    }
  }
  return best;
}

(double, double) _pointAt(List<List<double>> path, List<double> cum, double km) {
  if (path.isEmpty) return (0, 0);
  for (var i = 1; i < path.length; i++) {
    if (cum[i] >= km) {
      final seg = cum[i] - cum[i - 1];
      final f = seg <= 0 ? 0.0 : (km - cum[i - 1]) / seg;
      return (path[i - 1][0] + (path[i][0] - path[i - 1][0]) * f, path[i - 1][1] + (path[i][1] - path[i - 1][1]) * f);
    }
  }
  return (path.last[0], path.last[1]);
}

LiveAnalysis analyseTrip(Journey j, DateTime now, {double? lat, double? lon, int minTransfer = 0}) {
  final transit = j.transit;
  if (transit.isEmpty) return const LiveAnalysis();
  final hasGps = lat != null && lon != null;

  // Current train, or the next one if between trains / before the trip.
  final leg =
      transit.where((l) => !now.isBefore(l.dep) && now.isBefore(l.arr)).firstOrNull ??
      transit.where((l) => now.isBefore(l.dep)).firstOrNull;
  if (leg == null) return const LiveAnalysis(); // trip is over

  final riding = !now.isBefore(leg.dep);
  final official = (riding ? leg.arrDelay : leg.depDelay) ?? 0;

  (double, double)? expected;
  double? offsetKm;
  int? gpsDelay;
  var offRoute = false;
  (int, int)? reach;

  if (riding && leg.path.length >= 2) {
    final tl = _timeline(leg);
    final cum = _cumulative(leg.path);
    // Where you should be: interpolate between the two stops around "now" by time.
    for (var i = 1; i < tl.length; i++) {
      final a = tl[i - 1], b = tl[i];
      if (!now.isAfter(b.$1)) {
        final span = b.$1.difference(a.$1).inSeconds;
        final f = span <= 0 ? 1.0 : (now.difference(a.$1).inSeconds / span).clamp(0.0, 1.0);
        expected = _pointAt(leg.path, cum, a.$4 + (b.$4 - a.$4) * f);
        break;
      }
    }
    if (hasGps) {
      final i = _nearestIndex(leg.path, lat, lon);
      final off = distKm(lat, lon, leg.path[i][0], leg.path[i][1]);
      offRoute = off > 1.5;
      if (expected != null) offsetKm = distKm(lat, lon, expected.$1, expected.$2);
      if (!offRoute) {
        // Where on the timeline your position is → the time the train "should" have been here.
        final km = cum[i];
        for (var k = 1; k < tl.length; k++) {
          final a = tl[k - 1], b = tl[k];
          if (km <= b.$4 || k == tl.length - 1) {
            final seg = b.$4 - a.$4;
            final f = seg <= 0 ? 1.0 : ((km - a.$4) / seg).clamp(0.0, 1.0);
            final planned = a.$1.add(Duration(seconds: (b.$1.difference(a.$1).inSeconds * f).round()));
            // leg times already contain the official delay → add it back for the total
            gpsDelay = now.difference(planned).inMinutes + official;
            break;
          }
        }
      }
    }
  } else if (!riding && hasGps && leg.from.hasCoords) {
    // Before boarding: can you still walk to the station in time?
    final km = distKm(lat, lon, leg.from.lat, leg.from.lon);
    if (km > 0.15) {
      final walk = (km * 1.3 / 4.8 * 60).ceil();
      final left = leg.dep.difference(now).inMinutes;
      reach = (walk, left);
    }
  }

  final extra = max(0, (gpsDelay ?? official) - official); // what your position adds on top of the official delay
  final risks = <TransferRisk>[];
  var afterCurrent = false;
  for (final t in j.transferList) {
    if (identical(t.arriving, leg)) afterCurrent = true;
    if (!afterCurrent && !t.departing.dep.isAfter(now)) continue;
    final buffer = t.buffer - (afterCurrent ? extra : 0);
    if (buffer < 0 || (minTransfer > 0 && buffer < minTransfer)) risks.add(TransferRisk(t, buffer));
  }

  return LiveAnalysis(
    leg: leg,
    expected: expected,
    offsetKm: offsetKm,
    gpsDelay: gpsDelay,
    officialDelay: official,
    offRoute: offRoute,
    reachStation: reach,
    risks: risks,
    cancelled: transit.where((l) => l.cancelled && l.arr.isAfter(now)).firstOrNull,
  );
}

/// Where to search alternatives from: the next stop you can get off at when riding, else where you are.
Place alternativesStart(Journey j, DateTime now, {double? lat, double? lon, String here = 'Standort'}) {
  final leg = j.transit.where((l) => !now.isBefore(l.dep) && now.isBefore(l.arr)).firstOrNull;
  if (leg != null) {
    final next = leg.stops.where((s) => (s.arr ?? s.dep)?.isAfter(now) ?? false).firstOrNull;
    if (next != null && next.lat != null) return Place(name: next.name, lat: next.lat, lon: next.lon);
    return leg.to;
  }
  // Changing trains: from the station the last train arrived at, not from the start of the trip.
  final done = j.transit.where((l) => !now.isBefore(l.arr)).lastOrNull;
  if (done != null) return done.to;
  if (lat != null && lon != null) return Place(name: here, lat: lat, lon: lon, kind: PlaceKind.place);
  return j.transit.first.from;
}

/// The trip as ridden so far, then [alt] from where it starts: finished legs are kept, the train you are on
/// is cut at the stop [alt] starts from. Returns the new journey and the index of [alt]'s first leg in it.
(Journey, int) switchTo(Journey j, Journey alt, DateTime now) {
  final start = alt.legs.first.from.name;
  final kept = <Leg>[];
  for (final l in j.legs) {
    if (!l.arr.isAfter(now)) {
      kept.add(l);
      continue;
    }
    if (!l.isWalk && !now.isBefore(l.dep)) {
      final i = l.stops.indexWhere((st) => st.name == start);
      if (i >= 0) {
        kept.add(_cutAt(l, i));
      } else if (l.to.name == start) {
        kept.add(l);
      }
    }
    break;
  }
  return (
    Journey(
      source: alt.source,
      sources: {...j.sources, ...alt.sources}.toList(),
      legs: [...kept, ...alt.legs],
      prices: j.prices,
      dticket: alt.dticket,
      soldOut: alt.soldOut,
      bookingUrls: alt.bookingUrls,
    ),
    kept.length,
  );
}

/// [l] up to its stop [i] (you get off there).
Leg _cutAt(Leg l, int i) {
  final st = l.stops[i];
  final arr = (st.arr ?? st.dep)!;
  final path = st.lat == null || l.path.length < 2 ? l.path : l.path.sublist(0, _nearestIndex(l.path, st.lat!, st.lon!) + 1);
  return Leg(
    mode: l.mode,
    line: l.line,
    operator: l.operator,
    direction: l.direction,
    from: l.from,
    to: Place(name: st.name, lat: st.lat, lon: st.lon),
    dep: l.dep,
    arr: arr,
    plannedDep: l.plannedDep,
    plannedArr: arr.subtract(Duration(minutes: l.arrDelay ?? 0)),
    depDelay: l.depDelay,
    arrDelay: l.arrDelay,
    depPlatform: l.depPlatform,
    cancelled: l.cancelled,
    stops: l.stops.sublist(0, i),
    path: path,
    pathExact: l.pathExact,
    remarks: l.remarks,
  );
}
