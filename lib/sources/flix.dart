// FlixTrain (and optionally FlixBus) with live prices and seats, via the JSON API behind
// flixbus.de / flixtrain.de. Unofficial: it can change without notice.
import '../core/net.dart';
import '../core/util.dart';
import '../models/journey.dart';
import 'source.dart';

const _base = 'https://global.api.flixbus.com';

typedef FlixCity = ({String id, String name, double? lat, double? lon});

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

  Future<FlixCity> _city(Place place) async {
    final q = flixCityQuery(place.name);
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
          return (
            id: (c['id'] ?? c['uuid'] ?? '').toString(),
            name: (c['name'] ?? '').toString(),
            lat: ((l?['lat'] ?? l?['latitude']) as num?)?.toDouble(),
            lon: ((l?['lon'] ?? l?['longitude']) as num?)?.toDouble(),
          );
        })
        .where((c) => c.id.isNotEmpty)
        .toList();
    if (list.isEmpty) throw SourceException('Flix has no city matching "$q"');
    if (place.hasCoords) {
      list.sort((a, b) => distKm(place.lat, place.lon, a.lat, a.lon).compareTo(distKm(place.lat, place.lon, b.lat, b.lon)));
      if (list.first.lat != null && distKm(place.lat, place.lon, list.first.lat, list.first.lon) > 40) {
        throw SourceException('no Flix stop near ${place.name}');
      }
    }
    return list.first;
  }

  @override
  Future<List<Journey>> journeys(Place from, Place to, SearchOptions opts) async {
    if (opts.dticketOnly) return []; // Flix never accepts the Deutschlandticket
    final cities = await Future.wait([_city(from), _city(to)]);
    final params = {
      'from_city_id': cities[0].id,
      'to_city_id': cities[1].id,
      'departure_date': _ddmmyyyy(opts.when),
      'products': '{"adult":1}',
      'currency': 'EUR',
      'locale': 'de',
      'search_by': 'cities',
      'include_after_midnight_rides': '1',
    };
    Future<List<Journey>> day(DateTime d) async {
      final p = {...params, 'departure_date': _ddmmyyyy(d)};
      final data = await cache.get('flix:${Uri(queryParameters: p).query}', const Duration(minutes: 2), () {
        return Net.instance.getJson(
          Uri.parse('$_base/search/service/v4/search').replace(queryParameters: p),
          timeout: const Duration(seconds: 12),
        );
      });
      return parseFlixSearch(data as Map<String, dynamic>, cities[0], cities[1], opts);
    }

    final t = opts.when;
    final all = await day(t);
    // Flix searches whole days: late in the evening, also look at tomorrow (or yesterday for arrive-by).
    final enough = opts.arriveBy
        ? all.where((j) => !j.arrival.isAfter(t)).length >= opts.results
        : all.where((j) => !j.departure.isBefore(t)).length >= opts.results;
    if (!enough) {
      try {
        all.addAll(await day(t.add(Duration(days: opts.arriveBy ? -1 : 1))));
      } on SourceException {
        /* the first day's results are still useful */
      }
    }
    all.sort((a, b) => a.departure.compareTo(b.departure));
    if (opts.arriveBy) {
      final before = all.where((j) => !j.arrival.isAfter(t)).toList();
      return before.sublist((before.length - opts.results).clamp(0, before.length));
    }
    return all.where((j) => !j.departure.isBefore(t.subtract(const Duration(minutes: 15)))).take(opts.results).toList();
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
