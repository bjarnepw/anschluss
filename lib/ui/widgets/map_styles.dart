// Map styles for the vector map (OpenFreeMap). Loaded once and adjusted before use: labels in German
// (name:de, falling back to the local name) instead of the style's default latin/English names.
import 'dart:convert';

import '../../core/net.dart';

enum MapStyle { liberty, bright, positron }

const _base = 'https://tiles.openfreemap.org/styles';

String styleUrl(MapStyle s, bool dark) => dark ? '$_base/dark' : '$_base/${s.name}';

final _cache = <String, Future<String>>{};

/// The style as JSON text with labels in [lang] ('de' or 'en'). Falls back to the plain URL on errors.
Future<String> loadStyle(MapStyle s, bool dark, String lang) {
  final url = styleUrl(s, dark);
  return _cache.putIfAbsent('$url|$lang', () async {
    try {
      final style = jsonDecode(await Net.instance.getText(Uri.parse(url))) as Map<String, dynamic>;
      final label = [
        'coalesce',
        ['get', 'name:$lang'],
        ['get', 'name'],
      ];
      for (final layer in (style['layers'] as List).whereType<Map<String, dynamic>>()) {
        final layout = layer['layout'];
        if (layout is! Map<String, dynamic>) continue;
        final tf = layout['text-field'];
        if (tf == null) continue;
        final text = jsonEncode(tf);
        // Only place/street/POI names – keep house numbers, road refs and shields as they are.
        if (text.contains('name') && !text.contains('housenumber') && !text.contains('"ref"')) {
          layout['text-field'] = label;
        }
      }
      return jsonEncode(style);
    } catch (_) {
      _cache.remove('$url|$lang');
      return url;
    }
  });
}
