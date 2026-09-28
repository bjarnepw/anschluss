// Flix + feeder connections: FlixTrain between two hubs, with regional trains (via Transitous) to and
// from them. Finds e.g. Salzwedel → (RE) → Berlin → (FLX) → Köln even though Salzwedel has no Flix stop,
// and attaches Flix prices to connections other sources found with a FlixTrain leg.
import 'dart:async';

import '../core/util.dart';
import '../models/journey.dart';
import '../sources/flix.dart';
import '../sources/source.dart';
import '../sources/transitous.dart';
import 'merge.dart';

const _maxHubNames = 14;
const _maxPairs = 5;
const _maxRides = 8;

typedef _Hub = ({FlixCity city, Place place});

class FlixCombos {
  final FlixSource flix;
  final TransitousSource transitous;
  FlixCombos(this.flix, this.transitous);

  Future<List<Journey>> find(Place from, Place to, SearchOptions opts, List<Journey> seed) async {
    if (opts.dticketOnly || !from.hasCoords || !to.hasCoords) return [];
    final hubs = await _hubs(from, to, opts, seed);
    final fromCity = await _safe(flix.cityFor(from, maxKm: 8, trainOnly: !opts.coach));
    final toCity = await _safe(flix.cityFor(to, maxKm: 8, trainOnly: !opts.coach));

    // Hub pairs that make progress towards the destination, least detour first.
    final direct = placeDist(from, to);
    final pairs = <(_Hub, _Hub, double)>[];
    for (final a in hubs) {
      for (final b in hubs) {
        if (a.city.id == b.city.id) continue;
        if (a.city.id == fromCity?.id && b.city.id == toCity?.id) continue; // plain Flix search covers this
        final dA = placeDist(from, a.place), dB = placeDist(from, b.place);
        if (dA >= dB || placeDist(b.place, to) >= placeDist(a.place, to)) continue;
        if (placeDist(a.place, b.place) < 25) continue; // not worth a Flix ride
        final detour = dA + placeDist(a.place, b.place) + placeDist(b.place, to) - direct;
        if (detour > direct * 0.6 + 30) continue;
        pairs.add((a, b, detour));
      }
    }
    pairs.sort((x, y) => x.$3.compareTo(y.$3));

    // Flix rides for each pair around the time the traveller could reach hub A.
    final rides = <(Journey, _Hub, _Hub)>[];
    await Future.wait(
      pairs.take(_maxPairs).map((p) async {
        final (a, b, _) = p;
        final reachA = _estimateMinutes(placeDist(from, a.place));
        final reachEnd = _estimateMinutes(placeDist(b.place, to));
        final at = opts.arriveBy ? opts.when.subtract(Duration(minutes: reachEnd)) : opts.when.add(Duration(minutes: reachA));
        final list = await _safe(flix.ridesAround(a.city, b.city, _with(opts, when: at), limit: 3)) ?? const [];
        for (final r in list) {
          if (!opts.coach && r.legs.any((l) => l.mode == Mode.coach)) continue;
          rides.add((r, a, b));
        }
      }),
    );
    // The same FlixTrain shows up once per hub pair it serves (Hannover→Hagen, Hannover→Köln, …):
    // keep one per train, getting off closest to the destination.
    rides.sort((x, y) => placeDist(x.$3.place, to).compareTo(placeDist(y.$3.place, to)));
    final seenTrains = <String>{};
    rides.retainWhere((r) => seenTrains.add('${r.$2.city.id}@${r.$1.departure.toIso8601String()}'));
    rides.sort((x, y) => x.$1.departure.compareTo(y.$1.departure));

    final out = <Journey>[];
    await Future.wait(
      rides.take(_maxRides).map((r) async {
        final j = await _assemble(from, to, r.$1, r.$2, r.$3, opts, fromCity, toCity);
        if (j != null) out.add(j);
      }),
    );
    return out;
  }

