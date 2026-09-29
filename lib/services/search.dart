// Runs every source in parallel and emits a merged, ranked snapshot each time one answers,
// so fast sources show up immediately instead of waiting for the slowest one.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../core/net.dart';
import '../core/util.dart';
import '../models/journey.dart';
import '../sources/db.dart';
import '../sources/flix.dart';
import '../sources/oebb.dart';
import '../sources/regiojet.dart';
import '../sources/source.dart';
import '../sources/transitous.dart';
import '../offline/offline_pack.dart';
import 'flix_combos.dart';
import 'merge.dart';

enum SourceState { loading, ok, failed, paused, skipped }

class SourceStatus {
  final SourceState state;
  final int count;
  final String? error;
  final int ms;
  const SourceStatus(this.state, {this.count = 0, this.error, this.ms = 0});
}

class SearchResult {
  final List<Journey> journeys;
  final Map<String, SourceStatus> status;
  final bool done;
  final DateTime fetchedAt;
  const SearchResult(this.journeys, this.status, {this.done = false, required this.fetchedAt});

  bool get anyFailed => status.values.any((s) => s.state == SourceState.failed || s.state == SourceState.paused);
}

final dbSource = DbSource();
final transitousSource = TransitousSource();
final flixSource = FlixSource();
final regioJetSource = RegioJetSource();
final oebbSource = OebbSource();

final offlineSource = OfflineSource();

final Map<String, Source> sources = {
  'offline': offlineSource,
  'db': dbSource,
  'transitous': transitousSource,
  'flix': flixSource,
  'oebb': oebbSource,
  'regiojet': regioJetSource,
};

const _sourceTimeout = Duration(seconds: 30);

