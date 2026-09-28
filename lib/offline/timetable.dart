// Offline timetable from GTFS (gtfs.de: long-distance + regional trains for all of Germany, ~12 MB).
// GTFS stores trains as patterns: each trip once, plus a calendar of the days it runs. So a single
// download covers every day of the timetable period (usually ~4 weeks) – no per-day data needed.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/journey.dart';

/// One service calendar: weekdays + date range, with explicit additions/removals.
class Service {
  final int weekdays; // bit 0 = Monday … bit 6 = Sunday
  final int start; // yyyymmdd
  final int end;
  final Set<int> added = {};
  final Set<int> removed = {};
  Service(this.weekdays, this.start, this.end);

  bool runsOn(DateTime day) {
    final d = day.year * 10000 + day.month * 100 + day.day;
    if (removed.contains(d)) return false;
    if (added.contains(d)) return true;
    return d >= start && d <= end && (weekdays >> (day.weekday - 1)) & 1 == 1;
  }
}

class Timetable {
  // Stops (platform level); `stopGroup` joins platforms of the same station.
  final List<String> stopName;
  final Float64List stopLat, stopLon;
  final Int32List stopGroup;

  // Routes
  final List<String> routeName;
  final Uint8List routeMode; // Mode.index

  // Trips: stop times of trip t are st*[tripStart[t] .. tripStart[t] + tripLen[t])
  final Int32List tripRoute, tripService, tripStart, tripLen;
  final List<String> tripHeadsign;

  // Stop times: seconds after midnight of the service day (can exceed 24 h)
  final Int32List stStop, stArr, stDep;

  final List<Service> services;
  final int validFrom, validTo; // yyyymmdd

  Timetable({
    required this.stopName,
    required this.stopLat,
    required this.stopLon,
    required this.stopGroup,
    required this.routeName,
    required this.routeMode,
    required this.tripRoute,
    required this.tripService,
    required this.tripStart,
    required this.tripLen,
    required this.tripHeadsign,
    required this.stStop,
    required this.stArr,
    required this.stDep,
    required this.services,
    required this.validFrom,
    required this.validTo,
  });

  int get stopCount => stopName.length;
  int get tripCount => tripRoute.length;

  DateTime get validFromDate => DateTime(validFrom ~/ 10000, validFrom ~/ 100 % 100, validFrom % 100);
  DateTime get validToDate => DateTime(validTo ~/ 10000, validTo ~/ 100 % 100, validTo % 100);
}

// ---------------------------------------------------------------- parsing

/// Minimal CSV line splitter (handles quoted fields with commas and doubled quotes).
List<String> _split(String line) {
  if (!line.contains('"')) return line.split(',');
  final out = <String>[];
  final b = StringBuffer();
  var q = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (q) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          b.write('"');
          i++;
        } else {
          q = false;
        }
      } else {
        b.write(c);
      }
    } else if (c == '"') {
      q = true;
    } else if (c == ',') {
      out.add(b.toString());
      b.clear();
    } else {
      b.write(c);
    }
  }
  out.add(b.toString());
  return out;
}

/// Iterates the rows of a CSV file as maps from column name to index-accessible list.
Iterable<(Map<String, int>, List<String>)> _rows(String text) sync* {
  final lines = const LineSplitter().convert(text.startsWith('﻿') ? text.substring(1) : text);
  if (lines.isEmpty) return;
  final header = _split(lines.first);
  final idx = {for (var i = 0; i < header.length; i++) header[i].trim(): i};
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].isEmpty) continue;
    yield (idx, _split(lines[i]));
  }
}

String _get(Map<String, int> idx, List<String> row, String col) {
  final i = idx[col];
  return i == null || i >= row.length ? '' : row[i];
}

int _secs(String t) {
  // "HH:MM:SS", hours may exceed 23
  final p = t.split(':');
  if (p.length < 2) return -1;
  return int.parse(p[0].trim()) * 3600 + int.parse(p[1]) * 60 + (p.length > 2 ? int.parse(p[2]) : 0);
}

