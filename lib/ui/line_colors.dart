// Every train family (ICE, IC, RE, RB, S, FLX, ...) has a base colour; every individual line/train
// gets its own stable shade of it, so two REs in one journey are still easy to tell apart.
import 'package:flutter/material.dart';

import '../models/journey.dart';

class Family {
  final String key;
  final String label;
  final double hue;
  final double sat;
  const Family(this.key, this.label, this.hue, this.sat);
}

const families = <Family>[
  Family('ice', 'ICE', 0, 0.78),
  Family('ic', 'IC / EC', 22, 0.85),
  Family('rj', 'Railjet', 340, 0.62),
  Family('flx', 'FlixTrain', 88, 0.80),
  Family('rgj', 'RegioJet', 48, 0.95),
  Family('night', 'Nightjet / Nachtzug', 250, 0.55),
  Family('re', 'RE / IRE', 212, 0.75),
  Family('rb', 'RB', 188, 0.70),
  Family('s', 'S-Bahn', 140, 0.60),
  Family('u', 'U-Bahn', 265, 0.55),
  Family('tram', 'Tram', 315, 0.55),
  Family('bus', 'Bus', 32, 0.35),
  Family('coach', 'FlixBus', 50, 0.85),
  Family('ferry', 'Ferry', 198, 0.40),
  Family('other', 'Other', 220, 0.08),
  Family('walk', 'Walk', 0, 0),
];

final _byKey = {for (final f in families) f.key: f};

final _prefixes = <(RegExp, String)>[
  (RegExp(r'^ICE'), 'ice'),
  (RegExp(r'^(RJX?)(?![A-Za-z])'), 'rj'),
  (RegExp(r'^(IC|EC|ECE|IR|D)(?![A-Za-z])'), 'ic'),
  (RegExp(r'^(FLX|FlixTrain)', caseSensitive: false), 'flx'),
  (RegExp(r'^(RGJ|RegioJet)', caseSensitive: false), 'rgj'),
  (RegExp(r'^(NJ|EN|ES|ENJ|SJ)(?![A-Za-z])'), 'night'),
  (RegExp(r'^(RE|IRE|MEX|REX|RS|FEX|ALX|WFB|ERX|NWB)(?![A-Za-z])'), 're'),
  (RegExp(r'^(RB|R|BRB|ag|erx|HLB|ODEG|NEB)(?![A-Za-z])'), 'rb'),
  (RegExp(r'^S\s?\d|^S\b'), 's'),
  (RegExp(r'^U\s?\d|^U\b'), 'u'),
  (RegExp(r'^(STR|Tram|M\d)', caseSensitive: false), 'tram'),
  (RegExp(r'^FlixBus', caseSensitive: false), 'coach'),
  (RegExp(r'^(Bus|BUS|RUF|AST)\b'), 'bus'),
];

Family familyOf(Leg l) {
  if (l.isWalk) return _byKey['walk']!;
  final name = l.line.trim();
  if (l.mode == Mode.night) return _byKey['night']!;
  for (final (re, key) in _prefixes) {
    if (re.hasMatch(name)) return _byKey[key]!;
  }
  return _byKey[switch (l.mode) {
    Mode.long => 'ic',
    Mode.regional => 'rb',
    Mode.suburban => 's',
    Mode.metro => 'u',
    Mode.tram => 'tram',
    Mode.bus => 'bus',
    Mode.coach => 'coach',
    Mode.ferry => 'ferry',
    _ => 'other',
  }]!;
}

/// Stable 32-bit FNV-1a hash (String.hashCode is not stable across runs/platforms).
int _hash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

String _lineKey(String line) => line.toUpperCase().replaceAll(RegExp(r'\s+'), '');

Color familyColor(Family f, Brightness b) {
  // Walking: a clear slate grey – visible on the map and in the strip, but never mistaken for a train.
  if (f.key == 'walk') return b == Brightness.dark ? const Color(0xFFA7B2BD) : const Color(0xFF5B6873);
  final light = b == Brightness.dark ? 0.62 : 0.45;
  return HSLColor.fromAHSL(1, f.hue, f.sat, light).toColor();
}

Color lineColor(Leg l, Brightness b) {
  final f = familyOf(l);
  if (f.key == 'walk') return familyColor(f, b);
  final h = _hash(_lineKey(l.line));
  // Spread shades: lightness ±0.15, hue ±9°, saturation ±0.08 – still clearly the family colour.
  final dl = ((h & 0xff) / 255 - 0.5) * 0.30;
  final dh = (((h >> 8) & 0xff) / 255 - 0.5) * 18;
  final ds = (((h >> 16) & 0xff) / 255 - 0.5) * 0.16;
  final base = b == Brightness.dark ? 0.62 : 0.45;
  return HSLColor.fromAHSL(
    1,
    (f.hue + dh) % 360,
    (f.sat + ds).clamp(0.0, 1.0),
    (base + dl).clamp(b == Brightness.dark ? 0.45 : 0.28, b == Brightness.dark ? 0.78 : 0.60),
  ).toColor();
}

/// Readable text on top of a line colour.
Color onLineColor(Color c) => c.computeLuminance() > 0.45 ? Colors.black87 : Colors.white;
