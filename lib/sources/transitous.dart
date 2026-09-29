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

const _regional = 'REGIONAL_FAST_RAIL,REGIONAL_RAIL,RAIL,SUBURBAN,SUBWAY,METRO,TRAM,BUS,FERRY,CABLE_CAR,FUNICULAR,ODM';

/// Walking the whole way is only offered up to this long.
const _maxWalkOnlyMinutes = 120; // the user's limit is applied when showing results

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

  /// Street addresses and places (sights, parks, …) – no stations.
  Future<List<Place>> addresses(String q) async {
    final res = await cache.get('tr:addr:$q', const Duration(hours: 1), () {
      return Net.instance.getJson(
        Uri.parse('$_base/api/v1/geocode').replace(queryParameters: {'text': q, 'language': 'de'}),
        timeout: const Duration(seconds: 6),
        retries: 1,
      );
    });
    return parseTransitousLocations(res).where((p) => !p.isStop).toList();
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
      if (opts.regionalOnly) 'transitModes': _regional else if (!opts.coach) 'transitModes': _noCoach,
      // Walking: how far to walk to/from stations, and whether walking the whole way is an option.
      'maxPreTransitTime': '${opts.maxWalkMinutes * 60}',
      'maxPostTransitTime': '${opts.maxWalkMinutes * 60}',
      if (opts.includeWalking) ...{'directModes': 'WALK', 'maxDirectTime': '${_maxWalkOnlyMinutes * 60}'},
      // A 3 h window returns more (and more varied) connections than the default 2 h.
      if (opts.moreAlternatives) 'searchWindow': '${3 * 3600}',
    };
    final data = await _plan(params);
    return parseTransitousPlan(data, opts, fromName: from.name, toName: to.name);
  }
}

/// Transitous transit modes for one of our modes (to look up a single train's track).
String _modesFor(Mode m) => switch (m) {
  Mode.long => 'HIGHSPEED_RAIL,LONG_DISTANCE,REGIONAL_FAST_RAIL',
  Mode.night => 'NIGHT_RAIL,LONG_DISTANCE,HIGHSPEED_RAIL',
  Mode.regional => 'REGIONAL_FAST_RAIL,REGIONAL_RAIL,RAIL,LONG_DISTANCE',
  Mode.suburban => 'SUBURBAN,REGIONAL_RAIL,RAIL',
  Mode.metro => 'SUBWAY,METRO',
  Mode.tram => 'TRAM',
  Mode.bus => 'BUS',
  Mode.coach => 'COACH',
  Mode.ferry => 'FERRY',
  _ => 'TRANSIT',
};

