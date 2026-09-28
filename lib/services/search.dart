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
import '../sources/source.dart';
import '../sources/transitous.dart';
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
final oebbSource = OebbSource();

final Map<String, Source> sources = {'db': dbSource, 'transitous': transitousSource, 'flix': flixSource, 'oebb': oebbSource};

const _sourceTimeout = Duration(seconds: 30);

Stream<SearchResult> searchJourneys(Place from, Place to, SearchOptions opts, List<String> wanted, {bool hideTight = false}) {
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
    // Walking the whole way: only show it when it can compete with the trains.
    final fastest = merged
        .where((j) => !j.walkOnly && !j.cancelled)
        .map((j) => j.duration)
        .fold<int?>(null, (m, d) => m == null || d < m ? d : m);
    merged = merged.where((j) => !j.walkOnly || fastest == null || j.duration <= 30 || j.duration <= fastest * 1.4).toList();
    rankJourneys(merged, when: opts.when, arriveBy: opts.arriveBy, dticket: opts.dticket, minTransfer: opts.minTransferMinutes);
    ctrl.add(SearchResult(merged, Map.of(status), done: pending == 0, fetchedAt: DateTime.now()));
  }

  var combosStarted = false;

  // Phase 2, once the normal sources answered: Flix + feeder combinations built around the stations
  // those results pass through, plus Flix prices for FlixTrain legs other sources found.
  void runCombos() {
    if (combosStarted) return;
    combosStarted = true;
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
    src
        .journeys(from, to, opts)
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

bool _inWindow(Journey j, SearchOptions o) {
  const slack = Duration(hours: 2);
  return o.arriveBy
      ? j.arrival.isBefore(o.when.add(slack)) && j.arrival.isAfter(o.when.subtract(const Duration(hours: 30)))
      : j.departure.isAfter(o.when.subtract(slack)) && j.departure.isBefore(o.when.add(const Duration(hours: 30)));
}

/// Station suggestions from DB and Transitous, deduplicated by name/proximity.
Future<List<Place>> searchLocations(String q) async {
  final results = await Future.wait<List<Place>>([
    if (!kIsWeb || Net.instance.webProxy.isNotEmpty) dbSource.locations(q).catchError((_) => <Place>[]),
    transitousSource.locations(q).catchError((_) => <Place>[]),
  ]);
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
  return out.take(10).toList();
}
