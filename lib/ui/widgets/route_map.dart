import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/tiles/tile_cache.dart';
import '../../models/journey.dart';
import '../../services/geometry.dart';
import '../../services/location.dart';
import '../app_scope.dart';
import '../line_colors.dart';
import 'intro.dart';

/// OSM map with the journey's legs drawn in their line colours. Dashed = straight line (no exact geometry).
/// [padding] is the area covered by overlays (bottom sheet, side panel, status bar); fitting keeps the route
/// inside the visible part and the map controls clear of it.
/// [others] are drawn faded underneath the selected [journey]; tapping one calls [onSelect].
class RouteMap extends StatefulWidget {
  final Journey? journey;
  final List<Journey> others;
  final ValueChanged<Journey>? onSelect;
  final List<Place> pins;
  final EdgeInsets padding;
  final bool rounded;

  /// Called after real track geometry was loaded into [journey] (e.g. to save it with a trip).
  final ValueChanged<Journey>? onGeometry;

  const RouteMap({
    this.onGeometry,
    super.key,
    required this.journey,
    this.others = const [],
    this.onSelect,
    this.pins = const [],
    this.padding = EdgeInsets.zero,
    this.rounded = true,
  });

  @override
  State<RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<RouteMap> {
  final _ctrl = MapController();
  bool _rail = false;
  bool _ready = false;
  final LayerHitNotifier<String> _hit = ValueNotifier(null);
  static final _tiles = cachedTileProvider();
  static final _railTiles = cachedTileProvider();
  final _loc = LocationService.instance;

  @override
  void initState() {
    super.initState();
    _loc.position.addListener(_onPosition);
    _loc.resumeIfAllowed();
    _loadTrack();
  }

  /// Straight lines are only a stand-in: fetch the real route along the tracks for the shown journey.
  void _loadTrack() {
    final j = widget.journey;
    if (j == null || AppScope.read(context).settings.offlineOnly) return;
    enrichGeometry(j).then((changed) {
      if (!changed || !mounted || widget.journey?.id != j.id) return;
      setState(() {});
      widget.onGeometry?.call(j);
    });
  }

  @override
  void dispose() {
    _loc.position.removeListener(_onPosition);
    _hit.dispose();
    super.dispose();
  }

  void _onPosition() {
    if (mounted) setState(() {});
  }

  Future<void> _locate() async {
    final ok = await _loc.enable();
    if (!mounted) return;
    final p = _loc.position.value;
    if (!ok || p == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.s.noLocation)));
      return;
    }
    _ctrl.move(LatLng(p.latitude, p.longitude), 14, offset: Offset(0, -(widget.padding.bottom - widget.padding.top) / 2));
  }

  @override
  void didUpdateWidget(RouteMap old) {
    super.didUpdateWidget(old);
    // Move the camera only when what the user looks at changes (another connection, other stations) –
    // never because results stream in or the sheet moves; that made the map jump around.
    final pinsChanged = widget.journey == null && !_samePins(old.pins, widget.pins);
    final selectionChanged = old.journey?.id != widget.journey?.id;
    if (selectionChanged) _loadTrack();
    if (_ready && (selectionChanged || pinsChanged)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fit(animate: true));
    }
  }

  // Faded alternatives are cached: rebuilding thousands of points on every frame made the map stutter.
  List<Polyline<String>> _fadedCache = const [];
  String _fadedKey = '';

  List<Polyline<String>> _faded(Brightness b) {
    final j = widget.journey;
    final key = '${b.name}|${j?.id}|${widget.others.map((o) => '${o.id}:${o.legs.where((l) => l.pathExact).length}').join(',')}';
    if (key == _fadedKey) return _fadedCache;
    final out = <Polyline<String>>[];
    for (final o in widget.others) {
      if (o.id == j?.id) continue;
      for (final l in o.legs) {
        if (l.path.length < 2 || l.isWalk) continue;
        out.add(
          Polyline<String>(
            points: _thin(l.path, 150),
            color: lineColor(l, b).withValues(alpha: 0.3),
            strokeWidth: 4,
            pattern: l.pathExact ? const StrokePattern.solid() : StrokePattern.dashed(segments: const [10, 8]),
            hitValue: o.id,
          ),
        );
      }
    }
    _fadedKey = key;
    return _fadedCache = out;
  }

  /// Keeps at most [max] points (first and last always) – plenty for a faded background line.
  static List<LatLng> _thin(List<List<double>> path, int max) {
    if (path.length <= max) return [for (final p in path) LatLng(p[0], p[1])];
    final step = path.length / (max - 1);
    return [
      for (var i = 0; i < max - 1; i++) LatLng(path[(i * step).floor()][0], path[(i * step).floor()][1]),
      LatLng(path.last[0], path.last[1]),
    ];
  }

  bool _samePins(List<Place> a, List<Place> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  /// Fit to the selected journey – it is what the user is looking at; the faded alternatives
  /// run along roughly the same corridor anyway.
  List<LatLng> _points() {
    final j = widget.journey;
    if (j != null) {
      return [
        for (final l in j.legs)
          for (final p in l.path) LatLng(p[0], p[1]),
      ];
    }
    return [for (final p in widget.pins.where((p) => p.hasCoords)) LatLng(p.lat!, p.lon!)];
  }

  EdgeInsets get _fitPadding => widget.padding + const EdgeInsets.all(40);

  void _fit({bool animate = false}) {
    if (!mounted) return;
    final pts = _points();
    if (pts.isEmpty) return;
    if (pts.length == 1 || _allSame(pts)) {
      _ctrl.move(pts.first, 13, offset: Offset(0, -(widget.padding.bottom - widget.padding.top) / 2));
      return;
    }
    _ctrl.fitCamera(CameraFit.coordinates(coordinates: pts, padding: _fitPadding, maxZoom: 15));
  }

  void _onTapFaded() {
    final id = _hit.value?.hitValues.firstOrNull;
    if (id == null) return;
    final j = widget.others.where((o) => o.id == id).firstOrNull;
    if (j != null) widget.onSelect?.call(j);
  }

  bool _allSame(List<LatLng> pts) => pts.every((p) => p == pts.first);

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final cs = Theme.of(context).colorScheme;
    final j = widget.journey;
    final lines = <Polyline>[];
    final markers = <Marker>[];

    Marker dot(Place p, String tip, {Color? fill, double size = 18}) => Marker(
      point: LatLng(p.lat!, p.lon!),
      width: size,
      height: size,
      child: Tooltip(
        message: tip,
        child: Container(
          decoration: BoxDecoration(
            color: fill ?? cs.surface,
            shape: BoxShape.circle,
            border: Border.all(color: cs.onSurface, width: 3),
            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
          ),
        ),
      ),
    );

    // Alternatives: faded, thinner, no casing, drawn first so the selected journey sits on top.
    final faded = _faded(b);

    if (j != null) {
      for (final l in j.legs) {
        if (l.path.length < 2) continue;
        final pts = l.path.map((p) => LatLng(p[0], p[1])).toList();
        final c = lineColor(l, b);
        lines.add(Polyline(points: pts, color: b == Brightness.dark ? Colors.black : Colors.white, strokeWidth: l.isWalk ? 5 : 9));
        lines.add(
          Polyline(
            points: pts,
            color: c,
            strokeWidth: l.isWalk ? 3 : 5,
            pattern: l.isWalk
                ? StrokePattern.dotted(spacingFactor: 2)
                : (l.pathExact ? const StrokePattern.solid() : StrokePattern.dashed(segments: const [12, 7])),
          ),
        );
      }
      for (var i = 0; i < j.legs.length; i++) {
        final l = j.legs[i];
        if (l.from.hasCoords && (i == 0 || !l.isWalk)) {
          markers.add(
            dot(l.from, '${l.from.name} ${fmtTime(l.dep)}${l.depPlatform != null ? ', ${context.s.platform(l.depPlatform!)}' : ''}'),
          );
        }
        if (i == j.legs.length - 1 && l.to.hasCoords) {
          markers.add(
            dot(
              l.to,
              '${l.to.name} ${fmtTime(l.arr)}${l.arrPlatform != null ? ', ${context.s.platform(l.arrPlatform!)}' : ''}',
              fill: cs.primary,
              size: 20,
            ),
          );
        }
      }
    } else {
      final pins = widget.pins.where((p) => p.hasCoords).toList();
      for (var i = 0; i < pins.length; i++) {
        markers.add(dot(pins[i], pins[i].name, fill: i == pins.length - 1 && pins.length > 1 ? cs.primary : null, size: 20));
      }
      if (pins.length == 2) {
        lines.add(
          Polyline(
            points: [LatLng(pins[0].lat!, pins[0].lon!), LatLng(pins[1].lat!, pins[1].lon!)],
            color: cs.primary.withValues(alpha: 0.5),
            strokeWidth: 3,
            pattern: StrokePattern.dashed(segments: const [8, 8]),
          ),
        );
      }
    }

    final pts = _points();
    final pos = _loc.position.value;
    final me = pos == null ? null : LatLng(pos.latitude, pos.longitude);
    final map = FlutterMap(
      mapController: _ctrl,
      options: MapOptions(
        initialCenter: const LatLng(51.1, 10.4),
        initialZoom: 5.8,
        initialCameraFit: pts.length >= 2 && !_allSame(pts)
            ? CameraFit.coordinates(coordinates: pts, padding: _fitPadding, maxZoom: 15)
            : null,
        onMapReady: () => _ready = true,
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
      ),
      children: [
        TileLayer(
          urlTemplate: context.store.settings.tileUrl.isEmpty ? osmTemplate : context.store.settings.tileUrl,
          tileProvider: _tiles,
          userAgentPackageName: 'de.bjarnepw.anschluss',
          tileBuilder: b == Brightness.dark ? darkModeTileBuilder : null,
        ),
        if (_rail)
          Opacity(
            opacity: 0.7,
            child: TileLayer(
              urlTemplate: 'https://tiles.openrailwaymap.org/standard/{z}/{x}/{y}.png',
              tileProvider: _railTiles,
              userAgentPackageName: 'de.bjarnepw.anschluss',
            ),
          ),
        if (faded.isNotEmpty)
          MouseRegion(
            hitTestBehavior: HitTestBehavior.deferToChild,
            cursor: widget.onSelect != null ? SystemMouseCursors.click : MouseCursor.defer,
            child: GestureDetector(
              onTap: widget.onSelect == null ? null : _onTapFaded,
              child: PolylineLayer<String>(polylines: faded, hitNotifier: _hit, minimumHitbox: 14),
            ),
          ),
        PolylineLayer(polylines: lines),
        MarkerLayer(markers: markers),
        if (me != null) ...[
          CircleLayer(
            circles: [
              CircleMarker(
                point: me,
                radius: pos!.accuracy.clamp(5, 500).toDouble(),
                useRadiusInMeter: true,
                color: Colors.blue.withValues(alpha: 0.12),
                borderColor: Colors.blue.withValues(alpha: 0.4),
                borderStrokeWidth: 1,
              ),
            ],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: me,
                width: 22,
                height: 22,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue.shade600,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black38)],
                  ),
                ),
              ),
            ],
          ),
        ],
        Padding(
          padding: EdgeInsets.only(bottom: widget.padding.bottom, left: widget.padding.left),
          child: _Attribution(rail: _rail, custom: AppScope.read(context).settings.tileUrl.isNotEmpty),
        ),
      ],
    );

    final controls = Positioned(
      top: widget.padding.top + 8,
      right: widget.padding.right + 8,
      child: Material(
        color: cs.surface.withValues(alpha: 0.92),
        elevation: 2,
        shape: const StadiumBorder(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: context.s.myLocation,
              icon: Icon(me != null ? Icons.my_location : Icons.location_searching),
              onPressed: _locate,
            ),
            IconButton(
              tooltip: context.s.de ? 'Schienennetz' : 'Railway network',
              isSelected: _rail,
              icon: const Icon(Icons.train_outlined),
              selectedIcon: const Icon(Icons.train),
              onPressed: () => setState(() => _rail = !_rail),
            ),
            IconButton(
              tooltip: context.s.de ? 'Legende' : 'Legend',
              icon: const Icon(Icons.info_outline),
              onPressed: () => showMapLegend(context),
            ),
            IconButton(
              tooltip: context.s.de ? 'Einpassen' : 'Fit',
              icon: const Icon(Icons.fit_screen),
              onPressed: () => _fit(animate: true),
            ),
          ],
        ),
      ),
    );

    final stack = Stack(children: [map, controls]);
    return widget.rounded ? ClipRRect(borderRadius: BorderRadius.circular(16), child: stack) : stack;
  }
}

/// Always-visible licence attribution (OSM tile policy) with a "report a map issue" link.
class _Attribution extends StatelessWidget {
  final bool rail;
  final bool custom;
  const _Attribution({required this.rail, required this.custom});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = context.s;
    final style = TextStyle(fontSize: 11, color: cs.onSurface);
    final link = style.copyWith(color: cs.primary, decoration: TextDecoration.underline, decorationColor: cs.primary);
    Future<void> open(String u) => launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
    return Align(
      alignment: Alignment.bottomRight,
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: cs.surface.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(6)),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            GestureDetector(
              onTap: () => open('https://www.openstreetmap.org/copyright'),
              child: Text('© OpenStreetMap contributors', style: style),
            ),
            if (rail) Text(' · OpenRailwayMap', style: style),
            if (!custom) ...[
              Text(' · ', style: style),
              GestureDetector(
                onTap: () => open('https://www.openstreetmap.org/fixthemap'),
                child: Text(s.de ? 'Kartenfehler melden' : 'Report a map issue', style: link),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
