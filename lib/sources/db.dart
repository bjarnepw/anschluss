// Deutsche Bahn via the DB Navigator ("vendo"/"movas") API at app.services-bahn.de.
// Port of the request/response handling in db-vendo-client's `dbnav` profile.
// Covers DB Fernverkehr, nearly all German regional operators, local transport, plus timetables of
// FlixTrain / Nightjet / European Sleeper. Unofficial; rate-limited (~60 req/min) and may block networks.
import 'dart:math';

import '../core/net.dart';
import '../core/util.dart';
import '../models/journey.dart';
import 'source.dart';

const _base = 'https://app.services-bahn.de/mob';

const _products = {
  // vendo produktGattung / dbnav short -> mode
  'ICE': Mode.long, 'EC_IC': Mode.long, 'IC_EC': Mode.long, 'IR': Mode.long,
  'REGIONAL': Mode.regional, 'RB': Mode.regional, 'SBAHN': Mode.suburban, 'UBAHN': Mode.metro,
  'TRAM': Mode.tram, 'STR': Mode.tram, 'BUS': Mode.bus, 'SCHIFF': Mode.ferry,
  'ANRUFPFLICHTIG': Mode.bus, 'ANRUFPFLICHTIGEVERKEHRE': Mode.bus,
};

String _uuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

Map<String, String> _headers(String contentType) => {
  'X-Correlation-ID': '${_uuid()}_${_uuid()}',
  'Accept': contentType,
  'Content-Type': contentType,
  'Accept-Language': 'de',
};

/// Parses a HAFAS location id like "A=1@O=Berlin Hbf@X=13369549@Y=52525589@L=8011160@".
Map<String, String> parseLid(String? lid) {
  final out = <String, String>{};
  for (final part in (lid ?? '').split('@')) {
    final i = part.indexOf('=');
    if (i > 0) out[part.substring(0, i)] = part.substring(i + 1);
  }
  return out;
}

Place? dbPlace(Map<String, dynamic>? l) {
  if (l == null) return null;
  final lid = parseLid((l['id'] ?? l['locationId']) as String?);
  final name = (l['name'] ?? lid['O']) as String?;
  if (name == null || name.isEmpty) return null;
  final idRaw = (l['extId'] ?? l['evaNr'] ?? lid['L'] ?? l['evaNumber'] ?? l['bahnhofsId'])?.toString();
  final id = idRaw?.replaceFirst(RegExp(r'^0+'), '');
  double? lat, lon;
  final c = (l['coordinates'] ?? l['position']) as Map<String, dynamic>?;
  if (l['lat'] is num && l['lon'] is num) {
    lat = (l['lat'] as num).toDouble();
    lon = (l['lon'] as num).toDouble();
  } else if (c != null) {
    lat = (c['latitude'] as num?)?.toDouble();
    lon = (c['longitude'] as num?)?.toDouble();
  } else if (lid['X'] != null && lid['Y'] != null) {
    lat = int.parse(lid['Y']!) / 1e6;
    lon = int.parse(lid['X']!) / 1e6;
  }
  return Place(name: name, lat: lat, lon: lon, dbId: (id?.isNotEmpty ?? false) ? id : null);
}

class DbSource implements Source, LocationSource {
  @override
  String get id => 'db';
  @override
  String get label => 'Deutsche Bahn';
  @override
  bool get corsFriendly => false;

  @override
  Future<List<Place>> locations(String q) async {
    final res = await cache.get('db:loc:$q', const Duration(hours: 1), () {
      return Net.instance.postJson(
        Uri.parse('$_base/location/search'),
        {
          'locationTypes': ['ST'],
          'searchTerm': q,
          'maxResults': 8,
        },
        headers: _headers('application/x.db.vendo.mob.location.v3+json'),
        timeout: const Duration(seconds: 6),
        needsProxy: true,
      );
    });
    final list = res is List ? res : const [];
    return list.whereType<Map<String, dynamic>>().map(dbPlace).whereType<Place>().where((p) => p.dbId != null).toList();
  }

  Future<String> _resolve(Place p) async {
    if (p.dbId != null) return p.dbId!;
    final hits = await locations(p.name);
    if (hits.isEmpty) throw SourceException('DB does not know "${p.name}"');
    if (p.hasCoords) {
      hits.sort((a, b) => placeDist(p, a).compareTo(placeDist(p, b)));
      // Never a namesake far away from what was picked.
      if (hits.first.hasCoords && placeDist(p, hits.first) > 5) throw SourceException('DB has no station near ${p.name}');
    }
    return hits.first.dbId!;
  }

