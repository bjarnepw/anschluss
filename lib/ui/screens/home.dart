import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/net.dart';
import '../../models/journey.dart';
import '../../models/settings.dart';
import '../../services/merge.dart';
import '../../services/search.dart';
import '../../services/store.dart';
import '../../sources/source.dart';
import '../app_scope.dart';
import '../strings.dart';
import '../widgets/journey_card.dart';
import '../widgets/route_map.dart';
import 'journey_detail.dart';
import 'settings_screen.dart';
import 'station_picker.dart';
import 'tracking.dart';
import '../widgets/countdown.dart';
import '../widgets/intro.dart';
import '../widgets/time_picker_sheet.dart';

/// Map-first home: the map fills the screen, search + results live in a draggable bottom sheet
/// (phones) or a floating side panel (wide screens).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Place? _from, _to;
  DateTime? _when; // null = now
  bool _arriveBy = false;
  SortMode? _sort;
  SearchResult? _result;
  bool _searching = false;
  bool _loadingMore = false;
  bool _fromCache = false;
  StreamSubscription<SearchResult>? _sub;
  String? _selectedId;
  DateTime? _searchedWhen;

  final _sheet = DraggableScrollableController();
  static const _peekPx = 212.0; // grabber + compact search bar (plus the system gesture area)
  static const _halfFraction = 0.52;
  static const _fullFraction = 0.94;

  // The sheet must get identical snap sizes on every rebuild: a new list makes it re-snap (and
  // fight the finger) each time the screen rebuilds. Computed once per screen height.
  double? _sheetHeight;
  double _peekFraction = 0.25;
  List<double> _snaps = const [0.25, _halfFraction, _fullFraction];

  /// Sheet height in px, for map padding – only updated once the sheet has settled.
  final _sheetPx = ValueNotifier<double>(0);
  Timer? _settle;
  bool _dragging = false;

  // Search results arrive in bursts; repaint the list at most every 150 ms.
  Timer? _paintTimer;
  SearchResult? _pending;

  @override
  void initState() {
    super.initState();
    final store = AppScope.read(context);
    final last = store.lastSearch;
    if (last != null) {
      _from = last.route.from;
      _to = last.route.to;
      // Only show saved results while they are still relevant.
      final upcoming = last.journeys.where((j) => j.arrival.isAfter(DateTime.now())).toList();
      if (upcoming.isNotEmpty) {
        _result = SearchResult(upcoming, const {}, done: true, fetchedAt: last.fetchedAt);
        _fromCache = true;
        _searchedWhen = last.when;
        _arriveBy = last.arriveBy;
      }
    } else if (store.recentRoutes.isNotEmpty) {
      _from = store.recentRoutes.first.from;
      _to = store.recentRoutes.first.to;
    }
  }

  void _onSearchRequest() {
    final store = AppScope.read(context);
    final r = store.searchRequest.value;
    if (r == null) return;
    store.searchRequest.value = null;
    setState(() {
      _from = r.from;
      _to = r.to;
      _when = null;
    });
    _search();
  }

  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = AppScope.read(context);
    if (!_listening) {
      _listening = true;
      store.searchRequest.addListener(_onSearchRequest);
    }
    if (!store.settings.seenIntro && !_introShown) {
      _introShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        // Mark as seen right away, so it never shows twice (even if the app is closed meanwhile).
        store.updateSettings(store.settings.copyWith(seenIntro: true));
        await showIntro(context);
      });
    }
  }

  bool _introShown = false;

  @override
  void dispose() {
    AppScope.read(context).searchRequest.removeListener(_onSearchRequest);
    _sub?.cancel();
    _settle?.cancel();
    _paintTimer?.cancel();
    _sheetPx.dispose();
    _sheet.dispose();
    super.dispose();
  }

  void _moveSheet(double fraction) {
    if (!_sheet.isAttached || _dragging) return; // never fight the user's finger
    _sheet.animateTo(fraction, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
  }

  // ---------------- actions ----------------

  Future<void> _pick(bool from) async {
    final s = context.s;
    final p = await Navigator.push<Place>(
      context,
      MaterialPageRoute(
        builder: (_) => StationPicker(title: from ? s.from : s.to, initial: (from ? _from : _to)?.name ?? ''),
      ),
    );
    if (p == null || !mounted) return;
    setState(() {
      from ? _from = p : _to = p;
      _selectedId = null;
    });
    if (_from != null && _to != null) _search();
  }

  void _swap() {
    HapticFeedback.selectionClick();
    setState(() {
      final t = _from;
      _from = _to;
      _to = t;
    });
  }

  Future<void> _pickTime() async {
    final r = await showTimePickerSheet(context, initial: _when, arriveBy: _arriveBy);
    if (r == null || !mounted) return;
    setState(() {
      _when = r.when;
      _arriveBy = r.arriveBy;
    });
  }

  /// [keep]: add the new connections to the current list (earlier/later) instead of replacing it.
  Future<void> _search({DateTime? at, bool keep = false, bool? arriveBy}) async {
    final direction = arriveBy ?? _arriveBy;
    final store = context.store;
    final s = context.s;
    if (_from == null || _to == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.pickStations)));
      return;
    }
    if (at != null && !keep) _when = at;
    final when = at ?? _when ?? DateTime.now();
    final settings = store.settings;
    final from = _from!, to = _to!;
    store.rememberSearch(from, to);
    await _sub?.cancel();
    final previous = _result;
    final base = keep ? [...?previous?.journeys] : const <Journey>[];
    setState(() {
      _searching = true;
      _loadingMore = keep;
      _fromCache = false;
      if (!keep) {
        _selectedId = null;
        _searchedWhen = when;
        _result = null;
      }
    });
    if (_sheet.isAttached && _sheet.size < _halfFraction) _moveSheet(_halfFraction);
    final opts = SearchOptions.from(settings, when, arriveBy: direction);
    SearchResult? last;
    _sub = searchJourneys(from, to, opts, settings.sources, hideTight: settings.hideTightTransfers, offlineOnly: settings.offlineOnly)
        .listen(
          (snapshot) {
            var r = snapshot;
            if (keep) {
              final merged = mergeJourneys([base, r.journeys]);
              rankJourneys(
                merged,
                when: _searchedWhen ?? when,
                arriveBy: _arriveBy,
                dticket: settings.dticket,
                minTransfer: settings.minTransferMinutes,
              );
              r = SearchResult(merged, r.status, done: r.done, fetchedAt: r.fetchedAt);
            }
            last = r;
            _showThrottled(r);
          },
          onDone: () {
            if (!mounted) return;
            final r = last;
            _paintTimer?.cancel();
            _pending = null;
            setState(() {
              if (r != null) _result = r;
              _searching = false;
              _loadingMore = false;
            });
            if (r == null) return;
            if (r.journeys.isNotEmpty) {
              store.saveLastSearch(SavedSearch(SavedRoute(from, to), when, _arriveBy, r.journeys, r.fetchedAt));
            } else if (r.status.values.every((x) => x.state != SourceState.ok)) {
              // Everything failed (offline?): fall back to what we had for the same route.
              final cached = store.lastSearch;
              if (cached != null && cached.route.from.name == from.name && cached.route.to.name == to.name) {
                setState(() {
                  _result = SearchResult(cached.journeys, r.status, done: true, fetchedAt: cached.fetchedAt);
                  _fromCache = true;
                });
              } else if (previous != null && previous.journeys.isNotEmpty) {
                setState(() => _result = SearchResult(previous.journeys, r.status, done: true, fetchedAt: previous.fetchedAt));
              }
            }
          },
        );
  }

  void _showThrottled(SearchResult r) {
    _pending = r;
    if (_paintTimer?.isActive ?? false) return;
    if (mounted) setState(() => _result = r);
    _pending = null;
    _paintTimer = Timer(const Duration(milliseconds: 150), () {
      final p = _pending;
      _pending = null;
      if (p != null && mounted) setState(() => _result = p);
    });
  }

  /// Loads the connections right after the last one and adds them to the list.
  void _later() {
    final js = (_result?.journeys ?? const <Journey>[]).where((j) => !j.walkOnly);
    if (js.isEmpty) {
      _search(at: (_searchedWhen ?? DateTime.now()).add(const Duration(minutes: 30)), keep: true);
      return;
    }
    final lastDep = js.map((j) => j.departure).reduce((a, b) => a.isAfter(b) ? a : b);
    _searchKeepingDirection(lastDep.add(const Duration(minutes: 1)), arriveBy: false);
  }

  /// Loads the connections right before the first one and adds them to the list.
  void _earlier() {
    final js = (_result?.journeys ?? const <Journey>[]).where((j) => !j.walkOnly);
    if (js.isEmpty) {
      _search(at: (_searchedWhen ?? DateTime.now()).subtract(const Duration(minutes: 30)), keep: true);
      return;
    }
    final firstArr = js.map((j) => j.arrival).reduce((a, b) => a.isBefore(b) ? a : b);
    _searchKeepingDirection(firstArr.subtract(const Duration(minutes: 1)), arriveBy: true);
  }

  /// Earlier = "arrive before the first arrival", later = "depart after the last departure" – this gives
  /// exactly the neighbouring connections, independent of the user's own depart/arrive choice.
  void _searchKeepingDirection(DateTime at, {required bool arriveBy}) => _search(at: at.toLocal(), keep: true, arriveBy: arriveBy);

  void _openDetails(Journey j) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => JourneyDetailScreen(journey: j, route: SavedRoute(_from!, _to!)),
    ),
  );

  /// First tap shows the journey on the map, second tap opens the details.
  void _tapJourney(Journey j, bool wide) {
    if (_selectedId == j.id) {
      _openDetails(j);
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _selectedId = j.id);
    if (!wide && _sheet.isAttached && _sheet.size > _halfFraction) _moveSheet(_halfFraction);
  }

  // ---------------- data helpers ----------------

  List<Journey> _sorted(SortMode sort) {
    final js = [...?_result?.journeys];
    int byPrice(Journey a, Journey b) => (a.effectivePrice ?? double.infinity).compareTo(b.effectivePrice ?? double.infinity);
    js.sort(switch (sort) {
      SortMode.best => (a, b) => a.score.compareTo(b.score),
      SortMode.fast => (a, b) => a.duration != b.duration ? a.duration.compareTo(b.duration) : a.transfers.compareTo(b.transfers),
      SortMode.cheap => (a, b) => byPrice(a, b) != 0 ? byPrice(a, b) : a.duration.compareTo(b.duration),
      SortMode.early => (a, b) => a.arrival.compareTo(b.arrival),
      SortMode.transfers => (a, b) => a.transfers != b.transfers ? a.transfers.compareTo(b.transfers) : a.duration.compareTo(b.duration),
    });
    return js;
  }

  Map<String, String> _highlights(S s) {
    final ok = (_result?.journeys ?? const <Journey>[]).where((j) => !j.cancelled && !j.soldOut).toList();
    if (ok.length < 2) return {};
    String pick(int Function(Journey, Journey) f) => ([...ok]..sort(f)).first.id;
    final out = <String, String>{};
    out[pick((a, b) => a.duration.compareTo(b.duration))] = s.fastest;
    if (ok.any((j) => j.effectivePrice != null)) {
      out[pick((a, b) => (a.effectivePrice ?? double.infinity).compareTo(b.effectivePrice ?? double.infinity))] = s.cheapest;
    }
    out[pick((a, b) => a.score.compareTo(b.score))] = s.bestOverall;
    return out;
  }

  Journey? get _mapJourney {
    final js = _result?.journeys ?? const <Journey>[];
    if (js.isEmpty) return null;
    return js.where((j) => j.id == _selectedId).firstOrNull ?? _sorted(_sort ?? context.store.settings.defaultSort).first;
  }

  // ---------------- layout ----------------

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 900;
        final media = MediaQuery.of(context);
        final topInset = media.padding.top;
        final pins = [?_from, ?_to];

        if (!wide) _ensureSnaps(c.maxHeight, media.viewPadding.bottom);
        final trip = store.activeTrip;

        // The map rebuilds only when the sheet has settled (not while dragging).
        final map = RepaintBoundary(
          child: ValueListenableBuilder<double>(
            valueListenable: _sheetPx,
            builder: (context, sheetPx, _) => RouteMap(
              journey: _mapJourney,
              others: _result?.journeys ?? const [],
              onSelect: (j) => _tapJourney(j, wide),
              pins: pins,
              padding: wide
                  ? EdgeInsets.only(left: 472, top: topInset)
                  : EdgeInsets.only(
                      top: topInset + (trip != null ? 112 : 64),
                      bottom: (sheetPx > 0 ? sheetPx : _peekFraction * c.maxHeight).clamp(0, c.maxHeight * _halfFraction),
                    ),
              rounded: false,
            ),
          ),
        );

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: Theme.of(context).brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
          child: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(child: map),
                if (wide)
                  Positioned(
                    left: 16,
                    top: topInset + 16,
                    bottom: 16,
                    width: 440,
                    child: Material(
                      elevation: 6,
                      borderRadius: BorderRadius.circular(24),
                      clipBehavior: Clip.antiAlias,
                      color: Theme.of(context).colorScheme.surface,
                      child: CustomScrollView(
                        slivers: [
                          SliverToBoxAdapter(child: _panelHeader(context)),
                          ..._panelSlivers(context, wide: true),
                        ],
                      ),
                    ),
                  )
                else ...[
                  Positioned(top: topInset + 8, left: 12, child: _topBar(context)),
                  if (trip != null)
                    Positioned(
                      top: topInset + 64,
                      left: 12,
                      right: 72,
                      child: _TripBar(trip: trip),
                    ),
                  _bottomSheet(context, c.maxHeight),
                ],
                if (wide && trip != null) Positioned(bottom: 16, right: 16, width: 420, child: _TripBar(trip: trip)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _topBar(BuildContext context) {
    final s = context.s;
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface.withValues(alpha: 0.95),
      elevation: 2,
      shape: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Anschluss', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            IconButton(
              tooltip: s.settings,
              icon: const Icon(Icons.tune),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panelHeader(BuildContext context) {
    final s = context.s;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
      child: Row(
        children: [
          const Text('Anschluss', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
          const Spacer(),
          IconButton(
            tooltip: s.settings,
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
    );
  }

  void _ensureSnaps(double height, double bottomInset) {
    if (_sheetHeight == height) return;
    _sheetHeight = height;
    _peekFraction = ((_peekPx + bottomInset) / height).clamp(0.12, 0.45);
    _snaps = List.unmodifiable([_peekFraction, _halfFraction, _fullFraction]);
  }

  /// Tracks the sheet: marks dragging and publishes its height for the map once it settles.
  bool _onSheet(DraggableScrollableNotification n) {
    _dragging = true;
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 150), () {
      _dragging = false;
      final h = _sheetHeight;
      if (h != null && mounted) _sheetPx.value = n.extent * h;
    });
    return false;
  }

  Widget _bottomSheet(BuildContext context, double height) {
    final cs = Theme.of(context).colorScheme;
    return NotificationListener<DraggableScrollableNotification>(
      onNotification: _onSheet,
      child: DraggableScrollableSheet(
        controller: _sheet,
        initialChildSize: _peekFraction,
        minChildSize: _peekFraction,
        maxChildSize: _fullFraction,
        snap: true,
        snapSizes: _snaps,
        builder: (context, scroll) => Material(
          elevation: 12,
          color: cs.surface,
          shadowColor: Colors.black54,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: CustomScrollView(
            controller: scroll,
            // Always scrollable, so the sheet can be dragged even when its content is short.
            physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
            slivers: [
              SliverToBoxAdapter(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _moveSheet(_sheet.size < _halfFraction - 0.01 ? _halfFraction : _peekFraction),
                  child: Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 10, bottom: 6),
                      width: 40,
                      height: 5,
                      decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
                ),
              ),
              ..._panelSlivers(context, wide: false),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _panelSlivers(BuildContext context, {required bool wide}) {
    final store = context.store;
    final s = context.s;
    final sort = _sort ?? store.settings.defaultSort;
    final js = _sorted(sort);
    final hi = _highlights(s);
    final firstDay = js.isEmpty ? null : js.map((j) => j.departure).reduce((a, b) => a.isBefore(b) ? a : b);
    final selected = _mapJourney?.id;
    final durations = js.where((j) => !j.cancelled && !j.walkOnly).map((j) => j.duration).toList()..sort();
    final range = durations.isEmpty ? null : (durations.first, durations.last);

    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        sliver: SliverToBoxAdapter(child: _searchBar(context)),
      ),
      SliverToBoxAdapter(child: _quickRoutes(context)),
      if (_result != null) SliverToBoxAdapter(child: _statusBar(context)),
      if (_fromCache && _result != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                Icon(Icons.cloud_off, size: 16, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 6),
                Expanded(child: Text(s.offline(fmtAgo(_result!.fetchedAt, s.de)), style: Theme.of(context).textTheme.bodySmall)),
                TextButton(onPressed: _search, child: Text(s.retry)),
              ],
            ),
          ),
        ),
      if (js.isNotEmpty) SliverToBoxAdapter(child: _sortBar(context, sort)),
      if (js.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextButton.icon(
              onPressed: _searching ? null : _earlier,
              icon: _loadingMore
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.expand_less),
              label: Text(s.earlier),
            ),
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        sliver: SliverList.separated(
          itemCount: js.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final j = js[i];
            final isSel = selected == j.id && _selectedId != null;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                JourneyCard(
                  key: ValueKey(j.id),
                  journey: j,
                  highlight: hi[j.id],
                  selected: isSel,
                  firstDay: firstDay,
                  durationRange: range,
                  onTap: () => _tapJourney(j, wide),
                ),
                if (isSel)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(onPressed: () => _openDetails(j), icon: const Icon(Icons.chevron_right), label: Text(s.details)),
                  ),
              ],
            );
          },
        ),
      ),
      if (_searching && js.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(children: [const CircularProgressIndicator(), const SizedBox(height: 12), Text(s.searching)]),
          ),
        ),
      if (!_searching && _result != null && js.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.search_off, size: 40, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 8),
                Text('${s.noResults}${_result!.anyFailed ? '\n${s.someSourcesFailed}' : ''}', textAlign: TextAlign.center),
                const SizedBox(height: 8),
                FilledButton.tonal(
                  onPressed: () {
                    breaker.reset();
                    _search();
                  },
                  child: Text(s.retry),
                ),
              ],
            ),
          ),
        ),
      if (js.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: TextButton.icon(
              onPressed: _searching ? null : _later,
              icon: _loadingMore
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.expand_more),
              label: Text(s.later),
            ),
          ),
        ),
      // Room so the last card can scroll above the tracked-trip bar / home indicator.
      SliverToBoxAdapter(child: SizedBox(height: MediaQuery.of(context).padding.bottom + 16)),
    ];
  }

  /// Compact From / To / time bar – exactly what's visible when the sheet is collapsed.
  Widget _searchBar(BuildContext context) {
    final s = context.s;
    final store = context.store;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final fav = _from != null && _to != null && store.isFavorite(_from!, _to!);

    Widget stationRow(Place? p, bool from) => InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _pick(from),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Icon(from ? Icons.trip_origin : Icons.place, size: 20, color: from ? cs.onSurfaceVariant : cs.primary),
            ),
            Expanded(
              child: Text(
                p?.name ?? (from ? s.from : s.to),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.titleMedium?.copyWith(
                  color: p == null ? cs.outline : null,
                  fontWeight: p == null ? FontWeight.w400 : FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final when = _when;
    final whenLabel = when == null ? s.now : '${dayDiff(DateTime.now(), when) == 0 ? '' : '${fmtDate(when, s.de)} '}${fmtTime(when)}';

    return Column(
      children: [
        Container(
          decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
          padding: const EdgeInsets.fromLTRB(4, 2, 0, 2),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    stationRow(_from, true),
                    Padding(
                      padding: const EdgeInsets.only(left: 32, right: 4),
                      child: Divider(height: 1, color: cs.outlineVariant),
                    ),
                    stationRow(_to, false),
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(tooltip: s.swap, icon: const Icon(Icons.swap_vert), onPressed: _swap),
                  IconButton(
                    tooltip: fav ? s.removeFavorite : s.addFavorite,
                    icon: Icon(fav ? Icons.star_rounded : Icons.star_outline_rounded, color: fav ? Colors.amber.shade700 : null),
                    onPressed: _from == null || _to == null ? null : () => store.toggleFavorite(_from!, _to!),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _TimeChip(
              label: '${_arriveBy ? s.arrive : s.depart} · $whenLabel',
              onTap: _pickTime,
              onToggle: () => setState(() => _arriveBy = !_arriveBy),
              onReset: when == null ? null : () => setState(() => _when = null),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _searching ? null : _search,
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                icon: _searching
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search),
                label: Text(_searching ? s.loading : (s.de ? 'Suchen' : 'Search')),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _quickRoutes(BuildContext context) {
    final store = context.store;
    final s = context.s;
    final recents = store.recentRoutes.where((r) => !store.isFavorite(r.from, r.to)).take(4).toList();
    if (store.favorites.isEmpty && recents.isEmpty) return const SizedBox.shrink();

    Widget chip(SavedRoute r, bool fav) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InputChip(
        avatar: Icon(fav ? Icons.star_rounded : Icons.history, size: 18, color: fav ? Colors.amber.shade700 : null),
        label: Text('${_short(r.from.name)} → ${_short(r.to.name)}'),
        onPressed: () {
          setState(() {
            _from = r.from;
            _to = r.to;
          });
          _search();
        },
        onDeleted: fav ? () => store.removeFavorite(r) : null,
        deleteIcon: fav ? const Icon(Icons.close, size: 16) : null,
      ),
    );

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final r in store.favorites) chip(r, true),
          for (final r in recents) chip(r, false),
          if (recents.isNotEmpty) TextButton(onPressed: store.clearRecents, child: Text(s.clear)),
        ],
      ),
    );
  }

  static String _short(String name) => name.replaceAll(RegExp(r'\s*\((.*?)\)'), '').replaceAll(RegExp(r'^(S\+U|S|U)\s+'), '');

  Widget _statusBar(BuildContext context) {
    final s = context.s;
    final st = _result!.status;
    if (st.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final e in st.entries)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Tooltip(
                message: e.value.error ?? '${s.found(e.value.count)} · ${e.value.ms} ms',
                triggerMode: TooltipTriggerMode.tap,
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: switch (e.value.state) {
                    SourceState.loading => const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    SourceState.ok => Icon(Icons.check_circle, size: 16, color: Colors.green.shade600),
                    SourceState.failed => Icon(Icons.error, size: 16, color: Colors.red.shade600),
                    SourceState.paused => Icon(Icons.pause_circle, size: 16, color: Colors.orange.shade700),
                    SourceState.skipped => Icon(Icons.remove_circle_outline, size: 16, color: Theme.of(context).colorScheme.outline),
                  },
                  label: Text(
                    '${s.sourceLabel(e.key)}${e.value.state == SourceState.ok ? ' ${e.value.count}' : ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sortBar(BuildContext context, SortMode sort) {
    final s = context.s;
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: [
          for (final m in SortMode.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(label: Text(s.sortName(m)), selected: sort == m, onSelected: (_) => setState(() => _sort = m)),
            ),
        ],
      ),
    );
  }
}

/// "Ab · 14:30" chip: tap = pick date/time, the swap icon toggles depart/arrive, × resets to now.
class _TimeChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback? onReset;
  const _TimeChip({required this.label, required this.onTap, required this.onToggle, this.onReset});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(24)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: context.s.de ? 'Ab / An' : 'Depart / arrive',
            icon: const Icon(Icons.swap_horiz, size: 20),
            onPressed: onToggle,
          ),
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: EdgeInsets.only(right: onReset == null ? 16 : 0, top: 8, bottom: 8),
              child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
          if (onReset != null)
            IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 18), onPressed: onReset),
        ],
      ),
    );
  }
}

class _TripBar extends StatelessWidget {
  final SavedTrip trip;
  const _TripBar({required this.trip});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final j = trip.journey;
    final cs = Theme.of(context).colorScheme;
    final buffer = j.tightestBuffer;
    final next = j.departure.isAfter(DateTime.now()) ? j.departure : j.arrival;
    return Material(
      color: cs.primaryContainer,
      elevation: 3,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        bottom: false,
        child: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TripScreen(tripId: trip.id))),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                Icon(
                  buffer != null && buffer < 0 ? Icons.warning_amber_rounded : (trip.ongoing ? Icons.train : Icons.bookmark),
                  color: cs.onPrimaryContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        trip.ongoing ? s.tracking : (s.de ? 'Nächste Reise' : 'Next trip'),
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onPrimaryContainer),
                      ),
                      Text(
                        '${fmtTime(j.departure)} ${trip.route.from.name} → ${fmtTime(j.arrival)} ${trip.route.to.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: cs.onPrimaryContainer, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                Countdown(
                  target: next,
                  de: s.de,
                  showWithin: const Duration(hours: 12),
                  style: TextStyle(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Icon(Icons.chevron_right, color: cs.onPrimaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
