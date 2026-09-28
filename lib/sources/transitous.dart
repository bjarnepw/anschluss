// Transitous (https://transitous.org) – free, community-run MOTIS router on open GTFS data:
// all German public transport (DELFI), FlixTrain GTFS and many European operators.
// Exact route geometry for the map, no prices. Usage policy: https://transitous.org/api/
import '../core/net.dart';
import '../core/util.dart';
import '../models/journey.dart';
import 'source.dart';

const _base = 'https://api.transitous.org';

const _modes = {
  'HIGHSPEED_RAIL': Mode.long,
  'LONG_DISTANCE': Mode.long,
  'NIGHT_RAIL': Mode.night,
  'REGIONAL_FAST_RAIL': Mode.regional,
  'REGIONAL_RAIL': Mode.regional,
  'RAIL': Mode.regional,
  'SUBURBAN': Mode.suburban,
  'METRO': Mode.metro,
  'SUBWAY': Mode.metro,
  'TRAM': Mode.tram,
  'CABLE_CAR': Mode.tram,
  'BUS': Mode.bus,
  'COACH': Mode.coach,
  'FERRY': Mode.ferry,
  'WALK': Mode.walk,
};

const _noCoach =
    'HIGHSPEED_RAIL,LONG_DISTANCE,NIGHT_RAIL,REGIONAL_FAST_RAIL,REGIONAL_RAIL,RAIL,SUBURBAN,SUBWAY,METRO,'
    'TRAM,BUS,FERRY,CABLE_CAR,FUNICULAR,AERIAL_LIFT,ODM,OTHER';

class TransitousSource implements Source, LocationSource {
  @override
  String get id => 'transitous';
  @override
  String get label => 'Transitous';
  @override
  bool get corsFriendly => true;

  // MOTIS bumps the plan API version now and then; remember the newest one the server speaks.
  int? _planVersion;

  Future<Map<String, dynamic>> _plan(Map<String, String> params) async {
    final versions = _planVersion != null ? [_planVersion!] : [6, 5, 4, 3];
    SourceException? last;
    for (final v in versions) {
      try {
        final data = await Net.instance.getJson(
          Uri.parse('$_base/api/v$v/plan').replace(queryParameters: params),
          timeout: const Duration(seconds: 15),
        );
        _planVersion = v;
        return data as Map<String, dynamic>;
      } on SourceException catch (e) {
        last = e;
        if (e.status != 404 && e.status != 400) rethrow;
      }
    }
    throw last!;
  }

  @override
  Future<List<Place>> locations(String q) async {
    final res = await cache.get('tr:geo:$q', const Duration(hours: 1), () {
      return Net.instance.getJson(
        Uri.parse('$_base/api/v1/geocode').replace(queryParameters: {'text': q, 'type': 'STOP', 'language': 'de'}),
        timeout: const Duration(seconds: 6),
        retries: 1,
      );
    });
    return parseTransitousLocations(res);
  }

  /// Stops near a coordinate, closest first ("use my location").
  Future<List<Place>> nearby(double lat, double lon) async {
    final res = await Net.instance.getJson(
      Uri.parse('$_base/api/v1/reverse-geocode').replace(queryParameters: {'place': '$lat,$lon', 'type': 'STOP'}),
      timeout: const Duration(seconds: 8),
    );
    final list = parseTransitousLocations(res);
    list.sort((a, b) => distKm(lat, lon, a.lat, a.lon).compareTo(distKm(lat, lon, b.lat, b.lon)));
    return list;
  }

  @override
  Future<List<Journey>> journeys(Place from, Place to, SearchOptions opts) async {
    String? place(Place p) => p.hasCoords ? '${p.lat},${p.lon}' : p.transitousId;
    final f = place(from), t = place(to);
    if (f == null || t == null) throw SourceException('needs a station picked from the suggestions');
    final params = {
      'fromPlace': f,
      'toPlace': t,
      // Whole seconds only: MOTIS silently ignores times with fractional seconds and plans for another day.
      'time': '${opts.when.toUtc().toIso8601String().substring(0, 19)}Z',
      'arriveBy': opts.arriveBy ? 'true' : 'false',
      'numItineraries': '${opts.results}',
      'joinInterlinedLegs': 'true',
      'detailedTransfers': 'false',
      if (opts.minTransferMinutes > 0) 'minTransferTime': '${opts.minTransferMinutes}',
      if (opts.maxTransfers != null) 'maxTransfers': '${opts.maxTransfers}',
      if (opts.bike) 'requireBikeTransport': 'true',
      // Ask for trains-only routing instead of filtering afterwards – otherwise night searches come back
      // as FlixBus-only and end up empty.
      if (!opts.coach) 'transitModes': _noCoach,
    };
    final data = await _plan(params);
    return parseTransitousPlan(data, opts);
  }
}

