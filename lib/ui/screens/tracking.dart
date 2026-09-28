import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/tiles/tile_cache.dart';
import '../../models/journey.dart';
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

  @override
  void initState() {
    super.initState();
    TripUpdater.instance?.addListener(_onChanges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    TripUpdater.instance?.removeListener(_onChanges);
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
            SizedBox(height: 300, child: RouteMap(journey: j)),
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
