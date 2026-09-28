// Offline routing on the downloaded timetable with the Connection Scan Algorithm (CSA):
// all train hops of the day sorted by departure, scanned once per query. Fast enough on a phone
// for a whole country of regional + long-distance trains.
import 'dart:math';
import 'dart:typed_data';

import '../core/util.dart';
import '../models/journey.dart';
import 'timetable.dart';

const _inf = 1 << 30;

/// Connections of one service day, sorted by departure (seconds after local midnight of that day).
class _DayConnections {
  final Int32List dep, arr, trip, pos; // pos = index of the departure stop within the trip
  _DayConnections(this.dep, this.arr, this.trip, this.pos);
}

class OfflineRouter {
  final Timetable tt;
  OfflineRouter(this.tt);

  final _days = <int, _DayConnections>{};
  List<List<(int, int)>>? _foot; // stop -> [(other stop, walking seconds)]
  int _footSecs = -1; // same-station transfer time the footpaths were built with

  /// All connections usable on [day], including trips of the previous day that run past midnight.
  _DayConnections _connections(DateTime day) {
    final key = day.year * 10000 + day.month * 100 + day.day;
    final cached = _days[key];
    if (cached != null) return cached;
    final prev = day.subtract(const Duration(days: 1));
    final dep = <int>[], arr = <int>[], trip = <int>[], pos = <int>[];
    final activeToday = <int, bool>{}, activeYesterday = <int, bool>{};
    for (var t = 0; t < tt.tripCount; t++) {
      final svc = tt.tripService[t];
      final today = activeToday.putIfAbsent(svc, () => tt.services[svc].runsOn(day));
      final yesterday = activeYesterday.putIfAbsent(svc, () => tt.services[svc].runsOn(prev));
      if (!today && !yesterday) continue;
      final s0 = tt.tripStart[t], n = tt.tripLen[t];
      for (var i = 0; i < n - 1; i++) {
        final d = tt.stDep[s0 + i], a = tt.stArr[s0 + i + 1];
        if (today) {
          dep.add(d);
          arr.add(a);
          trip.add(t);
          pos.add(i);
        }
        if (yesterday && d >= 86400) {
          dep.add(d - 86400);
          arr.add(a - 86400);
          trip.add(-t - 1); // negative = yesterday's run
          pos.add(i);
        }
      }
    }
    final order = List<int>.generate(dep.length, (i) => i)..sort((a, b) => dep[a].compareTo(dep[b]));
    final c = _DayConnections(
      Int32List.fromList([for (final i in order) dep[i]]),
      Int32List.fromList([for (final i in order) arr[i]]),
      Int32List.fromList([for (final i in order) trip[i]]),
      Int32List.fromList([for (final i in order) pos[i]]),
    );
    if (_days.length > 2) _days.remove(_days.keys.first);
    _days[key] = c;
    return c;
  }