  static String bookingUrl(Place from, Place to, DateTime when, bool firstClass) {
    final w = cetWallClock(when);
    final p = Uri(
      queryParameters: {
        'sts': 'true',
        'so': from.name,
        'zo': to.name,
        'hd': '${w.year}-${two(w.month)}-${two(w.day)}T${two(w.hour)}:${two(w.minute)}:00',
        'kl': firstClass ? '1' : '2',
      },
    ).query;
    return 'https://www.bahn.de/buchung/fahrplan/suche#$p';
  }

  @override
  Future<List<Journey>> journeys(Place from, Place to, SearchOptions opts) async {
    final ids = await Future.wait([_resolve(from), _resolve(to)]);
    final ermaessigung = opts.bahncard > 0
        ? 'BAHNCARD${opts.bahncard} ${opts.firstClass ? 'KLASSE_1' : 'KLASSE_2'}'
        : 'KEINE_ERMAESSIGUNG KLASSENLOS';
    final body = {
      'autonomeReservierung': false,
      'einstiegsTypList': ['STANDARD'],
      'fahrverguenstigungen': {'deutschlandTicketVorhanden': opts.dticket, 'nurDeutschlandTicketVerbindungen': opts.dticketOnly},
      'klasse': opts.firstClass ? 'KLASSE_1' : 'KLASSE_2',
      'reisendenProfil': {
        'reisende': [
          {
            'ermaessigungen': [ermaessigung],
            'reisendenTyp': _ageGroup(opts.age),
            if (opts.age != null) 'alter': opts.age,
          },
        ],
      },
      'reservierungsKontingenteVorhanden': false,
      'reiseHin': {
        'wunsch': {
          'abgangsLocationId': 'A=1@L=${ids[0]}@',
          'verkehrsmittel': ['ALL'],
          'alternativeHalteBerechnung': true,
          'zeitWunsch': {'reiseDatum': cetIso(opts.when), 'zeitPunktArt': opts.arriveBy ? 'ANKUNFT' : 'ABFAHRT'},
          'zielLocationId': 'A=1@L=${ids[1]}@',
          if (opts.maxTransfers != null) 'maxUmstiege': opts.maxTransfers,
          if (opts.minTransferMinutes > 0) 'minUmstiegsdauer': opts.minTransferMinutes,
          if (opts.bike) 'fahrradmitnahme': true,
          // Also return slower but cheaper connections, not only the fastest ones.
          if (opts.moreAlternatives) 'economic': true,
        },
      },
    };
    final res = await Net.instance.postJson(
      Uri.parse('$_base/angebote/fahrplan'),
      body,
      headers: _headers('application/x.db.vendo.mob.verbindungssuche.v9+json'),
      timeout: const Duration(seconds: 20),
      needsProxy: true,
    );
    if (res is Map && res['fehlerNachricht'] != null) {
      final f = res['fehlerNachricht'] as Map;
      throw SourceException((f['ueberschrift'] ?? f['text'] ?? 'DB error').toString());
    }
    final url = bookingUrl(from, to, opts.when, opts.firstClass);
    return parseDbJourneys(res as Map<String, dynamic>, bookingUrl: url);
  }

  static String _ageGroup(int? age) {
    if (age == null) return 'ERWACHSENER';
    if (age < 6) return 'KLEINKIND';
    if (age < 15) return 'FAMILIENKIND';
    if (age < 27) return 'JUGENDLICHER';
    if (age < 65) return 'ERWACHSENER';
    return 'SENIOR';
  }
}

// ---------- response parsing ----------

final _tzSuffix = RegExp(r'([+-]\d\d:\d\d|Z)$');

DateTime? _t(Object? s) => s is String ? DateTime.tryParse(s) : null;

bool _stopCancelled(Map<String, dynamic> s) {
  if (s['canceled'] == true || s['cancelled'] == true) return true;
  final notes = (s['risNotizen'] ?? s['echtzeitNotizen'] ?? s['meldungen']) as List?;
  return notes?.whereType<Map>().any((r) => r['key'] == 'text.realtime.stop.cancelled' || r['type'] == 'HALT_AUSFALL') ?? false;
}

Place _stopPlace(Map<String, dynamic> s) => dbPlace((s['ort'] ?? s['station'] ?? s) as Map<String, dynamic>) ?? const Place(name: '');

