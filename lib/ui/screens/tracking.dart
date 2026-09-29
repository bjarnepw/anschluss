import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/tiles/tile_cache.dart';
import '../../models/journey.dart';
import '../../services/live_analysis.dart';
import '../../services/location.dart';
import '../../services/search.dart';
import '../../services/store.dart';
import '../../sources/source.dart';
import '../../offline/offline_pack.dart';
import '../../services/trip_updates.dart';
import '../app_scope.dart';
import '../widgets/journey_card.dart';
import '../widgets/leg_list.dart';
import '../widgets/route_map.dart';
import '../widgets/trip_progress.dart';
import 'journey_detail.dart';

/// A saved trip: where you are now, live updates while online, everything stored for offline use.
class TripScreen extends StatefulWidget {
  final String tripId;
  const TripScreen({super.key, required this.tripId});

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> {
  bool _refreshing = false;
  TripRefreshResult? _last;
  double? _download; // 0..1 while pre-downloading map tiles

  // Live analysis
  Timer? _tick;
  final _loc = LocationService.instance;
  List<Journey> _alts = [];
  bool _altsLoading = false;
  DateTime? _altsAt;
  Place? _altsFrom;

  @override
  void initState() {
    super.initState();
    TripUpdater.instance?.addListener(_onChanges);
    _loc.position.addListener(_onPosition);
    _loc.resumeIfAllowed();
    // Re-evaluate every 15 s: where you should be moves on even without a new GPS fix.
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => _onPosition());
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  void _onPosition() {
    if (!mounted) return;
    setState(() {});
    final trip = context.store.tripById(widget.tripId);
    if (trip == null) return;
    final p = _loc.position.value;
    final live = analyseTrip(
      trip.journey,
      DateTime.now(),
      lat: p?.latitude,
      lon: p?.longitude,
      minTransfer: context.store.settings.minTransferMinutes,
    );
    // Something breaks: look for alternatives on our own (at most every 5 minutes).
    if (live.atRisk && (_altsAt == null || DateTime.now().difference(_altsAt!).inMinutes >= 5)) _findAlternatives(live);
  }

  /// Long-range search from where you'll be (next stop / your position) to the destination – also later
  /// and slower connections, so there is a plan B even when the next hour looks bad.
  Future<void> _findAlternatives(LiveAnalysis live) async {
    final store = context.store;
    final trip = store.tripById(widget.tripId);
    if (trip == null || _altsLoading || store.settings.offlineOnly && !OfflinePack.instance.available) return;
    final p = _loc.position.value;
    final now = DateTime.now();
    final from = alternativesStart(trip.journey, now, lat: p?.latitude, lon: p?.longitude, here: context.s.myLocation);
    // Earliest you can start from there: arrival at the next stop incl. the estimated delay.
    var when = now;
    final leg = live.leg;
    if (leg != null && !now.isBefore(leg.dep)) {
      final next = leg.stops.where((x) => (x.arr ?? x.dep)?.isAfter(now) ?? false).firstOrNull;
      final base = (next?.arr ?? next?.dep) ?? leg.arr;
      when = base.add(Duration(minutes: live.effectiveDelay - live.officialDelay));
    }
    setState(() {
      _altsLoading = true;
      _altsAt = now;
      _altsFrom = from;
    });
    final opts = SearchOptions.from(store.settings, when);
    final wide = SearchOptions(
      when: opts.when,
      minTransferMinutes: opts.minTransferMinutes,
      bahncard: opts.bahncard,
      firstClass: opts.firstClass,
      dticket: opts.dticket,
      bike: opts.bike,
      coach: opts.coach,
      age: opts.age,
      results: 10, // long-term: more and later options
      maxWalkMinutes: opts.maxWalkMinutes,
      includeWalking: opts.includeWalking,
      moreAlternatives: true,
    );
    SearchResult? last;
    try {
      await for (final r in searchJourneys(from, trip.route.to, wide, store.settings.sources, offlineOnly: store.settings.offlineOnly)) {
        last = r;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _altsLoading = false;
      _alts = (last?.journeys ?? const <Journey>[]).where((x) => !x.cancelled && x.id != trip.journey.id).toList()
        ..sort((a, b) => a.arrival.compareTo(b.arrival));
    });
  }

  @override
  void dispose() {
    TripUpdater.instance?.removeListener(_onChanges);
    _loc.position.removeListener(_onPosition);
    _tick?.cancel();
    super.dispose();
  }

  void _onChanges(String id, List<String> changes) {
    if (id != widget.tripId || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(changes.join('\n')), duration: const Duration(seconds: 8)));
  }

