// Offline map tiles. On mobile/desktop every tile that is shown gets stored on disk and is served from
// there when there is no connection. Pre-downloading a route is only allowed for tile servers that
// permit it – the OpenStreetMap servers forbid bulk/offline downloads (operations.osmfoundation.org/policies/tiles).
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'tile_cache_io.dart' if (dart.library.js_interop) 'tile_cache_web.dart' as impl;

const osmTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// Whether the tile server allows pre-downloading tiles for offline use.
bool prefetchAllowed(String template) {
  final host = Uri.tryParse(template.replaceAll(RegExp(r'\{[^}]*\}'), 'a'))?.host ?? '';
  return host.isNotEmpty && !RegExp(r'(^|\.)(openstreetmap\.org|openrailwaymap\.org)$').hasMatch(host);
}

TileProvider cachedTileProvider() => impl.cachedTileProvider();

Future<int> tileCacheBytes() => impl.tileCacheBytes();

Future<void> clearTileCache() => impl.clearTileCache();

/// Tiles along [path] for zoom levels [minZoom]..[maxZoom], with a margin of one tile.
Set<(int, int, int)> tilesAlong(List<LatLng> path, {int minZoom = 8, int maxZoom = 14}) {
  final out = <(int, int, int)>{};
  if (path.isEmpty) return out;
  const crs = Epsg3857();
  for (var z = minZoom; z <= maxZoom; z++) {
    final scale = crs.scale(z.toDouble());
    (int, int) tileOf(LatLng p) {
      final pt = crs.latLngToOffset(p, z.toDouble());
      return ((pt.dx / 256).floor(), (pt.dy / 256).floor());
    }

    // Sample densely enough that no tile along the line is skipped.
    for (var i = 0; i < path.length; i++) {
      final a = path[i], b = i + 1 < path.length ? path[i + 1] : path[i];
      final ta = tileOf(a), tb = tileOf(b);
      final steps = ((ta.$1 - tb.$1).abs() + (ta.$2 - tb.$2).abs()).clamp(1, 1000);
      for (var s = 0; s <= steps; s++) {
        final t = s / steps;
        final (x, y) = tileOf(LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t));
        final margin = z >= 12 ? 1 : 0;
        final max = (scale / 256).round();
        for (var dx = -margin; dx <= margin; dx++) {
          for (var dy = -margin; dy <= margin; dy++) {
            final xx = x + dx, yy = y + dy;
            if (xx >= 0 && yy >= 0 && xx < max && yy < max) out.add((z, xx, yy));
          }
        }
      }
    }
  }
  return out;
}

/// Downloads the tiles along [path] into the cache. Returns the number of tiles stored.
/// Throws if the server does not allow it or on the web.
Future<int> prefetchRoute(String template, List<LatLng> path, {void Function(int done, int total)? onProgress}) {
  if (!prefetchAllowed(template)) {
    throw UnsupportedError('This tile server does not allow offline downloads.');
  }
  final tiles = tilesAlong(path).toList();
  if (tiles.length > 4000) tiles.removeRange(4000, tiles.length);
  return impl.prefetch(template, tiles, onProgress: onProgress);
}
