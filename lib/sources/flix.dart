// FlixTrain (and optionally FlixBus) with live prices and seats, via the JSON API behind
// flixbus.de / flixtrain.de. Unofficial: it can change without notice.
import '../core/net.dart';
import '../core/util.dart';
import '../models/journey.dart';
import 'source.dart';

const _base = 'https://global.api.flixbus.com';

typedef FlixCity = ({String id, String name, double? lat, double? lon, bool hasTrain});

/// Flix works with cities, not stations: "Berlin Hbf" -> "Berlin".
String flixCityQuery(String name) {
  final s = name
      .replaceAll(RegExp(r'\(.*?\)'), ' ')
      .split(RegExp(r'[,/]'))
      .first
      .replaceAll(
        RegExp(
          r'\b(Hbf|Hauptbahnhof|Bahnhof|Bf|Süd|Nord|Ost|West|Mitte|Flughafen|Airport|ZOB|Fernbusbahnhof|tief)\b\.?',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'^(S\+U|S|U)\s+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return s.isEmpty ? name : s;
}

String _ddmmyyyy(DateTime d) {
  final w = cetWallClock(d);
  return '${two(w.day)}.${two(w.month)}.${w.year}';
}

class FlixSource implements Source {
  @override
  String get id => 'flix';
  @override
  String get label => 'Flix';
  @override
  bool get corsFriendly => true;

  /// All Flix cities matching a name, closest to [lat]/[lon] first.
  Future<List<FlixCity>> cities(String name, {double? lat, double? lon}) async {
    final q = flixCityQuery(name);
    final res = await cache.get('flix:city:$q', const Duration(hours: 24), () {
      return Net.instance.getJson(
        Uri.parse('$_base/search/autocomplete/cities')
            .replace(queryParameters: {'q': q, 'lang': 'de', 'country': 'de', 'flixbus_cities_only': 'false', 'stations': 'true'}),
        timeout: const Duration(seconds: 6),
      );
    });
    final raw = res is List ? res : ((res as Map?)?['cities'] as List? ?? const []);
    final list = raw
        .whereType<Map<String, dynamic>>()
        .map<FlixCity>((c) {
          final l = (c['location'] ?? c['coordinates']) as Map?;
          final stations = (c['stations'] as List?)?.whereType<Map>() ?? const [];
          return (
            id: (c['id'] ?? c['uuid'] ?? '').toString(),
            name: (c['name'] ?? '').toString(),
            lat: ((l?['lat'] ?? l?['latitude']) as num?)?.toDouble(),
            lon: ((l?['lon'] ?? l?['longitude']) as num?)?.toDouble(),
            hasTrain: c['has_train_station'] == true || stations.any((st) => st['is_train'] == true),
          );
        })
        .where((c) => c.id.isNotEmpty)
        .toList();
    if (lat != null && lon != null) {
      list.sort((a, b) => distKm(lat, lon, a.lat, a.lon).compareTo(distKm(lat, lon, b.lat, b.lon)));
    }
    return list;
  }

  /// The Flix city serving [place], or null if Flix has no stop within [maxKm].
  Future<FlixCity?> cityFor(Place place, {double maxKm = 40, bool trainOnly = false}) async {
    final list = (await cities(place.name, lat: place.lat, lon: place.lon)).where((c) => !trainOnly || c.hasTrain).toList();
    if (list.isEmpty) return null;
    final c = list.first;
    if (place.hasCoords && c.lat != null && distKm(place.lat, place.lon, c.lat, c.lon) > maxKm) return null;
    return c;
  }

  /// All Flix rides between two cities on the calendar day of [day] (Europe/Berlin).
  Future<List<Journey>> ridesOnDay(FlixCity from, FlixCity to, DateTime day, SearchOptions opts) async {
    final p = {
      'from_city_id': from.id,
      'to_city_id': to.id,
      'departure_date': _ddmmyyyy(day),
      'products': '{"adult":1}',
      'currency': 'EUR',
      'locale': 'de',
      'search_by': 'cities',
      'include_after_midnight_rides': '1',
    };
    final data = await cache.get('flix:${Uri(queryParameters: p).query}', const Duration(minutes: 3), () {
      return Net.instance.getJson(
        Uri.parse('$_base/search/service/v4/search').replace(queryParameters: p),
        timeout: const Duration(seconds: 12),
      );
    });
    return parseFlixSearch(data as Map<String, dynamic>, from, to, opts);
  }

  /// Rides around [opts.when]; late in the day this also looks at the next (or, arriving, previous) day.
  Future<List<Journey>> ridesAround(FlixCity from, FlixCity to, SearchOptions opts, {int? limit}) async {
    final t = opts.when;
    final n = limit ?? opts.results;
    final all = await ridesOnDay(from, to, t, opts);
    final enough = opts.arriveBy
        ? all.where((j) => !j.arrival.isAfter(t)).length >= n
        : all.where((j) => !j.departure.isBefore(t)).length >= n;
    if (!enough) {
      try {
        all.addAll(await ridesOnDay(from, to, t.add(Duration(days: opts.arriveBy ? -1 : 1)), opts));
      } on SourceException {
        /* the first day's results are still useful */
      }
    }
    all.sort((a, b) => a.departure.compareTo(b.departure));
    if (opts.arriveBy) {
      final before = all.where((j) => !j.arrival.isAfter(t)).toList();
      return before.sublist((before.length - n).clamp(0, before.length));
    }
    return all.where((j) => !j.departure.isBefore(t.subtract(const Duration(minutes: 15)))).take(n).toList();
  }

  @override
  Future<List<Journey>> journeys(Place from, Place to, SearchOptions opts) async {
    if (opts.dticketOnly) return []; // Flix never accepts the Deutschlandticket
    final cities = await Future.wait([cityFor(from, trainOnly: !opts.coach), cityFor(to, trainOnly: !opts.coach)]);
    // No Flix stop at one end is not an error: the Flix+feeder search (services/flix_combos.dart) covers that.
    if (cities[0] == null || cities[1] == null || cities[0]!.id == cities[1]!.id) return [];
    return ridesAround(cities[0]!, cities[1]!, opts);
  }
}

List<Journey> parseFlixSearch(Map<String, dynamic> data, FlixCity fromCity, FlixCity toCity, SearchOptions opts) {
  final stations = (data['stations'] as Map<String, dynamic>?) ?? const {};
  final cities = (data['cities'] as Map<String, dynamic>?) ?? const {};

  Place station(Map<String, dynamic>? stop) {
    final s = stations[stop?['station_id']] as Map<String, dynamic>?;
    final c = (s?['coordinates'] ?? s?['location']) as Map?;
    // Flix omits station coordinates; fall back to the city centre for the map.
    final cityId = stop?['city_id'];
    final city = cityId == fromCity.id ? fromCity : (cityId == toCity.id ? toCity : null);
    return Place(
      name: (s?['name'] ?? (cities[cityId] as Map?)?['name'] ?? '').toString(),
      lat: ((c?['latitude'] ?? c?['lat']) as num?)?.toDouble() ?? city?.lat,
      lon: ((c?['longitude'] ?? c?['lon']) as num?)?.toDouble() ?? city?.lon,
    );
  }

  final url = Uri.parse('https://shop.flixbus.de/search')
      .replace(
        queryParameters: {
          'departureCity': fromCity.id,
          'arrivalCity': toCity.id,
          'rideDate': _ddmmyyyy(opts.when),
          'adult': '1',
          '_locale': 'de',
        },
      )
      .toString();

  final out = <Journey>[];
  for (final trip in ((data['trips'] as List?) ?? []).whereType<Map<String, dynamic>>()) {
    final rawResults = trip['results'];
    final results = rawResults is Map ? rawResults.values : (rawResults as List? ?? const []);
    for (final r in results.whereType<Map<String, dynamic>>()) {
      final rawLegs = ((r['legs'] as List?)?.isNotEmpty ?? false)
          ? (r['legs'] as List).whereType<Map<String, dynamic>>()
          : [
              {'departure': r['departure'], 'arrival': r['arrival'], 'means_of_transport': r['means_of_transport']},
            ];
      final legs = <Leg>[];
      for (final l in rawLegs) {
        final dep = DateTime.tryParse(((l['departure'] as Map?)?['date'] ?? '').toString());
        final arr = DateTime.tryParse(((l['arrival'] as Map?)?['date'] ?? '').toString());
        if (dep == null || arr == null) continue;
        final isTrain = RegExp('train', caseSensitive: false).hasMatch((l['means_of_transport'] ?? '').toString());
        final from = station(l['departure'] as Map<String, dynamic>?), to = station(l['arrival'] as Map<String, dynamic>?);
        legs.add(
          Leg(
            mode: isTrain ? Mode.long : Mode.coach,
            line: isTrain ? 'FLX' : 'FlixBus',
            operator: isTrain ? 'FlixTrain' : 'FlixBus',
            from: from,
            to: to,
            dep: dep,
            arr: arr,
            path: from.hasCoords && to.hasCoords
                ? [
                    [from.lat!, from.lon!],
                    [to.lat!, to.lon!],
                  ]
                : [],
          ),
        );
      }
      if (legs.isEmpty) continue;
      if (!opts.coach && legs.any((l) => l.mode == Mode.coach)) continue;
      final price = r['price'] as Map?;
      final total = (price?['total_with_platform_fee'] ?? price?['total'] ?? price?['average']) as num?;
      final seats = (r['available'] as Map?)?['seats'] as int?;
      out.add(
        Journey(
          source: 'flix',
          legs: legs,
          prices: [if (total != null) Price(amount: (total * 100).round() / 100, source: 'flix', url: url, seats: seats)],
          dticket: false,
          soldOut: r['status'] != null && r['status'] != 'available',
          bookingUrls: {'flix': url},
        ),
      );
    }
  }
  return out;
}
