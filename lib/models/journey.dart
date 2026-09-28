// Common journey format every source is normalized into.

/// Normalized transport classes. Used for colours, filtering and the Deutschlandticket check.
enum Mode { long, night, regional, suburban, metro, tram, bus, coach, ferry, walk, other }

const dticketModes = {Mode.regional, Mode.suburban, Mode.metro, Mode.tram, Mode.bus, Mode.ferry, Mode.walk};

Mode modeFromName(String? s) => Mode.values.firstWhere((m) => m.name == s, orElse: () => Mode.other);

class Place {
  final String name;
  final double? lat;
  final double? lon;
  final String? dbId;
  final String? transitousId;
  final String? oebbId;
  final String? area;

  const Place({required this.name, this.lat, this.lon, this.dbId, this.transitousId, this.oebbId, this.area});

  bool get hasCoords => lat != null && lon != null;

  Place mergedWith(Place o) => Place(
    name: name,
    lat: lat ?? o.lat,
    lon: lon ?? o.lon,
    dbId: dbId ?? o.dbId,
    transitousId: transitousId ?? o.transitousId,
    oebbId: oebbId ?? o.oebbId,
    area: (area?.isNotEmpty ?? false) ? area : o.area,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    if (lat != null) 'lat': lat,
    if (lon != null) 'lon': lon,
    if (dbId != null) 'dbId': dbId,
    if (transitousId != null) 'transitousId': transitousId,
    if (oebbId != null) 'oebbId': oebbId,
    if (area != null) 'area': area,
  };

  factory Place.fromJson(Map<String, dynamic> j) => Place(
    name: j['name'] as String? ?? '',
    lat: (j['lat'] as num?)?.toDouble(),
    lon: (j['lon'] as num?)?.toDouble(),
    dbId: j['dbId'] as String?,
    transitousId: j['transitousId'] as String?,
    oebbId: j['oebbId'] as String?,
    area: j['area'] as String?,
  );

  @override
  bool operator ==(Object other) => other is Place && other.name == name && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(name, lat, lon);
}

class Stopover {
  final String name;
  final double? lat;
  final double? lon;
  final DateTime? arr;
  final DateTime? dep;
  final bool cancelled;

  const Stopover({required this.name, this.lat, this.lon, this.arr, this.dep, this.cancelled = false});

  Map<String, dynamic> toJson() => {
    'name': name,
    'lat': lat,
    'lon': lon,
    'arr': arr?.toIso8601String(),
    'dep': dep?.toIso8601String(),
    'cancelled': cancelled,
  };

  factory Stopover.fromJson(Map<String, dynamic> j) => Stopover(
    name: j['name'] as String? ?? '',
    lat: (j['lat'] as num?)?.toDouble(),
    lon: (j['lon'] as num?)?.toDouble(),
    arr: _dt(j['arr']),
    dep: _dt(j['dep']),
    cancelled: j['cancelled'] == true,
  );
}

class Leg {
  final Mode mode;
  String line;
  final String operator;
  final String direction;
  final Place from;
  final Place to;
  final DateTime dep;
  final DateTime arr;
  final DateTime plannedDep;
  final DateTime plannedArr;
  final int? depDelay; // minutes
  final int? arrDelay;
  String? depPlatform;
  String? arrPlatform;
  final bool cancelled;
  List<Stopover> stops;
  List<List<double>> path; // [lat, lon]
  bool pathExact;
  final double? walkDistance;
  final List<String> remarks;

  Leg({
    required this.mode,
    required this.line,
    this.operator = '',
    this.direction = '',
    required this.from,
    required this.to,
    required this.dep,
    required this.arr,
    DateTime? plannedDep,
    DateTime? plannedArr,
    this.depDelay,
    this.arrDelay,
    this.depPlatform,
    this.arrPlatform,
    this.cancelled = false,
    this.stops = const [],
    this.path = const [],
    this.pathExact = false,
    this.walkDistance,
    this.remarks = const [],
  }) : plannedDep = plannedDep ?? dep,
       plannedArr = plannedArr ?? arr;

