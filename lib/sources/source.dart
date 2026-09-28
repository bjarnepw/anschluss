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
  });

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
