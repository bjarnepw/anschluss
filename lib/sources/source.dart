import '../models/journey.dart';
import '../models/settings.dart';

class SearchOptions {
  final DateTime when;
  final bool arriveBy;
  final int minTransferMinutes;
  final int? maxTransfers;
  final int bahncard;
  final bool firstClass;
  final bool dticket;
  final bool dticketOnly;
  final bool bike;
  final bool coach;
  final int? age;
  final int results;

  /// Longest walk to/from stations, in minutes.
  final int maxWalkMinutes;

  /// Also offer walking the whole way when that is competitive.
  final bool includeWalking;

  /// Walking the whole way is shown up to this many minutes (or when about as fast as the train).
  final int walkOnlyMaxMinutes;

  /// Ask sources for slower-but-cheaper and more varied connections, and search Flix+feeder combos.
  final bool moreAlternatives;

  /// Only local/regional trains and buses (Deutschlandticket modes) – used for Flix feeders.
  final bool regionalOnly;

  const SearchOptions({
    required this.when,
    this.arriveBy = false,
    this.minTransferMinutes = 0,
    this.maxTransfers,
    this.bahncard = 0,
    this.firstClass = false,
    this.dticket = false,
    this.dticketOnly = false,
    this.bike = false,
    this.coach = false,
    this.age,
    this.results = 6,
    this.maxWalkMinutes = 15,
    this.includeWalking = true,
    this.walkOnlyMaxMinutes = 30,
    this.moreAlternatives = true,
    this.regionalOnly = false,
  });

  /// For follow-up searches: never offers walking the whole way.
  SearchOptions copyWith({DateTime? when, int? results, bool? dticketOnly, bool? moreAlternatives, bool? regionalOnly}) => SearchOptions(
    when: when ?? this.when,
    arriveBy: arriveBy,
    minTransferMinutes: minTransferMinutes,
    maxTransfers: maxTransfers,
    bahncard: bahncard,
    firstClass: firstClass,
    dticket: dticket,
    dticketOnly: dticketOnly ?? this.dticketOnly,
    bike: bike,
    coach: coach,
    age: age,
    results: results ?? this.results,
    maxWalkMinutes: maxWalkMinutes,
    includeWalking: false,
    walkOnlyMaxMinutes: walkOnlyMaxMinutes,
    moreAlternatives: moreAlternatives ?? this.moreAlternatives,
    regionalOnly: regionalOnly ?? this.regionalOnly,
  );

  factory SearchOptions.from(Settings s, DateTime when, {bool arriveBy = false}) => SearchOptions(
    when: when,
    arriveBy: arriveBy,
    minTransferMinutes: s.minTransferMinutes,
    maxTransfers: s.maxTransfers,
    bahncard: s.bahncard,
    firstClass: s.firstClass,
    dticket: s.dticket,
    dticketOnly: s.dticketOnly,
    bike: s.bike,
    coach: s.coach,
    age: s.age,
    maxWalkMinutes: s.maxWalkMinutes,
    includeWalking: s.includeWalking,
    walkOnlyMaxMinutes: s.walkOnlyMaxMinutes,
    moreAlternatives: s.moreAlternatives,
    results: s.moreAlternatives ? 8 : 6,
  );
}

abstract class Source {
  String get id;
  String get label;

  /// Whether a browser may call this API directly (CORS). If not, web builds need the proxy.
  bool get corsFriendly;

  Future<List<Journey>> journeys(Place from, Place to, SearchOptions opts);
}

/// Sources that can also suggest stations.
abstract class LocationSource {
  Future<List<Place>> locations(String query);
}