  bool get isWalk => mode == Mode.walk;
  int get minutes => arr.difference(dep).inMinutes;

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'line': line,
    'operator': operator,
    'direction': direction,
    'from': from.toJson(),
    'to': to.toJson(),
    'dep': dep.toIso8601String(),
    'arr': arr.toIso8601String(),
    'plannedDep': plannedDep.toIso8601String(),
    'plannedArr': plannedArr.toIso8601String(),
    'depDelay': depDelay,
    'arrDelay': arrDelay,
    'depPlatform': depPlatform,
    'arrPlatform': arrPlatform,
    'cancelled': cancelled,
    'stops': stops.map((s) => s.toJson()).toList(),
    'path': path,
    'pathExact': pathExact,
    'walkDistance': walkDistance,
    'remarks': remarks,
  };

  factory Leg.fromJson(Map<String, dynamic> j) => Leg(
    mode: modeFromName(j['mode'] as String?),
    line: j['line'] as String? ?? '',
    operator: j['operator'] as String? ?? '',
    direction: j['direction'] as String? ?? '',
    from: Place.fromJson(j['from'] as Map<String, dynamic>),
    to: Place.fromJson(j['to'] as Map<String, dynamic>),
    dep: _dt(j['dep'])!,
    arr: _dt(j['arr'])!,
    plannedDep: _dt(j['plannedDep']),
    plannedArr: _dt(j['plannedArr']),
    depDelay: j['depDelay'] as int?,
    arrDelay: j['arrDelay'] as int?,
    depPlatform: j['depPlatform'] as String?,
    arrPlatform: j['arrPlatform'] as String?,
    cancelled: j['cancelled'] == true,
    stops: ((j['stops'] as List?) ?? []).map((s) => Stopover.fromJson(s as Map<String, dynamic>)).toList(),
    path: ((j['path'] as List?) ?? []).map((p) => (p as List).map((x) => (x as num).toDouble()).toList()).toList(),
    pathExact: j['pathExact'] == true,
    walkDistance: (j['walkDistance'] as num?)?.toDouble(),
    remarks: ((j['remarks'] as List?) ?? []).cast<String>(),
  );
}

class Price {
  final double amount; // euros
  final String currency;
  final String source;
  final bool partial;
  final String? url;
  final int? seats;

  /// Fare in the operator's own currency (e.g. 299 CZK); [amount] is then the converted euro value.
  final double? originalAmount;
  final String? originalCurrency;

  const Price({
    required this.amount,
    this.currency = 'EUR',
    required this.source,
    this.partial = false,
    this.url,
    this.seats,
    this.originalAmount,
    this.originalCurrency,
  });

  bool get converted => originalCurrency != null && originalCurrency != 'EUR';

  Map<String, dynamic> toJson() => {
    'amount': amount,
    'currency': currency,
    'source': source,
    'partial': partial,
    'url': url,
    'seats': seats,
    'originalAmount': originalAmount,
    'originalCurrency': originalCurrency,
  };

  factory Price.fromJson(Map<String, dynamic> j) => Price(
    amount: (j['amount'] as num).toDouble(),
    currency: j['currency'] as String? ?? 'EUR',
    source: j['source'] as String? ?? '',
    partial: j['partial'] == true,
    url: j['url'] as String?,
    seats: j['seats'] as int?,
    originalAmount: (j['originalAmount'] as num?)?.toDouble(),
    originalCurrency: j['originalCurrency'] as String?,
  );
}

/// A transfer between two transit legs: how much time you actually have.
class Transfer {
  final Leg arriving;
  final Leg departing;
  final int minutes; // realtime arrival -> realtime departure
  final int walkMinutes; // walking legs in between
  final String station;

  const Transfer({
    required this.arriving,
    required this.departing,
    required this.minutes,
    required this.walkMinutes,
    required this.station,
  });

