// ÖBB HAFAS (mgate.exe). Independent second opinion for cross-border trips, Nightjet, Westbahn,
// and trains into Austria/Switzerland/Italy. No prices.
import 'dart:convert';

import '../core/net.dart';
import '../core/util.dart';
import '../models/journey.dart';
import 'source.dart';

final _endpoint = Uri.parse('https://fahrplan.oebb.at/bin/mgate.exe');

Map<String, dynamic> _envelope(Map<String, dynamic> svcReq) => {
  'lang': 'de',
  'svcReqL': [svcReq],
  'client': {'type': 'IPH', 'id': 'OEBB', 'v': '6030600', 'name': 'oebbPROD-ADHOC'},
  'ver': '1.45',
  'auth': {'type': 'AID', 'aid': 'OWDL4fE4ixNiPBBm'},
};

Mode _modeForClass(int? cls) => switch (cls) {
  1 || 2 || 4 || 8 || 4096 => Mode.long,
  16 => Mode.regional,
  32 => Mode.suburban,
  64 || 2048 => Mode.bus,
  128 => Mode.ferry,
  256 => Mode.metro,
  512 => Mode.tram,
  _ => Mode.other,
};

class OebbSource implements Source {
  @override
  String get id => 'oebb';
  @override
  String get label => 'ÖBB';
  @override
  bool get corsFriendly => false;

  Future<Map<String, dynamic>> _call(
    Map<String, dynamic> svcReq, {
    Duration timeout = const Duration(seconds: 15),
    Duration? cacheFor,
  }) async {
    Future<Object?> post() => Net.instance.postJson(_endpoint, _envelope(svcReq), timeout: timeout, needsProxy: true);
    final body = cacheFor == null ? await post() : await cache.get('oebb:${jsonEncode(svcReq)}', cacheFor, post);
    if (body is! Map<String, dynamic>) throw SourceException('unreadable answer from ÖBB');
    if (body['err'] != null && body['err'] != 'OK') throw SourceException('ÖBB: ${body['errTxt'] ?? body['err']}');
    final svc = (body['svcResL'] as List?)?.firstOrNull as Map<String, dynamic>?;
    if (svc == null) throw SourceException('unreadable answer from ÖBB');
    if (svc['err'] != 'OK') {
      final err = svc['err'].toString();
      if (err == 'H890' || err == 'H895' || err == 'H9380') return const {}; // no connections found
      throw SourceException('ÖBB: ${svc['errTxt'] ?? err}', transient: err == 'H9220' || err.startsWith('SQ'));
    }
    return (svc['res'] as Map<String, dynamic>?) ?? const {};
  }

  Future<String> _resolve(Place p) async {
    if (p.oebbId != null) return p.oebbId!;
    final res = await cache.get('oebb:loc:${p.name}', const Duration(hours: 1), () {
      return _call({
        'meth': 'LocMatch',
        'req': {
          'input': {
            'loc': {'type': 'S', 'name': '${p.name}?'},
            'maxLoc': 5,
            'field': 'S',
          },
        },
      }, timeout: const Duration(seconds: 8));
    });
    final locs = (((res['match'] as Map?)?['locL'] as List?) ?? [])
        .whereType<Map<String, dynamic>>()
        .map((l) {
          final crd = l['crd'] as Map?;
          return (
            id: (l['extId'] ?? parseLidL(l['lid'] as String?))?.toString(),
            lat: (crd?['y'] as num?) != null ? (crd!['y'] as num) / 1e6 : null,
            lon: (crd?['x'] as num?) != null ? (crd!['x'] as num) / 1e6 : null,
          );
        })
        .where((l) => l.id != null)
        .toList();
    if (locs.isEmpty) throw SourceException('ÖBB does not know "${p.name}"');
    // prefer the candidate closest to the coordinates the user picked – and never a namesake far away
    // (a wrong match sent searches off to e.g. St. Gallen)
    if (p.hasCoords) {
      locs.sort((a, b) => distKm(p.lat, p.lon, a.lat, a.lon).compareTo(distKm(p.lat, p.lon, b.lat, b.lon)));
      final d = distKm(p.lat, p.lon, locs.first.lat, locs.first.lon);
      if (d > 5) throw SourceException('ÖBB has no station near ${p.name}');
    }
    return locs.first.id!;
  }