Mode _modeFor(String name, int routeType) {
  final n = name.toUpperCase();
  if (RegExp(r'^(NJ|EN|ES)\b').hasMatch(n)) return Mode.night;
  if (RegExp(r'^(ICE|IC|EC|ECE|RJX?|FLX|TGV|D)\b').hasMatch(n)) return Mode.long;
  if (RegExp(r'^S\s?\d|^S\b').hasMatch(n)) return Mode.suburban;
  if (RegExp(r'^U\s?\d').hasMatch(n)) return Mode.metro;
  return switch (routeType) {
    0 || 900 || 901 => Mode.tram,
    1 || 400 || 401 || 402 => Mode.metro,
    3 || 700 || 701 || 702 || 704 => Mode.bus,
    4 || 1000 => Mode.ferry,
    101 || 102 => Mode.long,
    109 => Mode.suburban,
    _ => Mode.regional,
  };
}

/// Parses one or more gtfs.de zip files (bytes) into one timetable. Run in an isolate: it's CPU-heavy.
Timetable parseGtfsZips(List<Uint8List> zips) {
  final stopName = <String>[];
  final lat = <double>[], lon = <double>[];
  final groupKey = <String>[];
  final routeName = <String>[];
  final routeMode = <int>[];
  final tripRoute = <int>[], tripService = <int>[], tripStart = <int>[], tripLen = <int>[];
  final tripHeadsign = <String>[];
  final stStop = <int>[], stArr = <int>[], stDep = <int>[];
  final services = <Service>[];
  var validFrom = 99999999, validTo = 0;

  for (var f = 0; f < zips.length; f++) {
    final archive = ZipDecoder().decodeBytes(zips[f]);
    String file(String name) {
      final e = archive.findFile(name);
      return e == null ? '' : utf8.decode(e.content as List<int>, allowMalformed: true);
    }

    final stopIdx = <String, int>{};
    for (final (idx, r) in _rows(file('stops.txt'))) {
      final id = _get(idx, r, 'stop_id');
      stopIdx[id] = stopName.length;
      stopName.add(_get(idx, r, 'stop_name'));
      lat.add(double.tryParse(_get(idx, r, 'stop_lat')) ?? 0);
      lon.add(double.tryParse(_get(idx, r, 'stop_lon')) ?? 0);
      final parent = _get(idx, r, 'parent_station');
      // Group platforms by station; stations with the same name across feeds are joined below.
      groupKey.add(parent.isNotEmpty ? 'p$f:$parent' : 'n:${_get(idx, r, 'stop_name')}');
    }

    final routeIdx = <String, int>{};
    for (final (idx, r) in _rows(file('routes.txt'))) {
      routeIdx[_get(idx, r, 'route_id')] = routeName.length;
      final short = _get(idx, r, 'route_short_name').trim();
      final name = short.isNotEmpty ? short : _get(idx, r, 'route_long_name').trim();
      routeName.add(name);
      routeMode.add(_modeFor(name, int.tryParse(_get(idx, r, 'route_type')) ?? 2).index);
    }

    final serviceIdx = <String, int>{};
    for (final (idx, r) in _rows(file('calendar.txt'))) {
      var wd = 0;
      const days = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
      for (var d = 0; d < 7; d++) {
        if (_get(idx, r, days[d]) == '1') wd |= 1 << d;
      }
      final start = int.tryParse(_get(idx, r, 'start_date')) ?? 0, end = int.tryParse(_get(idx, r, 'end_date')) ?? 0;
      serviceIdx[_get(idx, r, 'service_id')] = services.length;
      services.add(Service(wd, start, end));
      if (start < validFrom) validFrom = start;
      if (end > validTo) validTo = end;
    }
    for (final (idx, r) in _rows(file('calendar_dates.txt'))) {
      final sid = _get(idx, r, 'service_id');
      final i = serviceIdx.putIfAbsent(sid, () {
        services.add(Service(0, 0, 0));
        return services.length - 1;
      });
      final date = int.tryParse(_get(idx, r, 'date')) ?? 0;
      if (_get(idx, r, 'exception_type') == '1') {
        services[i].added.add(date);
        if (date > validTo) validTo = date;
      } else {
        services[i].removed.add(date);
      }
    }

    final tripIdx = <String, int>{};
    final tripFirst = tripRoute.length;
    for (final (idx, r) in _rows(file('trips.txt'))) {
      tripIdx[_get(idx, r, 'trip_id')] = tripRoute.length;
      tripRoute.add(routeIdx[_get(idx, r, 'route_id')] ?? 0);
      tripService.add(serviceIdx[_get(idx, r, 'service_id')] ?? 0);
      tripStart.add(0);
      tripLen.add(0);
      tripHeadsign.add(_get(idx, r, 'trip_headsign'));
    }

    // stop_times: flat arrays first, then a counting sort by trip and a small sort by stop_sequence
    // per trip – keeps memory low on phones (1.5 M rows).
    final nTrips = tripRoute.length - tripFirst;
    final rTrip = <int>[], rSeq = <int>[], rStop = <int>[], rArr = <int>[], rDep = <int>[];
    final headAt = List<int>.filled(nTrips, 1 << 30); // lowest stop_sequence that carried a headsign
    for (final (idx, r) in _rows(file('stop_times.txt'))) {
      final t = tripIdx[_get(idx, r, 'trip_id')];
      final s = stopIdx[_get(idx, r, 'stop_id')];
      if (t == null || s == null) continue;
      final a = _secs(_get(idx, r, 'arrival_time')), d = _secs(_get(idx, r, 'departure_time'));
      final seq = int.tryParse(_get(idx, r, 'stop_sequence')) ?? 0;
      rTrip.add(t - tripFirst);
      rSeq.add(seq);
      rStop.add(s);
      rArr.add(a < 0 ? d : a);
      rDep.add(d < 0 ? a : d);
      final head = _get(idx, r, 'stop_headsign');
      if (head.isNotEmpty && seq < headAt[t - tripFirst] && tripHeadsign[t].isEmpty) {
        headAt[t - tripFirst] = seq;
        tripHeadsign[t] = head;
      }
    }
    final count = Int32List(nTrips + 1);
    for (final t in rTrip) {
      count[t + 1]++;
    }
    for (var i = 0; i < nTrips; i++) {
      count[i + 1] += count[i];
    }
    final order = Int32List(rTrip.length);
    final fill = Int32List.fromList(count);
    for (var i = 0; i < rTrip.length; i++) {
      order[fill[rTrip[i]]++] = i;
    }
    for (var i = 0; i < nTrips; i++) {
      final t = tripFirst + i;
      final from = count[i], to = count[i + 1];
      tripStart[t] = stStop.length;
      tripLen[t] = to - from;
      final rows = order.sublist(from, to)..sort((a, b) => rSeq[a].compareTo(rSeq[b]));
      for (final k in rows) {
        stStop.add(rStop[k]);
        stArr.add(rArr[k]);
        stDep.add(rDep[k]);
      }
      if (tripHeadsign[t].isEmpty && rows.isNotEmpty) tripHeadsign[t] = stopName[rStop[rows.last]];
    }
  }

  // Station groups: same parent, or same name (joins long-distance and regional feeds).
  final groupOf = <String, int>{};
  final nameGroup = <String, int>{};
  final group = Int32List(stopName.length);
  var nextGroup = 0;
  for (var i = 0; i < stopName.length; i++) {
    final g = groupOf[groupKey[i]] ?? nameGroup[stopName[i]] ?? nextGroup++;
    groupOf.putIfAbsent(groupKey[i], () => g);
    nameGroup.putIfAbsent(stopName[i], () => g);
    group[i] = g;
  }

  return Timetable(
    stopName: stopName,
    stopLat: Float64List.fromList(lat),
    stopLon: Float64List.fromList(lon),
    stopGroup: group,
    routeName: routeName,
    routeMode: Uint8List.fromList(routeMode),
    tripRoute: Int32List.fromList(tripRoute),
    tripService: Int32List.fromList(tripService),
    tripStart: Int32List.fromList(tripStart),
    tripLen: Int32List.fromList(tripLen),
    tripHeadsign: tripHeadsign,
    stStop: Int32List.fromList(stStop),
    stArr: Int32List.fromList(stArr),
    stDep: Int32List.fromList(stDep),
    services: services,
    validFrom: validFrom == 99999999 ? 0 : validFrom,
    validTo: validTo,
  );
}