  /// Gives connections that contain a FlixTrain leg but no Flix price (found by DB/ÖBB/Transitous)
  /// the price of the matching Flix ride.
  Future<List<Journey>> enrich(List<Journey> journeys, SearchOptions opts) async {
    final out = <Journey>[];
    final todo = journeys.where((j) => !j.prices.any((p) => p.source == 'flix') && j.transit.any(_isFlx)).take(6);
    await Future.wait(
      todo.map((j) async {
        final leg = j.transit.firstWhere(_isFlx);
        final a = await _safe(flix.cityFor(leg.from, maxKm: 15, trainOnly: true));
        final b = await _safe(flix.cityFor(leg.to, maxKm: 15, trainOnly: true));
        if (a == null || b == null || a.id == b.id) return;
        final rides = await _safe(flix.ridesOnDay(a, b, leg.plannedDep, _with(opts, coach: true))) ?? const [];
        final ride = rides.where((r) => r.departure.difference(leg.plannedDep).inMinutes.abs() <= 5).firstOrNull;
        final price = ride?.bestPrice;
        if (price == null) return;
        final whole = j.transit.every((l) => _isFlx(l) || (opts.dticket && dticketModes.contains(l.mode)));
        out.add(
          Journey(
            source: 'flixcombo',
            sources: ['flix'],
            legs: j.legs,
            prices: [Price(amount: price.amount, source: 'flix', partial: !whole, url: price.url, seats: price.seats)],
            dticket: false,
            soldOut: ride!.soldOut,
            bookingUrls: {...ride.bookingUrls},
          ),
        );
      }),
    );
    return out;
  }

  /// Feeders are local/regional trains and buses (the cheap part) – an ICE to the Flix hub defeats the purpose.
  static bool _regional(Journey j) => j.transit.isNotEmpty && j.transit.every((l) => dticketModes.contains(l.mode));

  static bool _isFlx(Leg l) => RegExp(r'\bFLX|flixtrain', caseSensitive: false).hasMatch('${l.line} ${l.operator}');

  /// Candidate hubs: the endpoints plus stations the normal results pass through, if FlixTrain serves them.
  Future<List<_Hub>> _hubs(Place from, Place to, SearchOptions opts, List<Journey> seed) async {
    final names = <String, Place>{};
    void add(Place p) {
      if (p.name.isEmpty || !p.hasCoords || names.length >= _maxHubNames) return;
      names.putIfAbsent(flixCityQuery(p.name).toLowerCase(), () => p);
    }

    add(from);
    add(to);
    for (final j in seed.take(8)) {
      for (final l in j.transit) {
        add(l.from);
        add(l.to);
      }
    }
    // Big stations along long legs are typical Flix stops too.
    for (final j in seed.take(4)) {
      for (final l in j.transit.where((l) => l.minutes >= 40)) {
        for (final s in l.stops.where((s) => RegExp(r'Hbf|Hauptbahnhof').hasMatch(s.name) && s.lat != null)) {
          add(Place(name: s.name, lat: s.lat, lon: s.lon));
        }
      }
    }
    final resolved = await Future.wait(
      names.values.map((p) async {
        final c = await _safe(flix.cityFor(p, maxKm: 15, trainOnly: !opts.coach));
        return c == null ? null : (city: c, place: Place(name: c.name, lat: c.lat ?? p.lat, lon: c.lon ?? p.lon));
      }),
    );
    final seen = <String>{};
    return [
      for (final h in resolved.whereType<_Hub>())
        if (seen.add(h.city.id)) h,
    ];
  }