  Future<void> _refresh() async {
    final u = TripUpdater.instance;
    if (u == null || _refreshing) return;
    setState(() => _refreshing = true);
    final r = await u.refresh(widget.tripId);
    if (mounted) {
      setState(() {
        _refreshing = false;
        _last = r;
      });
    }
  }

  Future<void> _downloadMap(Journey j) async {
    final s = context.s;
    final template = context.store.settings.tileUrl;
    final path = [
      for (final l in j.legs)
        for (final p in l.path) LatLng(p[0], p[1]),
    ];
    setState(() => _download = 0);
    try {
      final n = await prefetchRoute(template, path, onProgress: (d, t) => mounted ? setState(() => _download = d / t) : null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.de ? '$n Kartenkacheln gespeichert' : '$n map tiles saved')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _download = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final store = context.store;
    final trip = store.tripById(widget.tripId);
    if (trip == null) return Scaffold(appBar: AppBar(), body: const SizedBox.shrink());
    final j = trip.journey;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final minTransfer = store.settings.minTransferMinutes;
    final risky = j.transferList.where((x) => x.buffer < 0 || (minTransfer > 0 && x.buffer < minTransfer)).toList();
    final offline = _last?.outcome == RefreshOutcome.offline;
    final lost = _last?.outcome == RefreshOutcome.notFound;
    final canPrefetch = !kIsWeb && prefetchAllowed(store.settings.tileUrl);
    final pos = _loc.position.value;
    final live = analyseTrip(j, DateTime.now(), lat: pos?.latitude, lon: pos?.longitude, minTransfer: minTransfer);

    return Scaffold(
      appBar: AppBar(
        title: Text('${trip.route.from.name} → ${trip.route.to.name}', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: s.retry,
            icon: _refreshing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: _refreshing ? null : _refresh,
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'details') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => JourneyDetailScreen(journey: j, route: trip.route),
                  ),
                );
              } else if (v == 'delete') {
                store.removeTrip(trip.id);
                Navigator.pop(context);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'details', child: Text(s.details)),
              PopupMenuItem(value: 'delete', child: Text(s.de ? 'Reise löschen' : 'Delete trip')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            TripProgressCard(journey: j),
            const SizedBox(height: 8),
            _LiveCard(
              live: live,
              hasGps: pos != null,
              loading: _altsLoading,
              onAlternatives: () => _findAlternatives(live),
              onLocate: () async {
                await _loc.enable();
                _onPosition();
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(offline ? Icons.cloud_off : Icons.cloud_done_outlined, size: 16, color: cs.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    offline
                        ? (s.de ? 'Offline – gespeicherter Stand von ' : 'Offline – saved data from ') +
                              (trip.updatedAt != null ? fmtAgo(trip.updatedAt!, s.de) : '?')
                        : trip.updatedAt != null
                        ? s.updated(fmtTime(trip.updatedAt!))
                        : s.loading,
                    style: t.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (lost)
              _Banner(color: cs.errorContainer, onColor: cs.onErrorContainer, icon: Icons.warning_amber_rounded, text: s.notFoundAnymore),
            for (final x in risky)
              _Banner(
                color: x.buffer < 0 ? cs.errorContainer : Colors.orange.withValues(alpha: 0.18),
                onColor: x.buffer < 0 ? cs.onErrorContainer : Colors.orange.shade900,
                icon: Icons.directions_run,
                text:
                    '${x.buffer < 0 ? s.missedTransfer : s.tightTransfer(x.buffer)} – ${x.departing.from.name}: '
                    '${x.arriving.line} ${fmtTime(x.arriving.arr)} → ${x.departing.line} ${fmtTime(x.departing.dep)}',
              ),
            if (trip.changes.isNotEmpty)
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: Text(s.de ? 'Änderungen (${trip.changes.length})' : 'Changes (${trip.changes.length})'),
                  subtitle: Text(trip.changes.first, maxLines: 1, overflow: TextOverflow.ellipsis),
                  children: [for (final c in trip.changes) ListTile(dense: true, title: Text(c))],
                ),
              ),
            const SizedBox(height: 12),
            JourneyStrip(journey: j, detailed: true),
            const SizedBox(height: 12),
            SizedBox(
              height: 300,
              child: RouteMap(
                journey: j,
                expected: live.expected,
                onGeometry: (g) => store.updateTrip(trip.copyWith(journey: g)),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.download_for_offline_outlined, size: 16, color: cs.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    kIsWeb
                        ? (s.de ? 'Offline-Karte nur in der App verfügbar.' : 'Offline map only in the app.')
                        : canPrefetch
                        ? (s.de ? 'Karte entlang der Strecke offline speichern' : 'Save the map along the route for offline use')
                        : (s.de
                              ? 'Angesehene Kartenausschnitte bleiben offline verfügbar. Für komplette Offline-Karten einen eigenen Kartenserver in den Einstellungen eintragen (OpenStreetMap erlaubt keine Massen-Downloads).'
                              : 'Map areas you viewed stay available offline. For full offline maps set your own tile server in Settings (OpenStreetMap does not allow bulk downloads).'),
                    style: t.bodySmall,
                  ),
                ),
                if (canPrefetch)
                  _download != null
                      ? SizedBox(width: 36, height: 36, child: CircularProgressIndicator(value: _download))
                      : TextButton(onPressed: () => _downloadMap(j), child: Text(s.de ? 'Laden' : 'Download')),
              ],
            ),
            const SizedBox(height: 12),
            LegList(journey: j),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: bookingButtons(context, j)),
            if (_alts.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('${s.alternatives}${_altsFrom != null ? ' ${s.de ? 'ab' : 'from'} ${_altsFrom!.name}' : ''}', style: t.titleMedium),
              const SizedBox(height: 8),
              for (final a in _alts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: JourneyCard(
                    journey: a,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => JourneyDetailScreen(journey: a, route: SavedRoute(_altsFrom ?? a.legs.first.from, trip.route.to)),
                      ),
                    ),
                  ),
                ),
            ],
            if (lost && _last!.alternatives.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(s.alternatives, style: t.titleMedium),
              const SizedBox(height: 8),
              for (final a in _last!.alternatives)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: JourneyCard(
                    journey: a,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => JourneyDetailScreen(journey: a, route: trip.route),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// All saved trips: upcoming first, then the ones that just ended.
class TripsScreen extends StatelessWidget {
  const TripsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final store = context.store;
    final trips = store.trips;
    final upcoming = trips.where((t) => !t.finished).toList();
    final past = trips.where((t) => t.finished).toList().reversed.toList();
    return Scaffold(
      appBar: AppBar(title: Text(s.de ? 'Meine Reisen' : 'My trips')),
      body: trips.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  s.de
                      ? 'Noch keine gespeicherten Reisen.\nÖffne eine Verbindung und tippe auf „Reise speichern“ – sie ist dann auch offline verfügbar und wird unterwegs aktualisiert.'
                      : 'No saved trips yet.\nOpen a connection and tap “Save trip” – it is then available offline and updated on the go.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final (label, list) in [(s.de ? 'Anstehend' : 'Upcoming', upcoming), (s.de ? 'Vergangen' : 'Past', past)])
                  if (list.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                      child: Text(label, style: Theme.of(context).textTheme.titleSmall),
                    ),
                    for (final t in list)
                      Dismissible(
                        key: ValueKey(t.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 24),
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: const Icon(Icons.delete_outline),
                        ),
                        onDismissed: (_) => store.removeTrip(t.id),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                                child: Text(
                                  '${t.route.from.name} → ${t.route.to.name} · ${fmtDate(t.journey.departure, s.de)}',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                              ),
                              JourneyCard(
                                journey: t.journey,
                                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TripScreen(tripId: t.id))),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
              ],
            ),
    );
  }
}