  @override
  Future<List<Journey>> journeys(Place from, Place to, SearchOptions opts) async {
    final ids = await Future.wait([_resolve(from), _resolve(to)]);
    final w = cetWallClock(opts.when);
    final res = await _call({
      'cfg': {'polyEnc': 'GPA'},
      'meth': 'TripSearch',
      'req': {
        'getPasslist': true,
        'maxChg': opts.maxTransfers ?? -1,
        'minChgTime': opts.minTransferMinutes,
        'depLocL': [
          {'type': 'S', 'lid': 'A=1@L=${ids[0]}@'},
        ],
        'viaLocL': [],
        'arrLocL': [
          {'type': 'S', 'lid': 'A=1@L=${ids[1]}@'},
        ],
        'jnyFltrL': [
          {'type': 'PROD', 'mode': 'INC', 'value': '7167'},
          if (opts.bike) {'type': 'BC', 'mode': 'INC'},
        ],
        'gisFltrL': [],
        // No prices from ÖBB, but a booking link for each exact connection.
        'getTariff': true,
        'trfReq': {
          'jnyCl': opts.firstClass ? 1 : 2,
          'tvlrProf': [
            {'type': 'E'},
          ],
          'cType': 'PK',
        },
        'ushrp': true,
        'getPT': true,
        'getIV': false,
        'getPolyline': false,
        'outDate': '${w.year}${two(w.month)}${two(w.day)}',
        'outTime': '${two(w.hour)}${two(w.minute)}00',
        'numF': opts.results,
        'outFrwd': !opts.arriveBy,
      },
    }, cacheFor: const Duration(seconds: 30));
    return parseOebbTrips(res, opts);
  }
}

String? parseLidL(String? lid) {
  final m = RegExp(r'@L=(\d+)').firstMatch(lid ?? '');
  return m?.group(1);
}

/// HAFAS times are "HHMMSS" or "DDHHMMSS" (day offset) relative to the connection date, in local time.
DateTime? hafasTime(String date, String? time, int? tzOffsetMinutes) {
  if (time == null || time.length < 6 || date.length != 8) return null;
  final dayOffset = time.length > 6 ? int.parse(time.substring(0, time.length - 6)) : 0;
  final t = time.substring(time.length - 6);
  final wall = DateTime.utc(
    int.parse(date.substring(0, 4)),
    int.parse(date.substring(4, 6)),
    int.parse(date.substring(6, 8)) + dayOffset,
    int.parse(t.substring(0, 2)),
    int.parse(t.substring(2, 4)),
    int.parse(t.substring(4, 6)),
  );
  final off = tzOffsetMinutes != null ? Duration(minutes: tzOffsetMinutes) : cetOffset(wall);
  return wall.subtract(off);
}

