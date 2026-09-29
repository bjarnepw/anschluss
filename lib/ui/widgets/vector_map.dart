// Vector map (MapLibre + OpenFreeMap) for Android, iOS and web: sharp at every zoom, smooth, real dark
// style – like OsmAnd. Desktop keeps the raster map (MapLibre has no Linux/macOS/Windows support).
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:url_launcher/url_launcher.dart';

import '../../models/journey.dart';
import '../../services/geometry.dart';
import '../../services/location.dart';
import '../app_scope.dart';
import '../line_colors.dart';
import 'intro.dart';

const _styleLight = 'https://tiles.openfreemap.org/styles/liberty';
const _styleDark = 'https://tiles.openfreemap.org/styles/dark';
const _railTiles = 'https://tiles.openrailwaymap.org/standard/{z}/{x}/{y}.png';

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

class VectorRouteMap extends StatefulWidget {
  final Journey? journey;
  final List<Journey> others;
  final ValueChanged<Journey>? onSelect;
  final List<Place> pins;
  final EdgeInsets padding;
  final bool rounded;
  final ValueChanged<Journey>? onGeometry;
  final (double, double)? expected;

  const VectorRouteMap({
    super.key,
    required this.journey,
    this.others = const [],
    this.onSelect,
    this.pins = const [],
    this.padding = EdgeInsets.zero,
    this.rounded = true,
    this.onGeometry,
    this.expected,
  });

  @override
  State<VectorRouteMap> createState() => _VectorRouteMapState();
}

class _VectorRouteMapState extends State<VectorRouteMap> {
  ml.MapLibreMapController? _ctrl;
  bool _styleReady = false;
  bool _rail = false;
  String _dataKey = '';
  Brightness? _styleFor;
  final _loc = LocationService.instance;

  @override
  void initState() {
    super.initState();
    _loc.position.addListener(_onPosition);
    _loc.resumeIfAllowed();
    _loadTrack();
  }

  @override
  void dispose() {
    _loc.position.removeListener(_onPosition);
    super.dispose();
  }

  void _onPosition() {
    if (mounted) setState(() {}); // enables the native location dot once permission is there
  }

  /// Straight lines are only a stand-in: fetch the real track / footpath for the shown journey.
  void _loadTrack() {
    final j = widget.journey;
    if (j == null || AppScope.read(context).settings.offlineOnly) return;
    enrichGeometry(j).then((changed) {
      if (!changed || !mounted || widget.journey?.id != j.id) return;
      _dataKey = '';
      _sync();
      widget.onGeometry?.call(j);
    });
  }

  @override
  void didUpdateWidget(VectorRouteMap old) {
    super.didUpdateWidget(old);
    final selectionChanged = old.journey?.id != widget.journey?.id;
    if (selectionChanged) _loadTrack();
    _sync(fit: selectionChanged || (widget.journey == null && !_samePins(old.pins, widget.pins)));
  }