/// [offlineOnly]: use only the downloaded timetable (no data usage). Otherwise the offline timetable is used
/// automatically when none of the online sources answers.
Stream<SearchResult> searchJourneys(
  Place from,
  Place to,
  SearchOptions opts,
  List<String> wanted, {
  bool hideTight = false,
  bool offlineOnly = false,
}) {
  if (offlineOnly) wanted = ['offline'];
  final ctrl = StreamController<SearchResult>();
  final lists = <String, List<Journey>>{};
  final status = <String, SourceStatus>{};
  var pending = 0;
  void emit() {
    var merged = mergeJourneys(lists.values);
    if (hideTight && opts.minTransferMinutes > 0) {
      merged = merged.where((j) => (j.tightestBuffer ?? 999) >= opts.minTransferMinutes).toList();
    }
    if (opts.maxTransfers != null) merged = merged.where((j) => j.transfers <= opts.maxTransfers!).toList();
    merged = pruneImplausible(merged, from, to);
    // Walking the whole way: only show it when it can compete with the trains.
    final fastest = merged
        .where((j) => !j.walkOnly && !j.cancelled)
        .map((j) => j.duration)
        .fold<int?>(null, (m, d) => m == null || d < m ? d : m);
    merged = merged
        .where((j) => !j.walkOnly || j.duration <= opts.walkOnlyMaxMinutes || (fastest != null && j.duration <= fastest * 1.2))
        .toList();
    rankJourneys(merged, when: opts.when, arriveBy: opts.arriveBy, dticket: opts.dticket, minTransfer: opts.minTransferMinutes);
    ctrl.add(SearchResult(merged, Map.of(status), done: pending == 0, fetchedAt: DateTime.now()));
  }

  var combosStarted = false;

  // Phase 2, once the normal sources answered: Flix + feeder combinations built around the stations
  // those results pass through, plus Flix prices for FlixTrain legs other sources found.
  void runCombos() {
    if (combosStarted) return;
    combosStarted = true;
    // Nobody answered (no connection?): fall back to the offline timetable if there is one.
    final noneOk = !status.values.any((x) => x.state == SourceState.ok);
    if (noneOk && !wanted.contains('offline') && OfflinePack.instance.available) {
      status['offline'] = const SourceStatus(SourceState.loading);
      pending++;
      emit();
      final sw = Stopwatch()..start();
      offlineSource
          .journeys(from, to, opts)
          .then((list) {
            lists['offline'] = list;
            status['offline'] = SourceStatus(SourceState.ok, count: list.length, ms: sw.elapsedMilliseconds);
          })
          .catchError((Object e) {
            status['offline'] = SourceStatus(SourceState.failed, error: e is SourceException ? e.message : e.toString());
          })
          .whenComplete(() {
            pending--;
            emit();
            ctrl.close();
          });
      return;
    }
    final useCombos = opts.moreAlternatives && wanted.contains('flix') && !opts.dticketOnly && breaker.pausedFor('flix') == null;
    if (!useCombos) {
      ctrl.close();
      return;
    }
    status['flixcombo'] = const SourceStatus(SourceState.loading);
    pending++;
    emit();
    final seed = mergeJourneys(lists.values);
    final combos = FlixCombos(flixSource, transitousSource);
    final sw = Stopwatch()..start();
    Future.wait([combos.find(from, to, opts, seed), combos.enrich(seed, opts)])
        .timeout(_sourceTimeout)
        .then((r) {
          final list = usefulCombos(r[0].where((j) => _inWindow(j, opts)).toList(), seed) + r[1];
          lists['flixcombo'] = list;
          status['flixcombo'] = SourceStatus(SourceState.ok, count: r[0].length, ms: sw.elapsedMilliseconds);
        })
        .catchError((Object e) {
          status['flixcombo'] = SourceStatus(SourceState.failed, error: e is TimeoutException ? 'timeout' : e.toString());
        })
        .whenComplete(() {
          pending--;
          emit();
          ctrl.close();
        });
  }

  for (final id in wanted) {
    final src = sources[id];
    if (src == null) continue;
    final paused = breaker.pausedFor(id);
    if (paused != null) {
      status[id] = SourceStatus(SourceState.paused, error: 'paused for ${(paused.inSeconds / 60).ceil()} min after errors');
      continue;
    }
    if (kIsWeb && !src.corsFriendly && Net.instance.webProxy.isEmpty) {
      status[id] = const SourceStatus(SourceState.skipped, error: 'needs the web proxy (Settings)');
      continue;
    }
    status[id] = const SourceStatus(SourceState.loading);
    pending++;
    final sw = Stopwatch()..start();
    // Transitous and the offline router route from any coordinate; the others only know stations.
    final fromAnywhere = id == 'transitous' || id == 'offline';
    (fromAnywhere ? src.journeys(from, to, opts) : _viaStations(src, from, to, opts))
        .timeout(_sourceTimeout)
        .then((all) {
          // Sanity window: never show connections from another day because an API misread the time.
          final list = all.where((j) => _inWindow(j, opts)).toList();
          breaker.success(id);
          lists[id] = list;
          status[id] = SourceStatus(SourceState.ok, count: list.length, ms: sw.elapsedMilliseconds);
        })
        .catchError((Object e) {
          final se = e is SourceException ? e : null;
          final msg = e is TimeoutException ? 'no answer within ${_sourceTimeout.inSeconds} s' : (se?.message ?? e.toString());
          breaker.failure(id, cooldownSeconds: se?.cooldown);
          status[id] = SourceStatus(SourceState.failed, error: msg, ms: sw.elapsedMilliseconds);
        })
        .whenComplete(() {
          pending--;
          emit();
          if (pending == 0) runCombos();
        });
  }

  if (pending == 0) {
    scheduleMicrotask(() {
      emit();
      runCombos();
    });
  } else {
    scheduleMicrotask(emit); // show "loading" statuses right away
  }
  return ctrl.stream;
}

/// Nearest stop for an address/place: (station, walking minutes). Stops are returned as they are.
Future<(Place, int)> stationFor(Place p) async {
  if (p.isStop || !p.hasCoords) return (p, 0);
  final near = await cache.get('near:${p.lat!.toStringAsFixed(4)},${p.lon!.toStringAsFixed(4)}', const Duration(hours: 6), () {
    return transitousSource.nearby(p.lat!, p.lon!);
  });
  final s = near.where((x) => x.isStop && x.hasCoords).firstOrNull;
  if (s == null) throw SourceException('no stop near ${p.name}');
  // Streets aren't straight: ~1.3× the direct distance at ~4.5 km/h.
  final minutes = (placeDist(p, s) * 1.3 / 4.5 * 60).ceil().clamp(1, 60);
  return (s, minutes);
}