List<Journey> parseOebbTrips(Map<String, dynamic> res, SearchOptions opts) {
  final common = (res['common'] as Map<String, dynamic>?) ?? const {};
  final locL = ((common['locL'] as List?) ?? []).whereType<Map<String, dynamic>>().toList();
  final prodL = ((common['prodL'] as List?) ?? []).whereType<Map<String, dynamic>>().toList();
  final opL = ((common['opL'] as List?) ?? []).whereType<Map<String, dynamic>>().toList();
  final remL = ((common['remL'] as List?) ?? []).whereType<Map<String, dynamic>>().toList();

  Place loc(int? i) {
    if (i == null || i >= locL.length) return const Place(name: '');
    final l = locL[i];
    final crd = l['crd'] as Map?;
    return Place(
      name: l['name'] as String? ?? '',
      lat: crd?['y'] is num ? (crd!['y'] as num) / 1e6 : null,
      lon: crd?['x'] is num ? (crd!['x'] as num) / 1e6 : null,
      oebbId: (l['extId'] ?? parseLidL(l['lid'] as String?))?.toString(),
    );
  }

  final out = <Journey>[];
  for (final c in ((res['outConL'] as List?) ?? []).whereType<Map<String, dynamic>>()) {
    final date = c['date'] as String? ?? '';
    final legs = <Leg>[];
    for (final s in ((c['secL'] as List?) ?? []).whereType<Map<String, dynamic>>()) {
      final d = (s['dep'] as Map<String, dynamic>?) ?? const {};
      final a = (s['arr'] as Map<String, dynamic>?) ?? const {};
      final pDep = hafasTime(date, d['dTimeS'] as String?, d['dTZOffset'] as int?);
      final pArr = hafasTime(date, a['aTimeS'] as String?, a['aTZOffset'] as int?);
      if (pDep == null || pArr == null) continue;
      final rDep = hafasTime(date, d['dTimeR'] as String?, d['dTZOffset'] as int?);
      final rArr = hafasTime(date, a['aTimeR'] as String?, a['aTZOffset'] as int?);
      final from = loc(d['locX'] as int?), to = loc(a['locX'] as int?);
      final straight = from.hasCoords && to.hasCoords
          ? [
              [from.lat!, from.lon!],
              [to.lat!, to.lon!],
            ]
          : <List<double>>[];
      final type = s['type'];
      if (type == 'WALK' || type == 'TRSF' || type == 'DEVI' || type == 'TETA') {
        legs.add(
          Leg(
            mode: Mode.walk,
            line: 'Walk',
            from: from,
            to: to,
            dep: rDep ?? pDep,
            arr: rArr ?? pArr,
            plannedDep: pDep,
            plannedArr: pArr,
            walkDistance: ((s['gis'] as Map?)?['dist'] as num?)?.toDouble(),
            path: straight,
          ),
        );
        continue;
      }
      if (type != 'JNY') continue;
      final jny = (s['jny'] as Map<String, dynamic>?) ?? const {};
      final prodX = (jny['prodX'] ?? d['dProdX']) as int?;
      final prod = prodX != null && prodX < prodL.length ? prodL[prodX] : const <String, dynamic>{};
      final ctx = (prod['prodCtx'] as Map?) ?? const {};
      final cat = (ctx['catOut'] ?? '').toString().trim();
      final lineNo = (ctx['line'] ?? ctx['num'] ?? prod['number'] ?? '').toString().trim();
      final name = cat.isNotEmpty && lineNo.isNotEmpty
          ? (lineNo.startsWith(cat) ? lineNo : '$cat $lineNo')
          : (prod['nameS'] ?? prod['name'] ?? '').toString().replaceAll(RegExp(r'\s*\(.*\)'), '').trim();
      final oprX = prod['oprX'] as int?;
      final operator = oprX != null && oprX < opL.length ? (opL[oprX]['name'] ?? '').toString() : '';
      final mode = refineMode(_modeForClass(prod['cls'] as int?), name, operator);
      final stopL = ((jny['stopL'] as List?) ?? []).whereType<Map<String, dynamic>>().toList();
      final stops = stopL.map((st) {
        final p = loc(st['locX'] as int?);
        return Stopover(
          name: p.name,
          lat: p.lat,
          lon: p.lon,
          arr: hafasTime(date, (st['aTimeR'] ?? st['aTimeS']) as String?, st['aTZOffset'] as int?),
          dep: hafasTime(date, (st['dTimeR'] ?? st['dTimeS']) as String?, st['dTZOffset'] as int?),
          cancelled: st['aCncl'] == true || st['dCncl'] == true,
        );
      }).toList();
      final path = stops.where((x) => x.lat != null).map((x) => [x.lat!, x.lon!]).toList();
      final remarks = ((jny['msgL'] as List?) ?? [])
          .whereType<Map>()
          .where((m) => m['type'] == 'REM' && m['remX'] is int && (m['remX'] as int) < remL.length)
          .map((m) => remL[m['remX'] as int])
          .where((r) => r['type'] == 'M' || r['type'] == 'L' || (r['prio'] is int && (r['prio'] as int) < 100))
          .map((r) => (r['txtN'] ?? '').toString())
          .where((t) => t.isNotEmpty)
          .take(3)
          .toList();
      String? plat(Map<String, dynamic> m, String k) =>
          ((m['${k}PltfR'] ?? m['${k}PltfS']) as Map?)?['txt']?.toString() ?? (m['${k}PlatfR'] ?? m['${k}PlatfS'])?.toString();
      legs.add(
        Leg(
          mode: mode,
          line: name,
          operator: operator,
          direction: (jny['dirTxt'] ?? '').toString(),
          from: from,
          to: to,
          dep: rDep ?? pDep,
          arr: rArr ?? pArr,
          plannedDep: pDep,
          plannedArr: pArr,
          depDelay: rDep?.difference(pDep).inMinutes,
          arrDelay: rArr?.difference(pArr).inMinutes,
          depPlatform: plat(d, 'd'),
          arrPlatform: plat(a, 'a'),
          cancelled: jny['isCncl'] == true || d['dCncl'] == true || a['aCncl'] == true,
          stops: stops.length > 2 ? stops.sublist(1, stops.length - 1) : const [],
          path: path.length >= 2 ? path : straight,
          remarks: remarks,
        ),
      );
    }
    final transit = legs.where((l) => !l.isWalk).toList();
    if (transit.isEmpty) continue;
    if (!opts.coach && legs.any((l) => l.mode == Mode.coach)) continue;
    final dt = transit.every((l) => dticketModes.contains(l.mode));
    if (opts.dticketOnly && !dt) continue;
    final clickout = (c['trfRes'] as Map?)?['clickout'] as String?;
    out.add(Journey(source: 'oebb', legs: legs, dticket: dt, bookingUrls: {'oebb': clickout ?? 'https://shop.oebbtickets.at/'}));
  }
  return out;
}