  /// Slack left after walking. Negative = connection will likely be missed.
  int get buffer => minutes - walkMinutes;
}

class Journey {
  final String source;
  final List<String> sources;
  final List<Leg> legs;
  final List<Price> prices;
  final bool dticket;
  final bool soldOut;
  final Map<String, String> bookingUrls;

  // Filled by ranking
  String id = '';
  int score = 0;
  double? effectivePrice;
  bool dominated = false;

  Journey({
    required this.source,
    List<String>? sources,
    required this.legs,
    List<Price>? prices,
    required this.dticket,
    this.soldOut = false,
    Map<String, String>? bookingUrls,
  }) : sources = sources ?? [source],
       prices = prices ?? [],
       bookingUrls = bookingUrls ?? {} {
    id = _makeId();
  }

  DateTime get departure => legs.first.dep;
  DateTime get arrival => legs.last.arr;
  DateTime get plannedDeparture => legs.first.plannedDep;
  DateTime get plannedArrival => legs.last.plannedArr;
  int get duration => arrival.difference(departure).inMinutes;
  List<Leg> get transit => legs.where((l) => !l.isWalk).toList();
  int get transfers => (transit.length - 1).clamp(0, 99);
  bool get cancelled => legs.any((l) => l.cancelled);

  /// Walking the whole way – free, no transfers.
  bool get walkOnly => legs.isNotEmpty && legs.every((l) => l.isWalk);

  Price? get bestPrice {
    if (prices.isEmpty) return null;
    final sorted = [...prices]..sort((a, b) => a.amount.compareTo(b.amount));
    return sorted.firstWhere((p) => !p.partial, orElse: () => sorted.first);
  }

  List<Transfer> get transferList {
    final out = <Transfer>[];
    Leg? prev;
    var walk = 0;
    for (final l in legs) {
      if (l.isWalk) {
        if (prev != null) walk += l.minutes;
        continue;
      }
      if (prev != null) {
        out.add(
          Transfer(
            arriving: prev,
            departing: l,
            minutes: l.dep.difference(prev.arr).inMinutes,
            walkMinutes: walk,
            station: prev.to.name == l.from.name ? l.from.name : '${prev.to.name} → ${l.from.name}',
          ),
        );
      }
      prev = l;
      walk = 0;
    }
    return out;
  }

  /// Shortest slack across all transfers (null for direct connections).
  int? get tightestBuffer {
    final t = transferList;
    if (t.isEmpty) return null;
    return t.map((x) => x.buffer).reduce((a, b) => a < b ? a : b);
  }

  String _makeId() {
    String k(DateTime d) => d.toUtc().toIso8601String().substring(0, 16);
    return '${k(plannedDeparture)}_${k(plannedArrival)}_$transfers';
  }

  void refreshId() => id = _makeId();

  Map<String, dynamic> toJson() => {
    'source': source,
    'sources': sources,
    'legs': legs.map((l) => l.toJson()).toList(),
    'prices': prices.map((p) => p.toJson()).toList(),
    'dticket': dticket,
    'soldOut': soldOut,
    'bookingUrls': bookingUrls,
  };

  factory Journey.fromJson(Map<String, dynamic> j) => Journey(
    source: j['source'] as String,
    sources: ((j['sources'] as List?) ?? []).cast<String>(),
    legs: ((j['legs'] as List?) ?? []).map((l) => Leg.fromJson(l as Map<String, dynamic>)).toList(),
    prices: ((j['prices'] as List?) ?? []).map((p) => Price.fromJson(p as Map<String, dynamic>)).toList(),
    dticket: j['dticket'] == true,
    soldOut: j['soldOut'] == true,
    bookingUrls: ((j['bookingUrls'] as Map?) ?? {}).cast<String, String>(),
  );
}

DateTime? _dt(Object? v) => v is String ? DateTime.tryParse(v) : null;
