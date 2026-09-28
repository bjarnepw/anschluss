import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../models/journey.dart';
import '../app_scope.dart';
import '../line_colors.dart';

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

  const RouteMap({
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

  @override
  void dispose() {
    _hit.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(RouteMap old) {
    super.didUpdateWidget(old);
    final pinsChanged = widget.journey == null && !_samePins(old.pins, widget.pins);
    final paddingChanged = (old.padding.bottom - widget.padding.bottom).abs() > 40 || old.padding.left != widget.padding.left;
    final setChanged = _ids(old) != _ids(widget);
    final selectionOnly = !setChanged && old.journey?.id != widget.journey?.id;
    if (_ready && (setChanged || selectionOnly || pinsChanged || paddingChanged)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fit(animate: true));
    }
  }

  String _ids(RouteMap w) => [w.journey?.id, ...w.others.map((j) => j.id)].whereType<String>().toSet().join('|');

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
    final faded = <Polyline<String>>[];
    for (final o in widget.others) {
      if (o.id == j?.id) continue;
      for (final l in o.legs) {
        if (l.path.length < 2 || l.isWalk) continue;
        faded.add(
          Polyline<String>(
            points: l.path.map((p) => LatLng(p[0], p[1])).toList(),
            color: lineColor(l, b).withValues(alpha: 0.3),
            strokeWidth: 4,
            pattern: l.pathExact ? const StrokePattern.solid() : StrokePattern.dashed(segments: const [10, 8]),
            hitValue: o.id,
          ),
        );
      }
    }

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
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'de.bjarnepw.anschluss',
          tileBuilder: b == Brightness.dark ? darkModeTileBuilder : null,
        ),
        if (_rail)
          Opacity(
            opacity: 0.7,
            child: TileLayer(
              urlTemplate: 'https://tiles.openrailwaymap.org/standard/{z}/{x}/{y}.png',
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
        Padding(
          padding: EdgeInsets.only(bottom: widget.padding.bottom, left: widget.padding.left),
          child: const SimpleAttributionWidget(source: Text('OpenStreetMap, OpenRailwayMap')),
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
              tooltip: context.s.de ? 'Schienennetz' : 'Railway network',
              isSelected: _rail,
              icon: const Icon(Icons.train_outlined),
              selectedIcon: const Icon(Icons.train),
              onPressed: () => setState(() => _rail = !_rail),
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
