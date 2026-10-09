// "Tricks": routes the normal search doesn't offer, built around the stations the first results pass through.
// - split: two tickets cut at a big station on the way – often cheaper than one through ticket.
// - dticket: with a Deutschlandticket, regional trains to a later stop of the ICE/IC, pay only from there.
// - start/end: for addresses, use the station good routes actually start/end at. DB and ÖBB otherwise only
//   get the nearest stop.
// A trick is kept only if it is clearly cheaper than every normal connection that is about as fast.
import 'dart:async';
import 'dart:math';

import '../core/util.dart';
import '../models/journey.dart';
import '../sources/source.dart';
import 'merge.dart';
import 'search.dart';
import 'via_search.dart';

const _hubsPerKind = 2;
const _firstParts = 3;

typedef TrickHub = ({Place place, int count, bool onLongLeg});

Future<List<Journey>> findTricks(Place from, Place to, SearchOptions opts, List<Journey> seed) async {
  final plain = seed.where((j) => !j.walkOnly && !j.cancelled && j.transit.isNotEmpty && j.trick == null).toList();
  if (plain.isEmpty || !from.hasCoords || !to.hasCoords) return [];
  final base = opts.copyWith(moreAlternatives: false);
  final hubs = trickHubs(from, to, plain);
  final direct = placeDist(from, to);
  // Split where the trip is cut roughly in half; D-Ticket to the first ICE stops (short regional ride).
  final splitAt = [...hubs]
    ..sort((a, b) {
      double mid(TrickHub h) => (placeDist(from, h.place) / direct - 0.5).abs();
      return b.count != a.count ? b.count.compareTo(a.count) : mid(a).compareTo(mid(b));
    });
  final dticketAt = hubs.where((h) => h.onLongLeg).toList()..sort((a, b) => placeDist(from, a.place).compareTo(placeDist(from, b.place)));

  final found = await Future.wait([
    for (final h in splitAt.take(_hubsPerKind)) _safe(_split(from, h.place, to, base)),
    if (opts.dticket)
      for (final h in dticketAt.take(_hubsPerKind)) _safe(_dticket(from, h.place, to, base)),
    if (!from.isStop) _safe(_otherStation(from, to, plain, base, atStart: true)),
    if (!to.isStop) _safe(_otherStation(from, to, plain, base, atStart: false)),
  ]);
  return usefulTricks(found.expand((l) => l).toList(), plain, dticket: opts.dticket);
}

/// Stations the normal results pass through: where people change trains and where long-distance trains stop.
/// Not too close to either end and not off the way.
List<TrickHub> trickHubs(Place from, Place to, List<Journey> plain) {
  final direct = placeDist(from, to);
  final byName = <String, TrickHub>{};
  void add(Place p, bool long) {
    if (!p.hasCoords || p.name.isEmpty) return;
    if (placeDist(from, p) < 15 || placeDist(p, to) < 15) return;
    if (placeDist(from, p) + placeDist(p, to) - direct > direct * 0.2 + 10) return;
    final old = byName[p.name];
    byName[p.name] = (place: old?.place ?? p, count: (old?.count ?? 0) + 1, onLongLeg: (old?.onLongLeg ?? false) || long);
  }

  for (final j in plain.take(10)) {
    final t = j.transit;
    for (var i = 0; i < t.length; i++) {
      final long = t[i].mode == Mode.long || t[i].mode == Mode.night;
      if (i > 0) add(t[i].from, long);
      if (long) {
        for (final s in t[i].stops.where((s) => s.lat != null && s.lon != null)) {
          add(Place(name: s.name, lat: s.lat, lon: s.lon), true);
        }
      }
    }
  }
  return byName.values.toList();
}

/// Two DB tickets: A → hub and hub → B.
Future<List<Journey>> _split(Place from, Place hub, Place to, SearchOptions base) async {
  final out = <Journey>[];
  for (final (a, b) in await _viaHub(from, hub, to, base, base, const ['db'])) {
    final pa = a.bestPrice, pb = b.bestPrice;
    if (pa == null || pb == null) continue;
    out.add(
      _tricked(
        joinJourneys(a, b),
        Trick('split', hub.name),
        Price(amount: ((pa.amount + pb.amount) * 100).round() / 100, source: 'db', partial: pa.partial || pb.partial),
        {if (a.bookingUrls['db'] != null) 'db': a.bookingUrls['db']!, if (b.bookingUrls['db'] != null) 'db2': b.bookingUrls['db']!},
      ),
    );
  }
  return out;
}

