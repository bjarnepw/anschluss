import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/journey.dart';
import '../../services/merge.dart';
import '../../services/search.dart';
import '../../services/store.dart';
import '../../sources/source.dart';
import '../app_scope.dart';
import '../widgets/journey_card.dart';
import '../widgets/leg_list.dart';
import '../widgets/route_map.dart';
import 'journey_detail.dart';

/// Follows a pinned journey: re-queries all sources periodically, picks the same connection
/// (matched by planned times) and warns when a transfer is getting too tight.
class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  Timer? _timer;
  bool _refreshing = false;
  bool _lost = false;
  DateTime? _updatedAt;
  String? _error;
  List<Journey> _alternatives = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    final secs = context.store.settings.trackRefreshSeconds;
    _timer = Timer.periodic(Duration(seconds: secs), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final store = AppScope.read(context);
    final tr = store.tracked;
    if (tr == null || _refreshing) return;
    if (tr.journey.arrival.isBefore(DateTime.now().subtract(const Duration(minutes: 30)))) {
      _timer?.cancel();
      return;
    }
    setState(() {
      _refreshing = true;
      _error = null;
    });
    final base = SearchOptions.from(store.settings, tr.journey.plannedDeparture.subtract(const Duration(minutes: 1)));
    // Search without the user's transfer filters so the tracked connection is always found if it still runs.
    final opts = SearchOptions(
      when: base.when,
      bahncard: base.bahncard,
      firstClass: base.firstClass,
      dticket: base.dticket,
      bike: base.bike,
      coach: true,
      age: base.age,
      results: 5,
    );
    SearchResult? last;
    try {
      await for (final r in searchJourneys(tr.route.from, tr.route.to, opts, store.settings.sources)) {
        last = r;
      }
    } catch (e) {
      _error = e.toString();
    }
    if (!mounted) return;
    final found = last?.journeys.where((j) => sameJourney(j, tr.journey)).firstOrNull;
    setState(() {
      _refreshing = false;
      _updatedAt = DateTime.now();
      if (found != null) {
        _lost = false;
        store.track(Tracked(found, tr.route));
      } else if (last != null && last.status.values.any((s) => s.state == SourceState.ok)) {
        _lost = true;
        _alternatives = last.journeys.where((j) => j.departure.isAfter(DateTime.now()) && !j.cancelled).take(3).toList();
      } else {
        _error ??= last?.status.values.map((s) => s.error).whereType<String>().firstOrNull;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final store = context.store;
    final tr = store.tracked;
    if (tr == null) {
      return Scaffold(appBar: AppBar(), body: const SizedBox.shrink());
    }
    final j = tr.journey;
    final minTransfer = store.settings.minTransferMinutes;
    final risky = j.transferList.where((t) => t.buffer < 0 || (minTransfer > 0 && t.buffer < minTransfer)).toList();
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.tracking),
        actions: [
          IconButton(
            tooltip: s.retry,
            icon: _refreshing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: _refreshing ? null : _refresh,
          ),
          IconButton(
            tooltip: s.stopTracking,
            icon: const Icon(Icons.location_off),
            onPressed: () {
              store.track(null);
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text('${tr.route.from.name} → ${tr.route.to.name}', style: Theme.of(context).textTheme.titleMedium),
            Text(_updatedAt == null ? s.loading : s.updated(fmtTime(_updatedAt!)), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (_lost)
              _Banner(color: cs.errorContainer, onColor: cs.onErrorContainer, icon: Icons.warning_amber_rounded, text: s.notFoundAnymore),
            for (final t in risky)
              _Banner(
                color: t.buffer < 0 ? cs.errorContainer : Colors.orange.withValues(alpha: 0.18),
                onColor: t.buffer < 0 ? cs.onErrorContainer : Colors.orange.shade900,
                icon: Icons.directions_run,
                text:
                    '${t.buffer < 0 ? s.missedTransfer : s.tightTransfer(t.buffer)} – ${t.departing.from.name}: '
                    '${t.arriving.line} ${fmtTime(t.arriving.arr)} → ${t.departing.line} ${fmtTime(t.departing.dep)}',
              ),
            if (_error != null) _Banner(color: cs.surfaceContainerHighest, onColor: cs.onSurface, icon: Icons.cloud_off, text: _error!),
            const SizedBox(height: 4),
            JourneyStrip(journey: j),
            const SizedBox(height: 12),
            SizedBox(height: 240, child: RouteMap(journey: j)),
            const SizedBox(height: 12),
            LegList(journey: j),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: bookingButtons(context, j)),
            if (_alternatives.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(s.alternatives, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final a in _alternatives)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: JourneyCard(
                    journey: a,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => JourneyDetailScreen(journey: a, route: tr.route),
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
