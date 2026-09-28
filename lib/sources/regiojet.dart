// RegioJet (Czech open-access operator): trains Prague–Vienna/Bratislava/Ostrava/…, and buses across Europe.
// Public JSON API behind regiojet.com. Fares are requested in the operator's home currency (CZK) and
// converted to euros with the ECB rate, so the original tariff stays visible.
import '../core/currency.dart';
import '../core/net.dart';
import '../core/util.dart';
import '../models/journey.dart';
import 'flix.dart' show flixCityQuery;
import 'source.dart';

const _base = 'https://brn-ybus-pubapi.sa.cz/restapi';

typedef _City = ({int id, String name, List<String> aliases, Map<int, String> stations});

class RegioJetSource implements Source {
  @override
  String get id => 'regiojet';
  @override
  String get label => 'RegioJet';
  @override
  bool get corsFriendly => false;

  Future<List<_City>> _cities() => cache.get('rj:cities', const Duration(hours: 24), () async {
    final res = await Net.instance.getJson(
      Uri.parse('$_base/consts/locations'),
      headers: {'X-Lang': 'de'},
      timeout: const Duration(seconds: 10),
      needsProxy: true,
    );
    final out = <_City>[];
    for (final country in (res as List).whereType<Map<String, dynamic>>()) {
      for (final c in ((country['cities'] as List?) ?? []).whereType<Map<String, dynamic>>()) {
        out.add((
          id: (c['id'] as num).toInt(),
          name: (c['name'] ?? '').toString(),
          aliases: [(c['name'] ?? '').toString(), ...((c['aliases'] as List?) ?? []).map((a) => a.toString())],
          stations: {
            for (final s in ((c['stations'] as List?) ?? []).whereType<Map<String, dynamic>>())
              (s['id'] as num).toInt(): (s['fullname'] ?? s['name'] ?? '').toString(),
          },
        ));
      }
    }
    return out;
  });

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[áà]'), 'a')
      .replaceAll(RegExp(r'[éě]'), 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll(RegExp(r'[úů]'), 'u')
      .replaceAll('ý', 'y')
      .replaceAll('č', 'c')
      .replaceAll('ř', 'r')
      .replaceAll('š', 's')
      .replaceAll('ž', 'z')
      .replaceAll(RegExp(r'\s+(hl\.?\s*n\.?|hlavni nadrazi)$'), '')
      .trim();

  Future<_City?> _city(Place p) async {
    final q = _norm(flixCityQuery(p.name));
    for (final c in await _cities()) {
      if (c.aliases.any((a) => _norm(a) == q)) return c;
    }
    return null;
  }

  @override
  Future<List<Journey>> journeys(Place from, Place to, SearchOptions opts) async {
    if (opts.dticketOnly) return [];
    final cities = await Future.wait([_city(from), _city(to)]);
    final a = cities[0], b = cities[1];
    if (a == null || b == null || a.id == b.id) return []; // RegioJet doesn't serve this pair
    final w = cetWallClock(opts.when);
    final res = await Net.instance.getJson(
      Uri.parse('$_base/routes/search/simple').replace(
        queryParameters: {
          'tariffs': 'REGULAR',
          'fromLocationType': 'CITY',
          'fromLocationId': '${a.id}',
          'toLocationType': 'CITY',
          'toLocationId': '${b.id}',
          'departureDate': '${w.year}-${two(w.month)}-${two(w.day)}',
        },
      ),
      headers: {'X-Lang': 'de', 'X-Currency': 'CZK'},
      timeout: const Duration(seconds: 12),
      needsProxy: true,
    );
    final url = Uri.parse('https://regiojet.com/')
        .replace(
          queryParameters: {
            'departureDate': '${w.year}-${two(w.month)}-${two(w.day)}',
            'fromLocationId': '${a.id}',
            'fromLocationType': 'CITY',
            'toLocationId': '${b.id}',
            'toLocationType': 'CITY',
            'tariffs': 'REGULAR',
          },
        )
        .toString();
    final all = await parseRegioJet(res as Map<String, dynamic>, from, to, {...a.stations, ...b.stations}, opts, url);
    // The API answers for several days; keep the ones around the requested time.
    all.sort((x, y) => x.departure.compareTo(y.departure));
    if (opts.arriveBy) {
      final ok = all.where((j) => !j.arrival.isAfter(opts.when)).toList();
      return ok.sublist((ok.length - opts.results).clamp(0, ok.length));
    }
    return all.where((j) => !j.departure.isBefore(opts.when.subtract(const Duration(minutes: 15)))).take(opts.results).toList();
  }
}

Future<List<Journey>> parseRegioJet(
  Map<String, dynamic> res,
  Place from,
  Place to,
  Map<int, String> stations,
  SearchOptions opts,
  String url,
) async {
  final out = <Journey>[];
  for (final r in ((res['routes'] as List?) ?? []).whereType<Map<String, dynamic>>()) {
    final dep = DateTime.tryParse(r['departureTime']?.toString() ?? ''), arr = DateTime.tryParse(r['arrivalTime']?.toString() ?? '');
    if (dep == null || arr == null) continue;
    final types = ((r['vehicleTypes'] as List?) ?? const []).map((e) => '$e').toSet();
    final train = types.contains('TRAIN') && !types.contains('BUS');
    if (!train && !opts.coach) continue;
    final czk = (r['priceFrom'] as num?)?.toDouble();
    final eur = czk == null ? null : await toEur(czk, 'CZK');
    final fromName = stations[(r['departureStationId'] as num?)?.toInt()] ?? from.name;
    final toName = stations[(r['arrivalStationId'] as num?)?.toInt()] ?? to.name;
    final transfers = (r['transfersCount'] as num?)?.toInt() ?? 0;
    out.add(
      Journey(
        source: 'regiojet',
        legs: [
          Leg(
            mode: train ? Mode.long : Mode.coach,
            line: train ? (transfers > 0 ? 'RGJ (${transfers + 1} Züge)' : 'RGJ') : 'RegioJet Bus',
            operator: 'RegioJet',
            from: Place(name: fromName, lat: from.lat, lon: from.lon),
            to: Place(name: toName, lat: to.lat, lon: to.lon),
            dep: dep,
            arr: arr,
            path: from.hasCoords && to.hasCoords
                ? [
                    [from.lat!, from.lon!],
                    [to.lat!, to.lon!],
                  ]
                : [],
          ),
        ],
        prices: [
          if (eur != null)
            Price(
              amount: eur,
              source: 'regiojet',
              url: url,
              seats: (r['freeSeatsCount'] as num?)?.toInt(),
              originalAmount: czk,
              originalCurrency: 'CZK',
            ),
        ],
        dticket: false,
        soldOut: r['bookable'] == false || (r['freeSeatsCount'] as num?) == 0,
        bookingUrls: {'regiojet': url},
      ),
    );
  }
  return out;
}