  /// Walking links: platforms of the same station, and stations within 500 m.
  List<List<(int, int)>> _footpaths(int sameStationSecs) {
    if (_foot != null && _footSecs == sameStationSecs) return _foot!;
    _footSecs = sameStationSecs;
    final n = tt.stopCount;
    final grid = <int, List<int>>{};
    int cell(double lat, double lon) => ((lat * 200).floor() << 16) ^ (lon * 130).floor();
    for (var i = 0; i < n; i++) {
      (grid[cell(tt.stopLat[i], tt.stopLon[i])] ??= []).add(i);
    }
    final foot = List<List<(int, int)>>.generate(n, (_) => []);
    for (var i = 0; i < n; i++) {
      final la = tt.stopLat[i], lo = tt.stopLon[i];
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final c = (((la * 200).floor() + dy) << 16) ^ ((lo * 130).floor() + dx);
          for (final j in grid[c] ?? const <int>[]) {
            if (j == i) continue;
            final km = distKm(la, lo, tt.stopLat[j], tt.stopLon[j]);
            if (tt.stopGroup[i] == tt.stopGroup[j]) {
              foot[i].add((j, max(sameStationSecs, (km * 1000 / 1.1).round())));
            } else if (km < 0.5) {
              foot[i].add((j, (km * 1000 / 1.1).round() + 120));
            }
          }
        }
      }
    }
    return _foot = foot;
  }

  /// Stops within walking distance of a place (seconds of walking), or matching its name.
  List<(int, int)> accessStops(Place p, int maxWalkSecs) {
    final out = <(int, int)>[];
    if (p.hasCoords) {
      for (var i = 0; i < tt.stopCount; i++) {
        final km = distKm(p.lat, p.lon, tt.stopLat[i], tt.stopLon[i]);
        final secs = (km * 1000 / 1.2).round();
        if (secs <= maxWalkSecs) out.add((i, secs));
      }
    }
    if (out.isEmpty) {
      final name = p.name.toLowerCase();
      for (var i = 0; i < tt.stopCount; i++) {
        if (tt.stopName[i].toLowerCase() == name) out.add((i, 0));
      }
    }
    return out;
  }

  /// Earliest-arrival journeys departing at or after [when], one after another.
  List<Journey> route(
    Place from,
    Place to,
    DateTime when, {
    int count = 5,
    int minTransferMinutes = 0,
    int maxWalkMinutes = 15,
    int? maxTransfers,
  }) {
    final walkSecs = max(maxWalkMinutes, 5) * 60;
    final origin = accessStops(from, walkSecs), target = accessStops(to, walkSecs);
    if (origin.isEmpty || target.isEmpty) return [];
    final transferSecs = max(minTransferMinutes, 4) * 60;
    final foot = _footpaths(transferSecs);

    final out = <Journey>[];
    var t0 = when;
    for (var k = 0; k < count; k++) {
      final j = _query(origin, target, from, to, t0, transferSecs, foot, maxTransfers);
      if (j == null) break;
      if (!out.any((o) => o.id == j.id)) out.add(j);
      t0 = j.transit.first.dep.add(const Duration(minutes: 1));
    }
    return out;
  }

  Journey? _query(
    List<(int, int)> origin,
    List<(int, int)> target,
    Place from,
    Place to,
    DateTime when,
    int transferSecs,
    List<List<(int, int)>> foot,
    int? maxTransfers,
  ) {
    final wall = cetWallClock(when);
    final day = DateTime(wall.year, wall.month, wall.day);
    var start = wall.hour * 3600 + wall.minute * 60 + wall.second;
    var conns = _connections(day);
    var dayShift = 0;
    // Late evening: continue into the next service day if nothing is left today.
    if (start > 22 * 3600) {
      final tomorrow = _connections(day.add(const Duration(days: 1)));
      if (_firstAtOrAfter(conns, start) >= conns.dep.length) {
        conns = tomorrow;
        start -= 86400;
        dayShift = 1;
      }
    }

    final n = tt.stopCount;
    final arrive = Int32List(n)..fillRange(0, n, _inf); // earliest arrival at stop
    final ready = Int32List(n)..fillRange(0, n, _inf); // earliest time to board there
    final viaEnter = Int32List(n)..fillRange(0, n, -1); // connection where the trip was boarded
    final viaExit = Int32List(n)..fillRange(0, n, -1); // connection that arrived here
    final viaFoot = Int32List(n)..fillRange(0, n, -1); // walked here from this stop
    final legsTo = Int32List(n); // transit legs used to reach the stop
    final tripEnter = <int, int>{};
    final tripLegs = <int, int>{};

    for (final (s, w) in origin) {
      arrive[s] = start + w;
      ready[s] = start + w;
    }
    final isTarget = <int, int>{for (final (s, w) in target) s: w};
    var best = _inf;

    for (var c = _firstAtOrAfter(conns, start); c < conns.dep.length; c++) {
      final dep = conns.dep[c];
      if (dep >= best) break;
      final trip = conns.trip[c];
      final t = trip < 0 ? -trip - 1 : trip;
      final s0 = tt.tripStart[t], p = conns.pos[c];
      final fromStop = tt.stStop[s0 + p], toStop = tt.stStop[s0 + p + 1];
      var entered = tripEnter[trip];
      if (entered == null) {
        if (ready[fromStop] > dep) continue;
        final legs = legsTo[fromStop] + 1;
        if (maxTransfers != null && legs - 1 > maxTransfers) continue;
        tripEnter[trip] = entered = c;
        tripLegs[trip] = legs;
      } else if (ready[fromStop] <= dep && legsTo[fromStop] + 1 < tripLegs[trip]!) {
        // Same train can be boarded here with fewer changes (e.g. instead of riding out and back):
        // board here instead – same arrival, simpler journey.
        tripEnter[trip] = entered = c;
        tripLegs[trip] = legsTo[fromStop] + 1;
      }
      final a = conns.arr[c];
      if (a < arrive[toStop]) {
        arrive[toStop] = a;
        ready[toStop] = min(ready[toStop], a + transferSecs);
        viaEnter[toStop] = entered;
        viaExit[toStop] = c;
        viaFoot[toStop] = -1;
        legsTo[toStop] = tripLegs[trip]!;
        final w = isTarget[toStop];
        if (w != null && a + w < best) best = a + w;
        for (final (o, secs) in foot[toStop]) {
          final r = a + secs;
          if (r < ready[o]) {
            ready[o] = r;
            if (r < arrive[o]) {
              arrive[o] = r;
              viaFoot[o] = toStop;
              viaExit[o] = -1;
              legsTo[o] = legsTo[toStop];
              final wt = isTarget[o];
              if (wt != null && r + wt < best) best = r + wt;
            }
          }
        }
      }
    }
    if (best == _inf) return null;

    // Best target stop (arrival + walk to the destination).
    var end = -1;
    for (final (s, w) in target) {
      if (arrive[s] < _inf && (end < 0 || arrive[s] + w < arrive[end] + isTarget[end]!)) end = s;
    }
    if (end < 0 || viaExit[end] < 0 && viaFoot[end] < 0) return null;

    final base = day.add(Duration(days: dayShift));
    DateTime at(int secs) {
      // secs after local midnight of `base` → UTC instant
      final wallTime = DateTime.utc(base.year, base.month, base.day).add(Duration(seconds: secs));
      return wallTime.subtract(cetOffset(wallTime.subtract(const Duration(hours: 2))));
    }

    Place stopPlace(int s) => Place(name: tt.stopName[s], lat: tt.stopLat[s], lon: tt.stopLon[s]);

    final legs = <Leg>[];
    var s = end;
    var guard = 0;
    while (guard++ < 50) {
      if (viaFoot[s] >= 0) {
        final f = viaFoot[s];
        if (tt.stopGroup[f] != tt.stopGroup[s]) {
          legs.insert(
            0,
            Leg(
              mode: Mode.walk,
              line: 'Walk',
              from: stopPlace(f),
              to: stopPlace(s),
              dep: at(arrive[f]),
              arr: at(arrive[s]),
              walkDistance: distKm(tt.stopLat[f], tt.stopLon[f], tt.stopLat[s], tt.stopLon[s]) * 1000,
              path: [
                [tt.stopLat[f], tt.stopLon[f]],
                [tt.stopLat[s], tt.stopLon[s]],
              ],
            ),
          );
        }
        s = f;
        continue;
      }
      final x = viaExit[s];
      if (x < 0) break; // origin reached
      final e = viaEnter[s];
      final trip = conns.trip[x];
      final t = trip < 0 ? -trip - 1 : trip;
      final shift = trip < 0 ? -86400 : 0;
      final s0 = tt.tripStart[t];
      final i0 = conns.pos[e], i1 = conns.pos[x] + 1;
      final stops = <Stopover>[
        for (var i = i0 + 1; i < i1; i++)
          Stopover(
            name: tt.stopName[tt.stStop[s0 + i]],
            lat: tt.stopLat[tt.stStop[s0 + i]],
            lon: tt.stopLon[tt.stStop[s0 + i]],
            arr: at(tt.stArr[s0 + i] + shift),
            dep: at(tt.stDep[s0 + i] + shift),
          ),
      ];
      final route = tt.tripRoute[t];
      legs.insert(
        0,
        Leg(
          mode: Mode.values[tt.routeMode[route]],
          line: tt.routeName[route],
          direction: tt.tripHeadsign[t],
          from: stopPlace(tt.stStop[s0 + i0]),
          to: stopPlace(tt.stStop[s0 + i1]),
          dep: at(tt.stDep[s0 + i0] + shift),
          arr: at(tt.stArr[s0 + i1] + shift),
          stops: stops,
          path: [
            for (var i = i0; i <= i1; i++) [tt.stopLat[tt.stStop[s0 + i]], tt.stopLon[tt.stStop[s0 + i]]],
          ],
        ),
      );
      s = tt.stStop[s0 + i0];
    }
    if (legs.isEmpty) return null;

    // Walks from the start place and to the destination.
    final firstStop = legs.first.from, lastStop = legs.last.to;
    final walkIn =
        origin.where((o) => tt.stopName[o.$1] == firstStop.name).map((o) => o.$2).fold<int?>(null, (m, v) => m == null || v < m ? v : m) ??
        0;
    final walkOut = isTarget[end] ?? 0;
    if (walkIn > 60 && from.hasCoords) {
      legs.insert(
        0,
        Leg(
          mode: Mode.walk,
          line: 'Walk',
          from: from,
          to: firstStop,
          dep: legs.first.dep.subtract(Duration(seconds: walkIn)),
          arr: legs.first.dep,
          walkDistance: walkIn * 1.2,
          path: [
            [from.lat!, from.lon!],
            [firstStop.lat!, firstStop.lon!],
          ],
        ),
      );
    }
    if (walkOut > 60 && to.hasCoords) {
      legs.add(
        Leg(
          mode: Mode.walk,
          line: 'Walk',
          from: lastStop,
          to: to,
          dep: legs.last.arr,
          arr: legs.last.arr.add(Duration(seconds: walkOut)),
          walkDistance: walkOut * 1.2,
          path: [
            [lastStop.lat!, lastStop.lon!],
            [to.lat!, to.lon!],
          ],
        ),
      );
    }
    final transit = legs.where((l) => !l.isWalk);
    return Journey(source: 'offline', legs: legs, dticket: transit.every((l) => dticketModes.contains(l.mode)));
  }

  int _firstAtOrAfter(_DayConnections c, int t) {
    var lo = 0, hi = c.dep.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (c.dep[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Stations whose name contains all words of [q], best matches first (one per station).
  List<Place> searchStops(String q, {int limit = 8}) {
    final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return [];
    final seen = <int>{};
    final hits = <(int, int)>[];
    for (var i = 0; i < tt.stopCount; i++) {
      final name = tt.stopName[i].toLowerCase();
      if (!words.every(name.contains)) continue;
      if (!seen.add(tt.stopGroup[i])) continue;
      final score = (name.startsWith(words.first) ? 0 : 100) + name.length;
      hits.add((i, score));
    }
    hits.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final (i, _) in hits.take(limit)) Place(name: tt.stopName[i], lat: tt.stopLat[i], lon: tt.stopLon[i])];
  }
}
