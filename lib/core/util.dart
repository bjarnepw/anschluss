import 'dart:math';

import '../models/journey.dart';

/// Google encoded polyline with arbitrary precision -> [[lat, lon], ...]
List<List<double>> decodePolyline(String str, [int precision = 5]) {
  final factor = pow(10, precision).toDouble();
  final out = <List<double>>[];
  var i = 0, lat = 0, lon = 0;
  while (i < str.length) {
    for (var which = 0; which < 2; which++) {
      var shift = 0, result = 0, b = 0;
      do {
        b = str.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && i < str.length);
      final d = (result & 1) != 0 ? ~(result >> 1) : result >> 1;
      if (which == 0) {
        lat += d;
      } else {
        lon += d;
      }
    }
    out.add([lat / factor, lon / factor]);
  }
  return out;
}

double distKm(double? aLat, double? aLon, double? bLat, double? bLon) {
  if (aLat == null || aLon == null || bLat == null || bLon == null) return double.infinity;
  const r = 6371.0, rad = pi / 180;
  final dLat = (bLat - aLat) * rad, dLon = (bLon - aLon) * rad;
  final s = pow(sin(dLat / 2), 2) + cos(aLat * rad) * cos(bLat * rad) * pow(sin(dLon / 2), 2);
  return 2 * r * asin(sqrt(s));
}

double placeDist(Place a, Place b) => distKm(a.lat, a.lon, b.lat, b.lon);

/// UTC offset of Central European (Summer) Time at [utc]: +2h between the last Sunday of March
/// 01:00 UTC and the last Sunday of October 01:00 UTC, else +1h. Same rule for Berlin and Vienna.
Duration cetOffset(DateTime utc) {
  DateTime lastSunday(int year, int month) {
    final last = DateTime.utc(year, month + 1, 0);
    return DateTime.utc(year, month, last.day - (last.weekday % 7), 1);
  }

  final u = utc.toUtc();
  final start = lastSunday(u.year, 3), end = lastSunday(u.year, 10);
  return (u.isAfter(start) || u.isAtSameMomentAs(start)) && u.isBefore(end) ? const Duration(hours: 2) : const Duration(hours: 1);
}

/// Wall-clock time in Germany/Austria for [utc] (fields are local, the object is marked UTC).
DateTime cetWallClock(DateTime utc) => utc.toUtc().add(cetOffset(utc));

String two(int n) => n.toString().padLeft(2, '0');

/// "2026-09-29T08:00:00+02:00"
String cetIso(DateTime t) {
  final off = cetOffset(t);
  final w = cetWallClock(t);
  return '${w.year}-${two(w.month)}-${two(w.day)}T${two(w.hour)}:${two(w.minute)}:${two(w.second)}+${two(off.inHours)}:00';
}

/// Night trains and open-access trains we can recognise by name in any source.
Mode refineMode(Mode mode, String name, String operator) {
  final s = '$name $operator';
  if (RegExp(r'\b(NJ|EN|ES)\s?\d').hasMatch(s) ||
      RegExp(r'nightjet|european sleeper|snälltåget|snalltaget|nachtzug', caseSensitive: false).hasMatch(s)) {
    return Mode.night;
  }
  if (RegExp(r'\bFLX\b|flixtrain', caseSensitive: false).hasMatch(s)) return Mode.long;
  return mode;
}

T? firstOrNull<T>(Iterable<T> it) => it.isEmpty ? null : it.first;
