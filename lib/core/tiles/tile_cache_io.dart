// Disk tile cache for Android, iOS, macOS and Linux.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../net.dart' show userAgent;

/// Used when the server gives no caching headers (OSM tile policy: at least 7 days).
const _defaultAge = Duration(days: 7);
const _maxBytes = 300 * 1024 * 1024;

class _TileStore {
  _TileStore._();
  static final instance = _TileStore._();

  final _client = http.Client();
  Future<Directory>? _dir;
  var _pruned = false;

  Future<Directory> get dir => _dir ??= () async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/tiles');
    await d.create(recursive: true);
    return d;
  }();

  /// FNV-1a 64-bit – stable file names for tile URLs.
  static String _name(String url) {
    var h = 0xcbf29ce484222325;
    for (final c in url.codeUnits) {
      h ^= c;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toUnsigned(64).toRadixString(16);
  }

  Future<File> _file(String url) async => File('${(await dir).path}/${_name(url)}.tile');

  /// Fresh from disk, else from the network (and stored), else stale from disk.
  File _meta(File tile) => File('${tile.path}.meta');

  /// How long a response may be used, from Cache-Control max-age or Expires (tile.openstreetmap.org policy:
  /// honour the caching headers; 7 days if there are none).
  static DateTime _expiry(Map<String, String> h) {
    final cc = h['cache-control'] ?? '';
    final m = RegExp(r'(?:s-)?max-age=(\d+)').firstMatch(cc);
    if (m != null) return DateTime.now().add(Duration(seconds: int.parse(m.group(1)!)));
    final exp = h['expires'];
    if (exp != null) {
      try {
        return HttpDate.parse(exp);
      } catch (_) {}
    }
    return DateTime.now().add(_defaultAge);
  }

  /// Fresh from disk; else revalidated with a conditional request (ETag / Last-Modified); else stale from disk.
  Future<Uint8List> get(String url) async {
    final f = await _file(url);
    final metaFile = _meta(f);
    final exists = await f.exists();
    Map<String, dynamic> meta = const {};
    if (exists) {
      try {
        meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      } catch (_) {}
      final expires = DateTime.tryParse(meta['expires'] as String? ?? '');
      if (expires != null && DateTime.now().isBefore(expires)) return f.readAsBytes();
    }
    try {
      final res = await _client
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent': userAgent,
              if (exists && meta['etag'] != null) 'If-None-Match': meta['etag'] as String,
              if (exists && meta['lastModified'] != null) 'If-Modified-Since': meta['lastModified'] as String,
            },
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 304 && exists) {
        // Unchanged: keep the tile, extend its lifetime.
        unawaited(metaFile.writeAsString(jsonEncode({...meta, 'expires': _expiry(res.headers).toIso8601String()})));
        return await f.readAsBytes();
      }
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) throw HttpException('HTTP ${res.statusCode}');
      unawaited(() async {
        await f.writeAsBytes(res.bodyBytes, flush: false);
        await metaFile.writeAsString(
          jsonEncode({
            'expires': _expiry(res.headers).toIso8601String(),
            if (res.headers['etag'] != null) 'etag': res.headers['etag'],
            if (res.headers['last-modified'] != null) 'lastModified': res.headers['last-modified'],
          }),
        );
        await _maybePrune();
      }());
      return res.bodyBytes;
    } catch (e) {
      if (exists) return f.readAsBytes(); // offline: an old tile beats an empty map
      rethrow;
    }
  }

  Future<bool> has(String url) async => (await _file(url)).exists();

  Future<void> _maybePrune() async {
    if (_pruned) return;
    _pruned = true;
    final files = (await (await dir).list().toList()).whereType<File>();
    final stats = <(File, FileStat)>[];
    var total = 0;
    for (final f in files) {
      final s = await f.stat();
      stats.add((f, s));
      total += s.size;
    }
    if (total <= _maxBytes) return;
    stats.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (f, s) in stats) {
      if (total <= _maxBytes * 4 ~/ 5) break;
      try {
        await f.delete();
        total -= s.size;
      } catch (_) {}
    }
  }
}

class _CachedTile extends ImageProvider<_CachedTile> {
  final String url;
  const _CachedTile(this.url);

  @override
  Future<_CachedTile> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_CachedTile key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1, debugLabel: url);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await _TileStore.instance.get(url);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) => other is _CachedTile && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

class _CachingTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) => _CachedTile(getTileUrl(coordinates, options));
}

TileProvider cachedTileProvider() => _CachingTileProvider();

Future<int> tileCacheBytes() async {
  var total = 0;
  try {
    await for (final f in (await _TileStore.instance.dir).list()) {
      if (f is File) total += await f.length();
    }
  } catch (_) {}
  return total;
}

Future<void> clearTileCache() async {
  final d = await _TileStore.instance.dir;
  if (await d.exists()) await d.delete(recursive: true);
  _TileStore.instance._dir = null;
}

Future<int> prefetch(String template, List<(int, int, int)> tiles, {void Function(int done, int total)? onProgress}) async {
  var done = 0, stored = 0;
  final queue = [...tiles];
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final (z, x, y) = queue.removeLast();
      final url = template.replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y').replaceAll('{s}', 'a');
      try {
        if (!await _TileStore.instance.has(url)) await _TileStore.instance.get(url);
        stored++;
      } catch (_) {}
      done++;
      onProgress?.call(done, tiles.length);
    }
  }

  await Future.wait(List.generate(4, (_) => worker()));
  return stored;
}
