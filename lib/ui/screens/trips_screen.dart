import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/store.dart';
import '../../services/trip_updates.dart';
import '../app_scope.dart';
import '../widgets/countdown.dart';
import '../widgets/journey_card.dart';
import 'tracking.dart';

/// Overview of saved trips: underway, upcoming by day, and past ones folded away.
class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key});

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  Timer? _tick;
  bool _showPast = false;

  @override
  void initState() {
    super.initState();
    // Status chips ("in 12 min", "underway") change with time.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    await TripUpdater.instance?.refreshActive();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final store = context.store;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final ongoing = store.trips.where((x) => x.ongoing).toList();
    final upcoming = store.trips.where((x) => x.journey.departure.isAfter(now)).toList();
    final past = store.trips.where((x) => x.finished).toList().reversed.toList();

    // Upcoming grouped by day: Today / Tomorrow / Mon, 6.10.
    final byDay = <String, List<SavedTrip>>{};
    for (final x in upcoming) {
      final d = dayDiff(now, x.journey.departure);
      final label = d == 0
          ? (s.de ? 'Heute' : 'Today')
          : d == 1
          ? (s.de ? 'Morgen' : 'Tomorrow')
          : fmtDate(x.journey.departure, s.de);
      (byDay[label] ??= []).add(x);
    }

    Widget header(String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: t.titleSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w800),
            ),
          ),
          ?trailing,
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(s.de ? 'Meine Reisen' : 'My trips')),
      body: store.trips.isEmpty
          ? _Empty(
              icon: Icons.bookmark_add_outlined,
              title: s.de ? 'Noch keine Reisen gespeichert' : 'No saved trips yet',
              text: s.de
                  ? 'Öffne eine Verbindung und tippe auf „Reise speichern“. Sie ist dann auch offline da, zeigt dir unterwegs wo du bist und warnt bei Verspätungen.'
                  : 'Open a connection and tap “Save trip”. It is then available offline, shows where you are on the way and warns about delays.',
            )
          : RefreshIndicator(
              onRefresh: _refreshAll,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                children: [
                  if (ongoing.isNotEmpty) ...[
                    header(s.de ? 'Jetzt unterwegs' : 'Underway now'),
                    for (final x in ongoing) _TripTile(trip: x, highlight: true),
                  ],
                  for (final e in byDay.entries) ...[header(e.key), for (final x in e.value) _TripTile(trip: x)],
                  if (past.isNotEmpty) ...[
                    header(
                      s.de ? 'Vergangen (${past.length})' : 'Past (${past.length})',
                      trailing: TextButton(
                        onPressed: () => setState(() => _showPast = !_showPast),
                        child: Text(_showPast ? (s.de ? 'Ausblenden' : 'Hide') : (s.de ? 'Anzeigen' : 'Show')),
                      ),
                    ),
                    if (_showPast) ...[
                      for (final x in past) _TripTile(trip: x),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          icon: const Icon(Icons.delete_sweep_outlined),
                          label: Text(s.de ? 'Vergangene löschen' : 'Delete past trips'),
                          onPressed: () {
                            for (final x in past) {
                              store.removeTrip(x.id);
                            }
                          },
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
    );
  }
}

class _TripTile extends StatelessWidget {
  final SavedTrip trip;
  final bool highlight;
  const _TripTile({required this.trip, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final store = context.store;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final j = trip.journey;
    final now = DateTime.now();
    final delay = [
      for (final l in j.transit) ...[l.depDelay ?? 0, l.arrDelay ?? 0],
    ].fold(0, (m, d) => d > m ? d : m);
    final risk = (j.tightestBuffer ?? 99) < 0;

    final status = trip.finished
        ? Capsule(icon: Icons.flag_outlined, text: s.de ? 'Angekommen' : 'Arrived')
        : trip.ongoing
        ? Capsule(icon: Icons.train, text: s.de ? 'Unterwegs' : 'Underway', color: cs.primary)
        : null;

    return Dismissible(
      key: ValueKey(trip.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(20)),
        child: Icon(Icons.delete_outline, color: cs.onErrorContainer),
      ),
      onDismissed: (_) => store.removeTrip(trip.id),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Card(
          color: highlight ? cs.primaryContainer : null,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TripScreen(tripId: trip.id))),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${trip.route.from.name} → ${trip.route.to.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      if (!trip.finished)
                        Countdown(
                          target: trip.ongoing ? j.arrival : j.departure,
                          de: s.de,
                          showWithin: const Duration(hours: 24),
                          style: t.labelLarge?.copyWith(fontWeight: FontWeight.w800, color: cs.primary),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${fmtTime(j.departure)} – ${fmtTime(j.arrival)}${dayDiff(now, j.departure) > 1 ? ' · ${fmtDate(j.departure, s.de)}' : ''}',
                    style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  JourneyStrip(journey: j, height: 18),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ?status,
                      Capsule(icon: Icons.schedule, text: fmtDur(j.duration)),
                      Capsule(icon: Icons.swap_horiz, text: j.transfers == 0 ? s.direct : s.changes(j.transfers)),
                      if (delay > 0)
                        Capsule(
                          icon: Icons.warning_amber_rounded,
                          text: '+$delay min',
                          color: delay >= 5 ? Colors.red.shade600 : Colors.orange.shade700,
                        ),
                      if (risk) Capsule(icon: Icons.directions_run, text: s.missedTransfer, color: Colors.red.shade600),
                      if (trip.changes.isNotEmpty && !trip.finished)
                        Capsule(icon: Icons.notifications_active_outlined, text: '${trip.changes.length}', color: cs.tertiary),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title, text;
  const _Empty({super.key, required this.icon, required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: cs.primaryContainer,
              child: Icon(icon, size: 40, color: cs.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared empty state (also used by the favourites page).
class EmptyState extends _Empty {
  const EmptyState({super.key, required super.icon, required super.title, required super.text});
}
