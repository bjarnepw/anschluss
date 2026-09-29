import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/journey.dart';
import '../../services/search.dart';
import '../../services/store.dart';
import '../../sources/source.dart';
import '../app_scope.dart';
import '../widgets/journey_card.dart';
import 'trips_screen.dart';

/// Favourite routes with their next departures; tap to search it on the map.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

/// Next departures per favourite, kept for a few minutes so switching tabs doesn't re-query.
final _nextCache = <String, (DateTime, List<Journey>)>{};

class _FavoritesScreenState extends State<FavoritesScreen> {
  final _loading = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  void _loadAll({bool force = false}) {
    for (final r in context.store.favorites) {
      _load(r, force: force);
    }
  }

  Future<void> _load(SavedRoute r, {bool force = false}) async {
    final hit = _nextCache[r.key];
    if (!force && hit != null && DateTime.now().difference(hit.$1).inMinutes < 5) return;
    if (!_loading.add(r.key)) return;
    setState(() {});
    final st = context.store.settings;
    // Quick look only: the fast sources, no combos – the full search happens on the map.
    final opts = SearchOptions(
      when: DateTime.now(),
      minTransferMinutes: st.minTransferMinutes,
      dticket: st.dticket,
      bahncard: st.bahncard,
      firstClass: st.firstClass,
      coach: st.coach,
      results: 4,
      moreAlternatives: false,
      includeWalking: false,
    );
    final wanted = st.offlineOnly ? const ['offline'] : st.sources.where((x) => x == 'transitous' || x == 'db').toList();
    SearchResult? last;
    try {
      await for (final res in searchJourneys(r.from, r.to, opts, wanted, offlineOnly: st.offlineOnly)) {
        last = res;
      }
    } catch (_) {}
    final list = [...?last?.journeys]
      ..removeWhere((j) => j.walkOnly || j.cancelled || j.departure.isBefore(DateTime.now().subtract(const Duration(minutes: 1))))
      ..sort((a, b) => a.departure.compareTo(b.departure));
    _nextCache[r.key] = (DateTime.now(), list.take(3).toList());
    _loading.remove(r.key);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final store = context.store;
    final favs = store.favorites;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.favorites),
        actions: [
          if (favs.isNotEmpty) IconButton(tooltip: s.retry, icon: const Icon(Icons.refresh), onPressed: () => _loadAll(force: true)),
        ],
      ),
      body: favs.isEmpty
          ? EmptyState(
              icon: Icons.star_outline_rounded,
              title: s.de ? 'Noch keine Favoriten' : 'No favourites yet',
              text: s.de
                  ? 'Tippe beim Suchen auf den Stern neben Start und Ziel. Deine Favoriten zeigen hier direkt die nächsten Abfahrten.'
                  : 'Tap the star next to start and destination when searching. Your favourites then show their next departures here.',
            )
          : RefreshIndicator(
              onRefresh: () async => _loadAll(force: true),
              child: ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                itemCount: favs.length,
                onReorderItem: store.reorderFavorites,
                itemBuilder: (context, i) {
                  final r = favs[i];
                  return Dismissible(
                    key: ValueKey(r.key),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.delete_outline),
                    ),
                    onDismissed: (_) => store.removeFavorite(r),
                    child: _FavoriteCard(route: r, next: _nextCache[r.key]?.$2, loading: _loading.contains(r.key)),
                  );
                },
              ),
            ),
    );
  }
}

class _FavoriteCard extends StatelessWidget {
  final SavedRoute route;
  final List<Journey>? next;
  final bool loading;
  const _FavoriteCard({required this.route, required this.next, required this.loading});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final store = context.store;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => store.searchRoute(route),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.star_rounded, color: Colors.amber.shade700),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            route.from.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          Text('→ ${route.to.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: s.de ? 'Rückfahrt suchen' : 'Search the way back',
                      icon: const Icon(Icons.swap_vert),
                      onPressed: () => store.searchRoute(SavedRoute(route.to, route.from)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (loading && next == null)
                  const LinearProgressIndicator()
                else if (next == null || next!.isEmpty)
                  Text(s.de ? 'Keine Abfahrten gefunden' : 'No departures found', style: TextStyle(color: cs.onSurfaceVariant))
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final j in next!)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(fmtTime(j.departure), style: const TextStyle(fontWeight: FontWeight.w800)),
                                  DelayText(j.legs.firstWhere((l) => !l.isWalk, orElse: () => j.legs.first).depDelay),
                                ],
                              ),
                              Text(
                                '${fmtDur(j.duration)} · ${j.transfers == 0 ? s.direct : '${j.transfers}×'}',
                                style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