Leg _walkLeg(Place from, Place to, DateTime dep, int minutes) => Leg(
  mode: Mode.walk,
  line: 'Walk',
  from: from,
  to: to,
  dep: dep,
  arr: dep.add(Duration(minutes: minutes)),
  walkDistance: placeDist(from, to) * 1300,
  path: [
    [from.lat!, from.lon!],
    [to.lat!, to.lon!],
  ],
);

/// Runs a station-only source for an address/place: searches from/to the nearest stop and adds the walks.
Future<List<Journey>> _viaStations(Source src, Place from, Place to, SearchOptions opts) async {
  if (from.isStop && to.isStop) return src.journeys(from, to, opts);
  final (a, walkIn) = await stationFor(from);
  final (b, walkOut) = await stationFor(to);
  final shifted = SearchOptions(
    when: opts.arriveBy ? opts.when.subtract(Duration(minutes: walkOut)) : opts.when.add(Duration(minutes: walkIn)),
    arriveBy: opts.arriveBy,
    minTransferMinutes: opts.minTransferMinutes,
    maxTransfers: opts.maxTransfers,
    bahncard: opts.bahncard,
    firstClass: opts.firstClass,
    dticket: opts.dticket,
    dticketOnly: opts.dticketOnly,
    bike: opts.bike,
    coach: opts.coach,
    age: opts.age,
    results: opts.results,
    maxWalkMinutes: opts.maxWalkMinutes,
    includeWalking: false,
    moreAlternatives: opts.moreAlternatives,
  );
  final list = await src.journeys(a, b, shifted);
  return [
    for (final j in list)
      Journey(
        source: j.source,
        sources: j.sources,
        legs: [
          if (walkIn > 0) _walkLeg(from, a, j.departure.subtract(Duration(minutes: walkIn)), walkIn),
          ...j.legs,
          if (walkOut > 0) _walkLeg(b, to, j.arrival, walkOut),
        ],
        prices: j.prices,
        dticket: j.dticket,
        soldOut: j.soldOut,
        bookingUrls: j.bookingUrls,
      ),
  ];
}

bool _inWindow(Journey j, SearchOptions o) {
  const slack = Duration(hours: 2);
  return o.arriveBy
      ? j.arrival.isBefore(o.when.add(slack)) && j.arrival.isAfter(o.when.subtract(const Duration(hours: 30)))
      : j.departure.isAfter(o.when.subtract(slack)) && j.departure.isBefore(o.when.add(const Duration(hours: 30)));
}

/// Station suggestions from DB and Transitous, deduplicated by name/proximity.
Future<List<Place>> searchLocations(String q, {bool offlineOnly = false}) async {
  if (offlineOnly) return offlineSource.locations(q).catchError((_) => <Place>[]);
  final results = await Future.wait<List<Place>>([
    if (!kIsWeb || Net.instance.webProxy.isNotEmpty) dbSource.locations(q).catchError((_) => <Place>[]),
    transitousSource.locations(q).catchError((_) => <Place>[]),
  ]);
  final addresses = transitousSource.addresses(q).catchError((_) => <Place>[]);
  final out = <Place>[];
  for (final list in results) {
    for (final l in list) {
      final i = out.indexWhere((o) => o.name.toLowerCase() == l.name.toLowerCase() || placeDist(o, l) < 0.3);
      if (i >= 0) {
        out[i] = out[i].mergedWith(l);
      } else {
        out.add(l);
      }
    }
  }
  // Stations first, then addresses and places (duplicates of the same spot dropped).
  final stations = out.take(7).toList();
  final extra = <Place>[];
  for (final a in await addresses) {
    if (extra.length >= 5) break;
    if (extra.any((e) => placeDist(e, a) < 0.05 || e.name == a.name)) continue;
    extra.add(a);
  }
  // Offline (or both services down): station names from the downloaded timetable.
  if (stations.isEmpty && extra.isEmpty && OfflinePack.instance.available) {
    return offlineSource.locations(q).catchError((_) => <Place>[]);
  }
  return [...stations, ...extra];
}