/// Regional trains (covered by the D-Ticket) to the hub, then a paid ticket from there.
Future<List<Journey>> _dticket(Place from, Place hub, Place to, SearchOptions base) async {
  final first = base.copyWith(dticketOnly: true, regionalOnly: true);
  final out = <Journey>[];
  for (final (a, b) in await _viaHub(from, hub, to, first, base, const ['transitous', 'db'])) {
    final pb = b.bestPrice;
    if (pb == null || b.dticket || !a.transit.every((l) => dticketModes.contains(l.mode))) continue;
    out.add(
      _tricked(joinJourneys(a, b), Trick('dticket', hub.name), Price(amount: pb.amount, source: 'db', partial: pb.partial), {
        if (b.bookingUrls['db'] != null) 'db': b.bookingUrls['db']!,
      }),
    );
  }
  return out;
}

/// Address → the station the normal results start at (or end at), asked at DB and ÖBB with a walk added.
Future<List<Journey>> _otherStation(Place from, Place to, List<Journey> plain, SearchOptions base, {required bool atStart}) async {
  final addr = atStart ? from : to;
  final (nearest, _) = await stationFor(addr);
  final maxKm = base.maxWalkMinutes / 60 * 4.5 / 1.3;
  final stations = <String, Place>{};
  for (final j in plain) {
    final s = atStart ? j.transit.first.from : j.transit.last.to;
    if (s.hasCoords && placeDist(addr, s) <= maxKm && placeDist(nearest, s) > 0.3) stations.putIfAbsent(s.name, () => s);
  }
  final out = <Journey>[];
  for (final s in stations.values.take(2)) {
    final walk = (placeDist(addr, s) * 1.3 / 4.5 * 60).ceil().clamp(1, 60);
    final list = await _last(
      atStart
          ? searchJourneys(s, to, base.copyWith(when: base.when.add(Duration(minutes: walk))), const ['db', 'oebb'])
          : searchJourneys(from, s, base, const ['db', 'oebb']),
    );
    for (final j in list.where((j) => !j.walkOnly && !j.cancelled)) {
      final legs = atStart
          ? [walkLeg(from, s, j.departure.subtract(Duration(minutes: walk)), walk), ...j.legs]
          : [...j.legs, walkLeg(s, to, j.arrival, walk)];
      out.add(
        Journey(
          source: 'trick',
          sources: j.sources,
          legs: legs,
          prices: j.prices,
          dticket: j.dticket,
          soldOut: j.soldOut,
          bookingUrls: j.bookingUrls,
          trick: Trick(atStart ? 'start' : 'end', s.name),
        ),
      );
    }
  }
  return out;
}

/// A → hub with [first], then for each of the best few, the earliest onward hub → B (DB, for the price).
Future<List<(Journey, Journey)>> _viaHub(
  Place from,
  Place hub,
  Place to,
  SearchOptions first,
  SearchOptions onward,
  List<String> firstSources,
) async {
  final transfer = Duration(minutes: max(first.minTransferMinutes, 5));
  final parts = (await _last(searchJourneys(from, hub, first, firstSources))).where((j) => !j.walkOnly && !j.cancelled).take(_firstParts);
  final pairs = await Future.wait(
    parts.map((a) async {
      final earliest = a.arrival.add(transfer);
      // Searched from the arrival, not after the transfer time: staying on the same train is the classic split.
      final next =
          (await _last(searchJourneys(hub, to, onward.copyWith(when: a.arrival, results: 3), const ['db'])))
              .where((b) => !b.walkOnly && !b.cancelled && (!b.departure.isBefore(earliest) || _sameTrain(a.legs.last, b.legs.first)))
              .toList()
            ..sort((x, y) => x.arrival.compareTo(y.arrival));
      return next.isEmpty ? null : (a, next.first);
    }),
  );
  return pairs.whereType<(Journey, Journey)>().toList();
}