List<String> _remarks(Map<String, dynamic> pt) {
  final out = <String>[];
  for (final key in ['echtzeitNotizen', 'risNotizen', 'himNotizen', 'himMeldungen', 'priorisierteMeldungen']) {
    for (final r in ((pt[key] as List?) ?? []).whereType<Map>()) {
      final prio = r['prioritaet'] ?? r['prio'];
      final important = key == 'echtzeitNotizen' || key == 'risNotizen' || prio == 'HOCH';
      if (!important) continue;
      final text = (r['value'] ?? r['text'] ?? r['ueberschrift'])?.toString();
      if (text != null && text.isNotEmpty && !out.contains(text)) out.add(text);
    }
  }
  return out.take(3).toList();
}

Leg? _dbLeg(Map<String, dynamic> pt, {bool fixWalkTz = false}) {
  final stops = ((pt['halte'] as List?) ?? []).whereType<Map<String, dynamic>>().toList();
  final type = ((pt['verkehrsmittel'] as Map?)?['typ'] ?? pt['typ'])?.toString();
  final walking = type == 'WALK' || type == 'FUSSWEG' || type == 'TRANSFER';

  String? plannedDepS = (pt['abgangsDatum'] ?? (stops.isNotEmpty ? stops.first['abgangsDatum'] : null)) as String?;
  String? rtDepS = (pt['ezAbgangsDatum'] ?? (stops.isNotEmpty ? stops.first['ezAbgangsDatum'] : null)) as String?;
  String? plannedArrS = (pt['ankunftsDatum'] ?? (stops.isNotEmpty ? stops.last['ankunftsDatum'] : null)) as String?;
  String? rtArrS = (pt['ezAnkunftsDatum'] ?? (stops.isNotEmpty ? stops.last['ezAnkunftsDatum'] : null)) as String?;

  // DB sometimes sends realtime of first/last walking legs in the wrong time zone (db-vendo-client #24).
  if (fixWalkTz && walking) {
    String? fix(String? planned, String? rt) {
      if (planned == null || rt == null) return rt;
      final off = _tzSuffix.firstMatch(planned)?.group(0);
      return off == null ? rt : rt.replaceFirst(_tzSuffix, off);
    }

    rtDepS = fix(plannedDepS, rtDepS);
    rtArrS = fix(plannedArrS, rtArrS);
  }

  final plannedDep = _t(plannedDepS), plannedArr = _t(plannedArrS);
  if (plannedDep == null || plannedArr == null) return null;
  final dep = _t(rtDepS) ?? plannedDep;
  var arr = _t(rtArrS) ?? plannedArr;

  final from = stops.isNotEmpty
      ? _stopPlace(stops.first)
      : dbPlace(pt['abgangsOrt'] as Map<String, dynamic>?) ?? Place(name: pt['abfahrtsOrt']?.toString() ?? '');
  final to = stops.isNotEmpty
      ? _stopPlace(stops.last)
      : dbPlace(pt['ankunftsOrt'] as Map<String, dynamic>?) ?? Place(name: pt['ankunftsOrt']?.toString() ?? '');

  List<List<double>> straight() => from.hasCoords && to.hasCoords
      ? [
          [from.lat!, from.lon!],
          [to.lat!, to.lon!],
        ]
      : [];

  if (walking) {
    if (from.dbId != null && from.dbId == to.dbId) arr = dep;
    return Leg(
      mode: Mode.walk,
      line: 'Walk',
      from: from,
      to: to,
      dep: dep,
      arr: arr.isBefore(dep) ? dep : arr,
      plannedDep: plannedDep,
      plannedArr: plannedArr,
      walkDistance: (pt['distanz'] as num?)?.toDouble(),
      path: straight(),
    );
  }

  // The movas API puts line info flat on the leg (mitteltext, produktGattung, ...); older variants nest it
  // in `verkehrsmittel`. Accept both.
  final vm = (pt['verkehrsmittel'] as Map<String, dynamic>?) ?? const {};
  var name = (vm['name'] ?? vm['langText'] ?? pt['mitteltext'] ?? pt['langtext'] ?? '').toString().trim();
  if (name.isEmpty) {
    name = [pt['kurztext'] ?? vm['kurzText'], pt['zugNummer'] ?? pt['verkehrsmittelNummer']].whereType<Object>().join(' ').trim();
  }
  final attrs = ((vm['zugattribute'] ?? pt['zugattribute'] ?? pt['attributNotizen']) as List?)?.whereType<Map>() ?? const [];
  final operator = firstOrNull(attrs.where((a) => a['key'] == 'BEF' || a['key'] == 'OP'))?['value']?.toString().trim() ?? '';
  final baseMode = _products[vm['produktGattung']] ?? _products[pt['produktGattung']] ?? Mode.other;
  final mode = refineMode(_regionalExpressFix(baseMode, name), name, operator);

  final cancelledDep = stops.isNotEmpty && _stopCancelled(stops.first);
  final cancelledArr = stops.isNotEmpty && _stopCancelled(stops.last);

  final stopovers = stops.map((s) {
    final p = _stopPlace(s);
    return Stopover(
      name: p.name,
      lat: p.lat,
      lon: p.lon,
      arr: _t(s['ezAnkunftsDatum']) ?? _t(s['ankunftsDatum']),
      dep: _t(s['ezAbgangsDatum']) ?? _t(s['abgangsDatum']),
      cancelled: _stopCancelled(s),
    );
  }).toList();
  final path = stopovers.where((s) => s.lat != null).map((s) => [s.lat!, s.lon!]).toList();

  int? delay(DateTime? rt, DateTime planned) => rt?.difference(planned).inMinutes;

  return Leg(
    mode: mode,
    line: name,
    operator: operator,
    direction: (vm['richtung'] ?? pt['richtung'] ?? '').toString(),
    from: from,
    to: to,
    dep: dep,
    arr: arr,
    plannedDep: plannedDep,
    plannedArr: plannedArr,
    depDelay: delay(_t(rtDepS), plannedDep),
    arrDelay: delay(_t(rtArrS), plannedArr),
    depPlatform: stops.isNotEmpty ? (stops.first['ezGleis'] ?? stops.first['gleis'])?.toString() : null,
    arrPlatform: stops.isNotEmpty ? (stops.last['ezGleis'] ?? stops.last['gleis'])?.toString() : null,
    cancelled: cancelledDep || cancelledArr || pt['cancelled'] == true || pt['canceled'] == true,
    stops: stopovers.length > 2 ? stopovers.sublist(1, stopovers.length - 1) : const [],
    path: path.length >= 2 ? path : straight(),
    remarks: _remarks(pt),
  );
}