/// The real track of one leg: asks Transitous for the same train (same departure time, same number)
/// between the same two stops and returns its geometry. Null if it can't be matched.
Future<List<List<double>>?> trackForLeg(Leg l) {
  if (l.isWalk || !l.from.hasCoords || !l.to.hasCoords) return Future.value(null);
  final key = 'track:${l.from.lat},${l.from.lon}>${l.to.lat},${l.to.lon}@${l.plannedDep.toUtc().toIso8601String()}';
  return cache.get(key, const Duration(hours: 12), () async {
    final params = {
      'fromPlace': '${l.from.lat},${l.from.lon}',
      'toPlace': '${l.to.lat},${l.to.lon}',
      'time': '${l.plannedDep.subtract(const Duration(minutes: 3)).toUtc().toIso8601String().substring(0, 19)}Z',
      'numItineraries': '3',
      'maxTransfers': '0',
      'transitModes': _modesFor(l.mode),
      'maxPreTransitTime': '600',
      'maxPostTransitTime': '600',
      'joinInterlinedLegs': 'true',
    };
    try {
      final data = await Net.instance.getJson(
        Uri.parse('$_base/api/v6/plan').replace(queryParameters: params),
        timeout: const Duration(seconds: 12),
        retries: 0,
      );
      final number = RegExp(r'\d{2,}').firstMatch(l.line)?.group(0);
      List<List<double>>? best;
      for (final it in ((data['itineraries'] as List?) ?? []).whereType<Map<String, dynamic>>()) {
        for (final raw in ((it['legs'] as List?) ?? []).whereType<Map<String, dynamic>>()) {
          if (raw['mode'] == 'WALK') continue;
          final start = DateTime.tryParse((raw['scheduledStartTime'] ?? raw['startTime'] ?? '') as String);
          if (start == null || start.difference(l.plannedDep).inMinutes.abs() > 3) continue;
          final name = '${raw['displayName'] ?? ''} ${raw['tripShortName'] ?? ''} ${raw['routeShortName'] ?? ''}';
          final geo = _geometry(raw);
          if (geo == null || geo.length < 3) continue;
          if (number != null && name.contains(number)) return geo; // same train number: certain
          best ??= geo;
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  });
}

/// The real walking route between the two ends of a walking leg (footpaths instead of a straight line).
Future<List<List<double>>?> walkForLeg(Leg l) {
  if (!l.isWalk || !l.from.hasCoords || !l.to.hasCoords) return Future.value(null);
  final key = 'walk:${l.from.lat},${l.from.lon}>${l.to.lat},${l.to.lon}';
  return cache.get(key, const Duration(days: 1), () async {
    try {
      final data = await Net.instance.getJson(
        Uri.parse('$_base/api/v6/plan').replace(
          queryParameters: {
            'fromPlace': '${l.from.lat},${l.from.lon}',
            'toPlace': '${l.to.lat},${l.to.lon}',
            'time': '${l.dep.toUtc().toIso8601String().substring(0, 19)}Z',
            'directModes': 'WALK',
            'transitModes': 'WALK', // no public transport: only the direct walk
            'maxDirectTime': '7200',
          },
        ),
        timeout: const Duration(seconds: 10),
        retries: 0,
      );
      for (final it in ((data['direct'] as List?) ?? []).whereType<Map<String, dynamic>>()) {
        final pts = <List<double>>[];
        for (final raw in ((it['legs'] as List?) ?? []).whereType<Map<String, dynamic>>()) {
          pts.addAll(_geometry(raw) ?? const []);
        }
        if (pts.length >= 2) return pts;
      }
    } catch (_) {}
    return null;
  });
}

List<Place> parseTransitousLocations(dynamic res) {
  if (res is! List) return [];
  return res
      .whereType<Map<String, dynamic>>()
      .take(8)
      .map((m) {
        final areas = (m['areas'] as List?)?.whereType<Map<String, dynamic>>() ?? const [];
        final area = firstOrNull(areas.where((a) => a['default'] == true))?['name'] as String? ?? '';
        final kind = switch (m['type']) {
          'ADDRESS' => PlaceKind.address,
          'PLACE' => PlaceKind.place,
          _ => PlaceKind.stop,
        };
        var name = m['name'] as String? ?? '';
        // "Friedrich-Ebert-Straße 79" alone is ambiguous: add the town.
        if (kind != PlaceKind.stop && area.isNotEmpty && !name.contains(area)) name = '$name, $area';
        final id = m['id'] as String?;
        return Place(
          name: name,
          lat: (m['lat'] as num?)?.toDouble(),
          lon: (m['lon'] as num?)?.toDouble(),
          transitousId: (id?.isEmpty ?? true) ? null : id,
          area: [if (m['zip'] != null) m['zip'], area].where((x) => '$x'.isNotEmpty).join(' '),
          kind: kind,
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

/// Names for MOTIS' placeholders when routing from/to coordinates ("START"/"END").
String? _startName, _endName;

Place _place(Map<String, dynamic> p) {
  var name = p['name'] as String? ?? '';
  if (name == 'START' && _startName != null) name = _startName!;
  if (name == 'END' && _endName != null) name = _endName!;
  return Place(name: name, lat: (p['lat'] as num?)?.toDouble(), lon: (p['lon'] as num?)?.toDouble());
}

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

List<Journey> parseTransitousPlan(Map<String, dynamic> data, SearchOptions opts, {String? fromName, String? toName}) {
  _startName = fromName;
  _endName = toName;
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
  // "direct" = walking the whole way (only requested with directModes=WALK).
  for (final it in ((data['direct'] as List?) ?? []).whereType<Map<String, dynamic>>()) {
    final legs = ((it['legs'] as List?) ?? []).whereType<Map<String, dynamic>>().map(_leg).whereType<Leg>().toList();
    if (legs.isEmpty || legs.any((l) => !l.isWalk)) continue;
    out.add(Journey(source: 'transitous', legs: legs, dticket: true));
  }
  return out;
}