  bool _samePins(List<Place> a, List<Place> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  // ---------------------------------------------------------------- data → GeoJSON

  Map<String, dynamic> _fc(List<Map<String, dynamic>> features) => {'type': 'FeatureCollection', 'features': features};

  Map<String, dynamic> _line(List<List<double>> path, Map<String, dynamic> props) => {
    'type': 'Feature',
    'properties': props,
    'geometry': {
      'type': 'LineString',
      'coordinates': [
        for (final p in path) [p[1], p[0]],
      ],
    },
  };

  Map<String, dynamic> _point(double lat, double lon, Map<String, dynamic> props) => {
    'type': 'Feature',
    'properties': props,
    'geometry': {
      'type': 'Point',
      'coordinates': [lon, lat],
    },
  };

  static List<List<double>> _thin(List<List<double>> path, int max) {
    if (path.length <= max) return path;
    final step = path.length / (max - 1);
    return [for (var i = 0; i < max - 1; i++) path[(i * step).floor()], path.last];
  }

  Future<void> _sync({bool fit = false}) async {
    final c = _ctrl;
    if (c == null || !_styleReady) return;
    final b = Theme.of(context).brightness;
    final j = widget.journey;
    final key = [
      b.name,
      j?.id,
      j?.legs.where((l) => l.pathExact).length,
      widget.others.map((o) => '${o.id}:${o.legs.where((l) => l.pathExact).length}').join(','),
      widget.pins.map((p) => '${p.lat},${p.lon}').join(';'),
      widget.expected,
    ].join('|');
    if (key != _dataKey) {
      _dataKey = key;
      final faded = <Map<String, dynamic>>[
        for (final o in widget.others)
          if (o.id != j?.id)
            for (final l in o.legs)
              if (!l.isWalk && l.path.length >= 2)
                _line(_thin(l.path, 200), {'color': _hex(lineColor(l, b)), 'jid': o.id, 'kind': l.pathExact ? 'solid' : 'dashed'}),
      ];
      final route = <Map<String, dynamic>>[
        if (j != null)
          for (final l in j.legs)
            if (l.path.length >= 2)
              _line(l.path, {'color': _hex(lineColor(l, b)), 'kind': l.isWalk ? 'walk' : (l.pathExact ? 'solid' : 'dashed')}),
      ];
      final points = <Map<String, dynamic>>[];
      if (j != null) {
        for (var i = 0; i < j.legs.length; i++) {
          final l = j.legs[i];
          if (l.from.hasCoords && (i == 0 || !l.isWalk)) {
            points.add(_point(l.from.lat!, l.from.lon!, {'role': i == 0 ? 'start' : 'change'}));
          }
          if (i == j.legs.length - 1 && l.to.hasCoords) points.add(_point(l.to.lat!, l.to.lon!, {'role': 'end'}));
        }
      } else {
        final pins = widget.pins.where((p) => p.hasCoords).toList();
        for (var i = 0; i < pins.length; i++) {
          points.add(_point(pins[i].lat!, pins[i].lon!, {'role': i == pins.length - 1 && pins.length > 1 ? 'end' : 'start'}));
        }
        if (pins.length == 2) {
          route.add(
            _line(
              [
                [pins[0].lat!, pins[0].lon!],
                [pins[1].lat!, pins[1].lon!],
              ],
              {'color': _hex(Theme.of(context).colorScheme.primary), 'kind': 'dashed'},
            ),
          );
        }
      }
      final exp = widget.expected;
      try {
        await c.setGeoJsonSource('faded', _fc(faded));
        await c.setGeoJsonSource('route', _fc(route));
        await c.setGeoJsonSource('points', _fc(points));
        await c.setGeoJsonSource('expected', _fc([if (exp != null) _point(exp.$1, exp.$2, const {})]));
      } catch (_) {
        return; // style was being replaced; the next style load re-syncs
      }
    }
    if (fit) _fit();
  }

  Future<void> _fit() async {
    final c = _ctrl;
    if (c == null) return;
    final pts = <List<double>>[
      if (widget.journey != null)
        for (final l in widget.journey!.legs) ...l.path
      else
        for (final p in widget.pins.where((p) => p.hasCoords)) [p.lat!, p.lon!],
    ];
    if (pts.isEmpty) return;
    final pad = widget.padding + const EdgeInsets.all(48);
    if (pts.length == 1 || pts.every((p) => p[0] == pts.first[0] && p[1] == pts.first[1])) {
      await c.animateCamera(ml.CameraUpdate.newLatLngZoom(ml.LatLng(pts.first[0], pts.first[1]), 13));
      return;
    }
    final lats = pts.map((p) => p[0]), lons = pts.map((p) => p[1]);
    await c.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        ml.LatLngBounds(southwest: ml.LatLng(lats.reduce(min), lons.reduce(min)), northeast: ml.LatLng(lats.reduce(max), lons.reduce(max))),
        left: pad.left,
        top: pad.top,
        right: pad.right,
        bottom: pad.bottom,
      ),
      duration: const Duration(milliseconds: 450),
    );
  }

  // ---------------------------------------------------------------- style setup

  Future<void> _onStyleLoaded() async {
    final c = _ctrl;
    if (c == null) return;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    for (final id in ['faded', 'route', 'points', 'expected']) {
      await c.addGeoJsonSource(id, _fc(const []));
    }
    final casing = dark ? '#000000' : '#ffffff';
    dynamic kind(String k) => [
      '==',
      ['get', 'kind'],
      k,
    ];
    // Alternatives, faded (tap to select)
    await c.addLineLayer(
      'faded',
      'faded-solid',
      ml.LineLayerProperties(lineColor: ['get', 'color'], lineWidth: 4.0, lineOpacity: 0.35, lineCap: 'round', lineJoin: 'round'),
      filter: kind('solid'),
    );
    await c.addLineLayer(
      'faded',
      'faded-dashed',
      const ml.LineLayerProperties(lineColor: ['get', 'color'], lineWidth: 4.0, lineOpacity: 0.35, lineDasharray: [2, 2]),
      filter: kind('dashed'),
    );
    // Selected journey: white casing, then colour
    await c.addLineLayer(
      'route',
      'route-casing',
      ml.LineLayerProperties(lineColor: casing, lineWidth: 9.0, lineOpacity: 0.9, lineCap: 'round', lineJoin: 'round'),
    );
    await c.addLineLayer(
      'route',
      'route-solid',
      const ml.LineLayerProperties(lineColor: ['get', 'color'], lineWidth: 5.0, lineCap: 'round', lineJoin: 'round'),
      filter: kind('solid'),
    );
    await c.addLineLayer(
      'route',
      'route-dashed',
      const ml.LineLayerProperties(lineColor: ['get', 'color'], lineWidth: 5.0, lineDasharray: [2.4, 1.6]),
      filter: kind('dashed'),
    );
    await c.addLineLayer(
      'route',
      'route-walk',
      const ml.LineLayerProperties(lineColor: ['get', 'color'], lineWidth: 5.0, lineDasharray: [0.1, 1.8], lineCap: 'round'),
      filter: kind('walk'),
    );
    await c.addCircleLayer(
      'points',
      'points',
      ml.CircleLayerProperties(
        circleRadius: [
          'match',
          ['get', 'role'],
          'change',
          6.0,
          8.0,
        ],
        circleColor: [
          'match',
          ['get', 'role'],
          'end',
          _hex(cs.primary),
          _hex(cs.surface),
        ],
        circleStrokeColor: _hex(cs.onSurface),
        circleStrokeWidth: 3.0,
      ),
    );
    await c.addCircleLayer(
      'expected',
      'expected',
      ml.CircleLayerProperties(
        circleRadius: 13.0,
        circleColor: _hex(cs.primary),
        circleOpacity: 0.2,
        circleStrokeColor: _hex(cs.primary),
        circleStrokeWidth: 3.0,
      ),
    );
    if (_rail) await _addRail();
    _styleReady = true;
    _dataKey = '';
    await _sync(fit: true);
  }

  Future<void> _addRail() async {
    final c = _ctrl!;
    await c.addSource('orm', const ml.RasterSourceProperties(tiles: [_railTiles], tileSize: 256, attribution: 'OpenRailwayMap'));
    await c.addRasterLayer('orm', 'orm', const ml.RasterLayerProperties(rasterOpacity: 0.75), belowLayerId: 'faded-solid');
  }

  Future<void> _toggleRail() async {
    final c = _ctrl;
    if (c == null || !_styleReady) return;
    setState(() => _rail = !_rail);
    try {
      if (_rail) {
        await _addRail();
      } else {
        await c.removeLayer('orm');
        await c.removeSource('orm');
      }
    } catch (_) {}
  }

  Future<void> _onTap(Point<double> p, ml.LatLng _) async {
    final c = _ctrl;
    if (c == null || widget.onSelect == null) return;
    final hits = await c.queryRenderedFeaturesInRect(Rect.fromCenter(center: Offset(p.x, p.y), width: 28, height: 28), [
      'faded-solid',
      'faded-dashed',
    ], null);
    for (final h in hits) {
      final props = h is Map ? h['properties'] : null;
      final id = props is Map ? props['jid'] as String? : null;
      final j = widget.others.where((o) => o.id == id).firstOrNull;
      if (j != null) {
        widget.onSelect!(j);
        return;
      }
    }
  }

  Future<void> _locate() async {
    final ok = await _loc.enable();
    if (!mounted) return;
    final p = _loc.position.value;
    if (!ok || p == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.s.noLocation)));
      return;
    }
    setState(() {});
    await _ctrl?.animateCamera(ml.CameraUpdate.newLatLngZoom(ml.LatLng(p.latitude, p.longitude), 15));
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final cs = Theme.of(context).colorScheme;
    final s = context.s;
    // Dark/light switch: new style, layers are added again in onStyleLoaded.
    if (_styleFor != null && _styleFor != b) _styleReady = false;
    _styleFor = b;
    final hasLocation = _loc.position.value != null;

    final map = ml.MapLibreMap(
      styleString: b == Brightness.dark ? _styleDark : _styleLight,
      initialCameraPosition: const ml.CameraPosition(target: ml.LatLng(51.1, 10.4), zoom: 5.2),
      onMapCreated: (c) => _ctrl = c,
      onStyleLoadedCallback: _onStyleLoaded,
      onMapClick: _onTap,
      myLocationEnabled: hasLocation,
      myLocationRenderMode: ml.MyLocationRenderMode.normal,
      myLocationTrackingMode: ml.MyLocationTrackingMode.none,
      compassEnabled: true,
      compassViewMargins: Point(widget.padding.right + 16, widget.padding.top + 220),
      rotateGesturesEnabled: true,
      tiltGesturesEnabled: false,
      logoEnabled: false,
      attributionButtonMargins: const Point(-100, -100), // replaced by the always-visible text below
      trackCameraPosition: false,
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
            IconButton(tooltip: s.myLocation, icon: Icon(hasLocation ? Icons.my_location : Icons.location_searching), onPressed: _locate),
            IconButton(
              tooltip: s.de ? 'Schienennetz' : 'Railway network',
              isSelected: _rail,
              icon: const Icon(Icons.train_outlined),
              selectedIcon: const Icon(Icons.train),
              onPressed: _toggleRail,
            ),
            IconButton(tooltip: s.de ? 'Legende' : 'Legend', icon: const Icon(Icons.info_outline), onPressed: () => showMapLegend(context)),
            IconButton(tooltip: s.de ? 'Einpassen' : 'Fit', icon: const Icon(Icons.fit_screen), onPressed: _fit),
          ],
        ),
      ),
    );

    final attribution = Positioned(
      right: widget.padding.right + 4,
      bottom: widget.padding.bottom + 4,
      child: _VectorAttribution(rail: _rail),
    );

    final stack = Stack(children: [map, controls, attribution]);
    return widget.rounded ? ClipRRect(borderRadius: BorderRadius.circular(16), child: stack) : stack;
  }
}