/// In DB's data the "IR" product class holds FlixTrain and other open-access trains, but also plain REs.
Mode _regionalExpressFix(Mode m, String name) {
  if (RegExp(r'^(RE|RB|IRE|MEX|RS)\b').hasMatch(name)) return Mode.regional;
  return m;
}

List<Journey> parseDbJourneys(Map<String, dynamic> res, {String? bookingUrl}) {
  var list = (res['verbindungen'] as List?) ?? const [];
  final intervals = (res['intervalle'] ?? res['tagesbestPreisIntervalle']) as List?;
  if (intervals != null) {
    list = intervals
        .whereType<Map>()
        .expand((i) => ((i['verbindungen'] as List?) ?? []).whereType<Map<String, dynamic>>())
        .map((v) => {...v, ...?(v['verbindung'] as Map<String, dynamic>?)})
        .toList();
  }
  final out = <Journey>[];
  for (final jj in list.whereType<Map<String, dynamic>>()) {
    final j = (jj['verbindung'] as Map<String, dynamic>?) ?? jj;
    final raw = ((j['verbindungsAbschnitte'] as List?) ?? []).whereType<Map<String, dynamic>>().toList();
    final legs = <Leg>[];
    for (var i = 0; i < raw.length; i++) {
      final l = _dbLeg(raw[i], fixWalkTz: i == 0 || i == raw.length - 1);
      if (l != null) legs.add(l);
    }
    if (legs.isEmpty) continue;
    final transit = legs.where((l) => !l.isWalk).toList();
    if (transit.isEmpty) continue;

    final p = (jj['angebotsPreis'] ?? ((jj['angebote'] as Map?)?['preise'] as Map?)?['gesamt']?['ab'] ?? jj['abPreis']) as Map?;
    final partial = (jj['hasTeilpreis'] ?? ((jj['angebote'] as Map?)?['preise'] as Map?)?['istTeilpreis'] ?? jj['teilpreis']) == true;
    final prices = <Price>[
      if (p?['betrag'] is num)
        Price(
          amount: (p!['betrag'] as num).toDouble(),
          currency: (p['waehrung'] ?? 'EUR').toString(),
          source: 'db',
          partial: partial,
          url: bookingUrl,
        ),
    ];
    out.add(
      Journey(
        source: 'db',
        legs: legs,
        prices: prices,
        dticket: transit.every((l) => dticketModes.contains(l.mode)),
        bookingUrls: {'db': ?bookingUrl},
      ),
    );
  }
  return out;
}