  Future<Journey?> _assemble(
    Place from,
    Place to,
    Journey ride,
    _Hub a,
    _Hub b,
    SearchOptions opts,
    FlixCity? fromCity,
    FlixCity? toCity,
  ) async {
    final transfer = Duration(minutes: opts.minTransferMinutes > 0 ? opts.minTransferMinutes : 8);
    final flixFrom = ride.legs.first.from, flixTo = ride.legs.last.to;

    Journey? pre;
    if (a.city.id != fromCity?.id) {
      final station = await _station(flixFrom, a.place);
      final list = await _safe(
        transitous.journeys(
          from,
          station,
          _with(
            opts,
            when: ride.departure.subtract(transfer),
            arriveBy: true,
            results: 3,
            coach: false,
            dticketOnly: false,
            regionalOnly: true,
          ),
        ),
      );
      final ok =
          (list ?? const <Journey>[])
              .where((j) => _regional(j) && !j.arrival.isAfter(ride.departure.subtract(transfer)))
              .where((j) => opts.arriveBy || !j.departure.isBefore(opts.when.subtract(const Duration(minutes: 5))))
              .toList()
            ..sort((x, y) => y.departure.compareTo(x.departure)); // leave as late as possible
      if (ok.isEmpty) return null;
      pre = ok.first;
    } else if (!opts.arriveBy && ride.departure.isBefore(opts.when)) {
      return null;
    }

    Journey? post;
    if (b.city.id != toCity?.id) {
      final station = await _station(flixTo, b.place);
      final list = await _safe(
        transitous.journeys(
          station,
          to,
          _with(opts, when: ride.arrival.add(transfer), arriveBy: false, results: 3, coach: false, dticketOnly: false, regionalOnly: true),
        ),
      );
      final ok = (list ?? const <Journey>[]).where((j) => _regional(j) && !j.departure.isBefore(ride.arrival.add(transfer))).toList()
        ..sort((x, y) => x.arrival.compareTo(y.arrival));
      if (ok.isEmpty) return null;
      post = ok.first;
      if (opts.arriveBy && post.arrival.isAfter(opts.when)) return null;
    }

    final legs = [...?pre?.legs, ...ride.legs, ...?post?.legs];
    final feeders = [...?pre?.transit, ...?post?.transit];
    final price = ride.bestPrice;
    final whole = feeders.every((l) => opts.dticket && dticketModes.contains(l.mode));
    return Journey(
      source: 'flixcombo',
      sources: ['flix', if (feeders.isNotEmpty) 'transitous'],
      legs: legs,
      prices: [if (price != null) Price(amount: price.amount, source: 'flix', partial: !whole, url: price.url, seats: price.seats)],
      dticket: false,
      soldOut: ride.soldOut,
      bookingUrls: {...ride.bookingUrls},
    );
  }

  /// Flix only gives station names; find the actual station (for coordinates) near the Flix city.
  Future<Place> _station(Place flixStation, Place city) async {
    final hits = await _safe(transitous.locations(flixStation.name)) ?? const [];
    final near = hits.where((h) => distKm(h.lat, h.lon, city.lat, city.lon) < 25).toList()
      ..sort((x, y) => distKm(x.lat, x.lon, city.lat, city.lon).compareTo(distKm(y.lat, y.lon, city.lat, city.lon)));
    return near.isNotEmpty ? near.first : Place(name: flixStation.name, lat: city.lat, lon: city.lon);
  }

  /// Rough door-to-door minutes for a regional-train distance (for choosing which Flix rides to look at).
  static int _estimateMinutes(double km) => km < 3 ? 0 : (15 + km * 1.1).round();

  static Future<T?> _safe<T>(Future<T> f) async {
    try {
      return await f;
    } catch (_) {
      return null;
    }
  }
}

SearchOptions _with(
  SearchOptions o, {
  DateTime? when,
  bool? arriveBy,
  int? results,
  bool? coach,
  bool? dticketOnly,
  bool regionalOnly = false,
}) => SearchOptions(
  when: when ?? o.when,
  arriveBy: arriveBy ?? o.arriveBy,
  minTransferMinutes: o.minTransferMinutes,
  maxTransfers: o.maxTransfers,
  bahncard: o.bahncard,
  firstClass: o.firstClass,
  dticket: o.dticket,
  dticketOnly: dticketOnly ?? o.dticketOnly,
  bike: o.bike,
  coach: coach ?? o.coach,
  age: o.age,
  results: results ?? o.results,
  maxWalkMinutes: o.maxWalkMinutes,
  includeWalking: o.includeWalking,
  moreAlternatives: o.moreAlternatives,
  regionalOnly: regionalOnly,
);

/// Keeps only combos that are not clearly worse than something already found.
List<Journey> usefulCombos(List<Journey> combos, List<Journey> existing) {
  final real = existing.where((e) => e.transit.isNotEmpty && !e.cancelled).toList();
  final fastest = real.map((e) => e.duration).fold<int?>(null, (m, d) => m == null || d < m ? d : m);
  final cheapest = real.map((e) => e.bestPrice?.amount).whereType<double>().fold<double?>(null, (m, p) => m == null || p < m ? p : m);
  return combos.where((c) {
    if (existing.any((e) => sameJourney(e, c))) return true; // merges and adds the Flix price
    if (fastest == null) return true;
    // Not much slower: always interesting.
    if (c.duration <= fastest * 1.35 + 20) return true;
    // Clearly slower, but a lot cheaper: still worth showing ("all possible connections").
    final price = c.bestPrice?.amount;
    return price != null && (cheapest == null || price <= cheapest * 0.6) && c.duration <= fastest * 1.8 + 30;
  }).toList();
}