/// Always visible (OSM/OpenFreeMap attribution requirements) with a "report a map issue" link.
class _VectorAttribution extends StatelessWidget {
  final bool rail;
  const _VectorAttribution({required this.rail});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = context.s;
    final style = TextStyle(fontSize: 10.5, color: cs.onSurface);
    final link = style.copyWith(color: cs.primary, decoration: TextDecoration.underline, decorationColor: cs.primary);
    Future<void> open(String u) => launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: cs.surface.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(6)),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          GestureDetector(
            onTap: () => open('https://openfreemap.org'),
            child: Text('OpenFreeMap', style: style),
          ),
          Text(' · ', style: style),
          GestureDetector(
            onTap: () => open('https://www.openmaptiles.org/'),
            child: Text('© OpenMapTiles', style: style),
          ),
          Text(' · ', style: style),
          GestureDetector(
            onTap: () => open('https://www.openstreetmap.org/copyright'),
            child: Text('© OpenStreetMap contributors', style: style),
          ),
          if (rail) Text(' · OpenRailwayMap', style: style),
          Text(' · ', style: style),
          GestureDetector(
            onTap: () => open('https://www.openstreetmap.org/fixthemap'),
            child: Text(s.de ? 'Fehler melden' : 'Report issue', style: link),
          ),
        ],
      ),
    );
  }
}
