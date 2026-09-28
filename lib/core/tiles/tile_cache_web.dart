// Web: the browser's HTTP cache keeps tiles; no file system for an own store.
import 'package:flutter_map/flutter_map.dart';

TileProvider cachedTileProvider() => NetworkTileProvider();

Future<int> tileCacheBytes() async => 0;

Future<void> clearTileCache() async {}

Future<int> prefetch(String template, List<(int, int, int)> tiles, {void Function(int done, int total)? onProgress}) =>
    throw UnsupportedError('Offline maps are not available in the web version.');