/// [b] is the train [a] arrives with, continuing from the hub (split ticket: just stay on board).
bool _sameTrain(Leg a, Leg b) => !a.isWalk && a.mode == b.mode && a.line == b.line && a.to.name == b.from.name && !b.dep.isBefore(a.arr);

/// One leg for a train ridden on two tickets, so it is neither shown nor scored as a transfer.
List<Leg> seatedLegs(List<Leg> legs) {
  final out = <Leg>[];
  for (final l in legs) {
    final p = out.lastOrNull;
    if (p == null || !_sameTrain(p, l)) {
      out.add(l);
      continue;
    }
    out.last = Leg(
      mode: p.mode,
      line: p.line,
      operator: p.operator,
      direction: l.direction,
      from: p.from,
      to: l.to,
      dep: p.dep,
      arr: l.arr,
      plannedDep: p.plannedDep,
      plannedArr: l.plannedArr,
      depDelay: p.depDelay,
      arrDelay: l.arrDelay,
      depPlatform: p.depPlatform,
      arrPlatform: l.arrPlatform,
      cancelled: p.cancelled || l.cancelled,
      stops: [
        ...p.stops,
        Stopover(name: p.to.name, lat: p.to.lat, lon: p.to.lon, arr: p.arr, dep: l.dep),
        ...l.stops,
      ],
      path: [...p.path, ...l.path],
      pathExact: p.pathExact && l.pathExact,
      remarks: {...p.remarks, ...l.remarks}.toList(),
    );
  }
  return out;
}

Journey _tricked(Journey j, Trick trick, Price price, Map<String, String> urls) => Journey(
  source: 'trick',
  sources: j.sources,
  legs: seatedLegs(j.legs),
  prices: [price],
  dticket: false,
  soldOut: j.soldOut,
  bookingUrls: urls,
  trick: trick,
);

/// Keeps a split/D-Ticket trick only if it is at least 2 € cheaper than every normal connection arriving
/// no more than 15 min earlier, and not much slower than the fastest one. Start/end tricks are kept as long
/// as they are not much slower: if they are the same trains as a normal result they just merge into it
/// (adding DB's price); otherwise they are a new option.
List<Journey> usefulTricks(List<Journey> tricks, List<Journey> plain, {required bool dticket}) {
  final fastest = plain.map((j) => j.duration).reduce(min);
  final out = <Journey>[];
  for (final t in tricks) {
    if (t.duration > fastest * 1.5 + 60) continue;
    var keep = t;
    if (t.trick!.separate) {
      final price = t.bestPrice?.amount;
      if (price == null) continue;
      final rivals = plain
          .where((p) => !p.arrival.isAfter(t.arrival.add(const Duration(minutes: 15))))
          .map((p) => effectivePrice(p, dticket))
          .whereType<double>();
      final rival = rivals.isEmpty ? null : rivals.reduce(min);
      if (rival != null && price > rival - 2) continue;
      keep = Journey(
        source: t.source,
        sources: t.sources,
        legs: t.legs,
        prices: t.prices,
        dticket: t.dticket,
        soldOut: t.soldOut,
        bookingUrls: t.bookingUrls,
        trick: Trick(t.trick!.kind, t.trick!.at, saves: rival == null ? null : ((rival - price) * 100).round() / 100),
      );
    }
    // The same trick found twice (e.g. via two hubs): keep the cheaper one.
    final i = out.indexWhere((o) => o.trick!.kind == keep.trick!.kind && sameJourney(o, keep));
    if (i < 0) {
      out.add(keep);
    } else if ((keep.bestPrice?.amount ?? double.infinity) < (out[i].bestPrice?.amount ?? double.infinity)) {
      out[i] = keep;
    }
  }
  return out;
}

Future<List<Journey>> _last(Stream<SearchResult> s) async {
  var out = const <Journey>[];
  await for (final r in s) {
    out = r.journeys;
  }
  return out;
}

Future<List<Journey>> _safe(Future<List<Journey>> f) => f.catchError((Object _) => <Journey>[]);
