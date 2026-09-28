// Keeps saved trips current: re-queries the sources for the same connection (matched by planned times
// and train numbers), stores the fresh data on the device and records what changed.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/journey.dart';
import '../offline/offline_pack.dart';
import '../sources/source.dart';
import '../ui/strings.dart';
import 'merge.dart';
import 'search.dart';
import 'store.dart';

enum RefreshOutcome { updated, notFound, offline }

class TripRefreshResult {
  final RefreshOutcome outcome;
  final List<String> changes;
  final List<Journey> alternatives;
  final String? error;
  const TripRefreshResult(this.outcome, {this.changes = const [], this.alternatives = const [], this.error});
}

/// Human-readable differences between two versions of the same journey.
List<String> diffJourneys(Journey old, Journey neu, S s) {
  final out = <String>[];
  final a = old.transit, b = neu.transit;
  if (a.length != b.length) return [s.de ? 'Verbindung hat sich geändert' : 'Connection has changed'];
  for (var i = 0; i < a.length; i++) {
    final o = a[i], n = b[i];
    if (!o.cancelled && n.cancelled) out.add(s.de ? '${n.line} fällt aus' : '${n.line} is cancelled');
    if ((o.depDelay ?? 0) != (n.depDelay ?? 0) && (n.depDelay ?? 0) != 0 || (o.depDelay ?? 0) > 0 && (n.depDelay ?? 0) == 0) {
      final d = n.depDelay ?? 0;
      out.add(
        s.de
            ? '${n.line} ab ${n.from.name}: ${d > 0 ? '+$d min' : 'wieder pünktlich'}'
            : '${n.line} from ${n.from.name}: ${d > 0 ? '+$d min' : 'on time again'}',
      );
    }
    if (o.depPlatform != null && n.depPlatform != null && o.depPlatform != n.depPlatform) {
      out.add(
        s.de
            ? 'Gleiswechsel ${n.from.name}: ${n.line} jetzt Gl. ${n.depPlatform} (statt ${o.depPlatform})'
            : 'Platform change at ${n.from.name}: ${n.line} now Pl. ${n.depPlatform} (was ${o.depPlatform})',
      );
    }
    if (o.arrPlatform != null && n.arrPlatform != null && o.arrPlatform != n.arrPlatform) {
      out.add(
        s.de
            ? 'Ankunft ${n.to.name} jetzt Gl. ${n.arrPlatform} (statt ${o.arrPlatform})'
            : 'Arrival at ${n.to.name} now Pl. ${n.arrPlatform} (was ${o.arrPlatform})',
      );
    }
  }
  final ob = old.tightestBuffer, nb = neu.tightestBuffer;
  if (ob != null && nb != null && nb < 0 && ob >= 0) out.add(s.de ? 'Anschluss gefährdet!' : 'Connection at risk!');
  return out;
}

class TripUpdater with WidgetsBindingObserver {
  /// The app-wide instance (set in main).
  static TripUpdater? instance;

  final AppStore store;
  Timer? _timer;
  final _running = <String>{};

  /// Called with (trip id, changes) whenever a refresh found something new – the UI shows a banner.
  final _listeners = <void Function(String, List<String>)>[];

  TripUpdater(this.store);

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _schedule();
    refreshActive();
    _checkOffline();
  }

  /// Keep the offline timetable current (construction work, cancellations …) – cheap check, at most every 12 h.
  void _checkOffline() {
    if (store.settings.offlineOnly) return;
    OfflinePack.instance.checkForUpdate(autoDownload: store.settings.autoUpdateOffline);
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: store.settings.trackRefreshSeconds), (_) => refreshActive());
  }

  void addListener(void Function(String, List<String>) f) => _listeners.add(f);
  void removeListener(void Function(String, List<String>) f) => _listeners.remove(f);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _schedule();
      refreshActive(); // coming back to the app: get fresh data right away
      _checkOffline();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
    }
  }

  /// Refreshes trips that are underway or start within the next hours.
  Future<void> refreshActive() async {
    final now = DateTime.now();
    for (final t in [...store.trips]) {
      final soon = t.journey.departure.difference(now).inHours < 6;
      final notOver = t.journey.arrival.isAfter(now.subtract(const Duration(minutes: 30)));
      if (soon && notOver) await refresh(t.id);
    }
  }

  Future<TripRefreshResult> refresh(String id) async {
    final trip = store.tripById(id);
    if (store.settings.offlineOnly) return const TripRefreshResult(RefreshOutcome.offline);
    if (trip == null || !_running.add(id)) return const TripRefreshResult(RefreshOutcome.offline);
    try {
      final s = S(store.settings.language);
      final st = store.settings;
      // Search without the user's filters so the saved connection is found whenever it still runs.
      final opts = SearchOptions(
        when: trip.journey.plannedDeparture.subtract(const Duration(minutes: 1)),
        bahncard: st.bahncard,
        firstClass: st.firstClass,
        dticket: st.dticket,
        bike: st.bike,
        coach: true,
        age: st.age,
        results: 6,
        moreAlternatives: false,
        includeWalking: false,
      );
      SearchResult? last;
      await for (final r in searchJourneys(trip.route.from, trip.route.to, opts, st.sources)) {
        last = r;
      }
      if (last == null || !last.status.values.any((x) => x.state == SourceState.ok)) {
        final err = last?.status.values.map((x) => x.error).whereType<String>().firstOrNull;
        return TripRefreshResult(RefreshOutcome.offline, error: err);
      }
      final found = last.journeys.where((j) => sameJourney(j, trip.journey)).firstOrNull;
      if (found == null) {
        final alts = last.journeys.where((j) => j.departure.isAfter(DateTime.now()) && !j.cancelled).take(3).toList();
        return TripRefreshResult(RefreshOutcome.notFound, alternatives: alts);
      }
      // Keep the id stable even if a source reports slightly different planned times.
      found.id = trip.id;
      final changes = diffJourneys(trip.journey, found, s);
      final stamp = '${_hhmm(DateTime.now())} ';
      store.updateTrip(
        trip.copyWith(
          journey: found,
          updatedAt: DateTime.now(),
          changes: [...changes.map((c) => '$stamp$c'), ...trip.changes].take(30).toList(),
        ),
      );
      if (changes.isNotEmpty) {
        for (final l in [..._listeners]) {
          l(id, changes);
        }
      }
      return TripRefreshResult(RefreshOutcome.updated, changes: changes);
    } catch (e) {
      return TripRefreshResult(RefreshOutcome.offline, error: e.toString());
    } finally {
      _running.remove(id);
    }
  }

  static String _hhmm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