List<Place> parseTransitousLocations(dynamic res) {
  if (res is! List) return [];
  return res
      .whereType<Map<String, dynamic>>()
      .take(8)
      .map((m) {
        final areas = (m['areas'] as List?)?.whereType<Map<String, dynamic>>() ?? const [];
        return Place(
          name: m['name'] as String? ?? '',
          lat: (m['lat'] as num?)?.toDouble(),
          lon: (m['lon'] as num?)?.toDouble(),
          transitousId: m['id'] as String?,
          area: firstOrNull(areas.where((a) => a['default'] == true))?['name'] as String? ?? '',
        );
      })
      .where((p) => p.name.isNotEmpty)
      .toList();
}

List<List<double>>? _geometry(Map<String, dynamic> leg) {
  final g = leg['legGeometry'] as Map<String, dynamic>?;
  final points = g?['points'] as String?;
  if (points == null || points.isEmpty) return null;
  final from = leg['from'] as Map<String, dynamic>;
  final wantLat = (from['lat'] as num?)?.toDouble(), wantLon = (from['lon'] as num?)?.toDouble();
  final candidates = [if (g!['precision'] is int) g['precision'] as int, 7, 6, 5];
  for (final p in candidates) {
    try {
      final pts = decodePolyline(points, p);
      if (pts.isNotEmpty && distKm(wantLat, wantLon, pts[0][0], pts[0][1]) < 5) return pts;
    } catch (_) {
      /* try next precision */
    }
  }
  return null;
}

Place _place(Map<String, dynamic> p) =>
    Place(name: p['name'] as String? ?? '', lat: (p['lat'] as num?)?.toDouble(), lon: (p['lon'] as num?)?.toDouble());

Leg? _leg(Map<String, dynamic> l) {
  final dep = DateTime.tryParse(l['startTime'] as String? ?? '');
  final arr = DateTime.tryParse(l['endTime'] as String? ?? '');
  if (dep == null || arr == null) return null;
  final base = _modes[l['mode']] ?? Mode.other;
  final name = (l['displayName'] ?? l['tripShortName'] ?? l['routeShortName'] ?? '') as String;
  final agency = l['agencyName'] as String? ?? '';
  final mode = base == Mode.walk ? Mode.walk : refineMode(base, name, agency);
  final from = _place(l['from'] as Map<String, dynamic>), to = _place(l['to'] as Map<String, dynamic>);
  final exact = _geometry(l);
  final plannedDep = DateTime.tryParse(l['scheduledStartTime'] as String? ?? '') ?? dep;
  final plannedArr = DateTime.tryParse(l['scheduledEndTime'] as String? ?? '') ?? arr;
  final rt = l['realTime'] == true;
  final lf = l['from'] as Map<String, dynamic>, lt = l['to'] as Map<String, dynamic>;
  return Leg(
    mode: mode,
    line: mode == Mode.walk ? 'Walk' : name,
    operator: agency,
    direction: l['headsign'] as String? ?? '',
    from: from,
    to: to,
    dep: dep,
    arr: arr,
    plannedDep: plannedDep,
    plannedArr: plannedArr,
    depDelay: rt ? dep.difference(plannedDep).inMinutes : null,
    arrDelay: rt ? arr.difference(plannedArr).inMinutes : null,
    depPlatform: (lf['track'] ?? lf['scheduledTrack']) as String?,
    arrPlatform: (lt['track'] ?? lt['scheduledTrack']) as String?,
    cancelled: l['cancelled'] == true,
    stops: ((l['intermediateStops'] as List?) ?? [])
        .whereType<Map<String, dynamic>>()
        .map(
          (s) => Stopover(
            name: s['name'] as String? ?? '',
            lat: (s['lat'] as num?)?.toDouble(),
            lon: (s['lon'] as num?)?.toDouble(),
            arr: DateTime.tryParse(s['arrival'] as String? ?? ''),
            dep: DateTime.tryParse(s['departure'] as String? ?? ''),
            cancelled: s['cancelled'] == true,
          ),
        )
        .toList(),
    path:
        exact ??
        (from.hasCoords && to.hasCoords
            ? [
                [from.lat!, from.lon!],
                [to.lat!, to.lon!],
              ]
            : []),
    pathExact: exact != null,
    walkDistance: mode == Mode.walk ? (l['distance'] as num?)?.toDouble() : null,
  );
}

List<Journey> parseTransitousPlan(Map<String, dynamic> data, SearchOptions opts) {
  final out = <Journey>[];
  for (final it in ((data['itineraries'] as List?) ?? []).whereType<Map<String, dynamic>>()) {
    final legs = ((it['legs'] as List?) ?? []).whereType<Map<String, dynamic>>().map(_leg).whereType<Leg>().toList();
    if (legs.isEmpty) continue;
    // A trains app: drop long-distance coaches unless wanted.
    if (!opts.coach && legs.any((l) => l.mode == Mode.coach)) continue;
    final transit = legs.where((l) => !l.isWalk).toList();
    if (transit.isEmpty) continue;
    final dt = transit.every((l) => dticketModes.contains(l.mode));
    if (opts.dticketOnly && !dt) continue;
    out.add(Journey(source: 'transitous', legs: legs, dticket: dt));
  }
  return out;
}