class _Banner extends StatelessWidget {
  final Color color, onColor;
  final IconData icon;
  final String text;
  const _Banner({required this.color, required this.onColor, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
    child: Row(
      children: [
        Icon(icon, color: onColor),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: onColor, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

/// Live check: official delay vs. what your position says, distance to where you should be, and warnings.
class _LiveCard extends StatelessWidget {
  final LiveAnalysis live;
  final bool hasGps;
  final bool loading;
  final VoidCallback onAlternatives;
  final VoidCallback onLocate;
  const _LiveCard({required this.live, required this.hasGps, required this.loading, required this.onAlternatives, required this.onLocate});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    if (live.leg == null) return const SizedBox.shrink();
    String delay(int m) => m <= 0 ? (s.de ? 'pünktlich' : 'on time') : '+$m min';
    Color delayColor(int m) => m <= 0 ? Colors.green.shade600 : (m < 5 ? Colors.orange.shade700 : Colors.red.shade600);

    final rows = <Widget>[
      _row(context, Icons.campaign_outlined, s.de ? 'Offiziell' : 'Official', delay(live.officialDelay), delayColor(live.officialDelay)),
      if (live.gpsDelay != null)
        _row(
          context,
          Icons.gps_fixed,
          s.de ? 'Laut deiner Position' : 'From your position',
          delay(live.gpsDelay!),
          delayColor(live.gpsDelay!),
        ),
      if (live.offsetKm != null && !live.offRoute)
        _row(
          context,
          Icons.straighten,
          s.de ? 'Abstand Soll ↔ Ist' : 'Planned ↔ actual',
          live.offsetKm! < 1 ? '${(live.offsetKm! * 1000).round()} m' : '${live.offsetKm!.toStringAsFixed(1)} km',
          null,
        ),
    ];
    final warnings = <String>[
      if (live.offRoute)
        s.de
            ? 'Du bist nicht auf der Strecke – nicht im Zug oder GPS ungenau.'
            : "You're not on the route – not on the train, or GPS is inaccurate.",
      if (live.reachStation != null && live.reachStation!.$1 > live.reachStation!.$2)
        s.de
            ? 'Zu Fuß brauchst du ca. ${live.reachStation!.$1} min zum Bahnhof, Abfahrt in ${live.reachStation!.$2} min.'
            : 'Walking to the station takes about ${live.reachStation!.$1} min, departure in ${live.reachStation!.$2} min.',
      for (final r in live.risks)
        r.buffer < 0
            ? (s.de
                  ? 'Anschluss in ${r.transfer.departing.from.name} (${r.transfer.departing.line}) wird knapp verpasst (${r.buffer} min).'
                  : 'Connection at ${r.transfer.departing.from.name} (${r.transfer.departing.line}) will be missed (${r.buffer} min).')
            : (s.de
                  ? 'Nur noch ${r.buffer} min Umstieg in ${r.transfer.departing.from.name}.'
                  : 'Only ${r.buffer} min to change at ${r.transfer.departing.from.name}.'),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.insights, color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.de ? 'Live-Analyse' : 'Live analysis', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                ),
                if (!hasGps)
                  TextButton.icon(
                    onPressed: onLocate,
                    icon: const Icon(Icons.my_location, size: 18),
                    label: Text(s.de ? 'Standort nutzen' : 'Use location'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            ...rows,
            for (final w in warnings)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        w,
                        style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: loading ? null : onAlternatives,
                icon: loading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.alt_route),
                label: Text(s.de ? 'Alternativen ab hier' : 'Alternatives from here'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, String value, Color? color) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(child: Text(label)),
        Capsule(text: value, color: color),
      ],
    ),
  );
}
