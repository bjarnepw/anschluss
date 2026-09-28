// App state + persistence (settings, favourites, recents, offline copy of the last search, saved trips).
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/net.dart';
import '../models/journey.dart';
import '../models/settings.dart';

class SavedRoute {
  final Place from;
  final Place to;
  const SavedRoute(this.from, this.to);

  String get key => '${from.name}→${to.name}';
  Map<String, dynamic> toJson() => {'from': from.toJson(), 'to': to.toJson()};
  factory SavedRoute.fromJson(Map<String, dynamic> j) =>
      SavedRoute(Place.fromJson(j['from'] as Map<String, dynamic>), Place.fromJson(j['to'] as Map<String, dynamic>));
}

/// Last search, kept so the app shows something useful when offline.
class SavedSearch {
  final SavedRoute route;
  final DateTime when;
  final bool arriveBy;
  final List<Journey> journeys;
  final DateTime fetchedAt;
  const SavedSearch(this.route, this.when, this.arriveBy, this.journeys, this.fetchedAt);

  Map<String, dynamic> toJson() => {
    'route': route.toJson(),
    'when': when.toIso8601String(),
    'arriveBy': arriveBy,
    'journeys': journeys.map((j) => j.toJson()).toList(),
    'fetchedAt': fetchedAt.toIso8601String(),
  };

  factory SavedSearch.fromJson(Map<String, dynamic> j) => SavedSearch(
    SavedRoute.fromJson(j['route'] as Map<String, dynamic>),
    DateTime.parse(j['when'] as String),
    j['arriveBy'] == true,
    ((j['journeys'] as List?) ?? []).map((x) => Journey.fromJson(x as Map<String, dynamic>)).toList(),
    DateTime.parse(j['fetchedAt'] as String),
  );
}

/// A trip the user saved: kept on the device (works offline) and refreshed whenever there is a connection.
class SavedTrip {
  final String id;
  final Journey journey;
  final SavedRoute route;
  final DateTime savedAt;
  final DateTime? updatedAt;

  /// What changed on refreshes (delays, platforms, cancellations), newest first.
  final List<String> changes;

  const SavedTrip({
    required this.id,
    required this.journey,
    required this.route,
    required this.savedAt,
    this.updatedAt,
    this.changes = const [],
  });

  bool get finished => journey.arrival.isBefore(DateTime.now());
  bool get ongoing => !journey.departure.isAfter(DateTime.now()) && !finished;

  SavedTrip copyWith({Journey? journey, DateTime? updatedAt, List<String>? changes}) => SavedTrip(
    id: id,
    journey: journey ?? this.journey,
    route: route,
    savedAt: savedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    changes: changes ?? this.changes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'journey': journey.toJson(),
    'route': route.toJson(),
    'savedAt': savedAt.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
    'changes': changes,
  };

  factory SavedTrip.fromJson(Map<String, dynamic> j) => SavedTrip(
    id: j['id'] as String,
    journey: Journey.fromJson(j['journey'] as Map<String, dynamic>),
    route: SavedRoute.fromJson(j['route'] as Map<String, dynamic>),
    savedAt: DateTime.tryParse(j['savedAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
    changes: ((j['changes'] as List?) ?? const []).whereType<String>().toList(),
  );
}

class AppStore extends ChangeNotifier {
  SharedPreferences? _prefs;

  Settings settings = const Settings();
  List<SavedRoute> favorites = [];
  List<Place> recentPlaces = [];
  List<SavedRoute> recentRoutes = [];
  SavedSearch? lastSearch;
  List<SavedTrip> trips = [];

  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      settings = Settings.fromJson(_read('settings') as Map<String, dynamic>? ?? {});
      favorites = _list('favorites', SavedRoute.fromJson);
      recentPlaces = _list('recentPlaces', Place.fromJson);
      recentRoutes = _list('recentRoutes', SavedRoute.fromJson);
      final ls = _read('lastSearch');
      if (ls is Map<String, dynamic>) lastSearch = SavedSearch.fromJson(ls);
      trips = _list('trips', SavedTrip.fromJson);
      // Migrate the single "tracked" journey of older versions.
      final old = _read('tracked');
      if (old is Map<String, dynamic>) {
        try {
          final j = Journey.fromJson(old['journey'] as Map<String, dynamic>);
          trips.add(
            SavedTrip(id: j.id, journey: j, route: SavedRoute.fromJson(old['route'] as Map<String, dynamic>), savedAt: DateTime.now()),
          );
        } catch (_) {}
        _write('tracked', null);
      }
      // Trips that ended more than a day ago are no longer useful.
      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      trips.removeWhere((t) => t.journey.arrival.isBefore(cutoff));
      _sortTrips();
      _writeTrips();
    } catch (e) {
      debugPrint('store: could not load saved data: $e');
    }
    Net.instance.webProxy = settings.webProxy;
  }

  Object? _read(String key) {
    final s = _prefs?.getString(key);
    if (s == null) return null;
    try {
      return jsonDecode(s);
    } catch (_) {
      return null; // corrupt entry: ignore instead of crashing on startup
    }
  }

  List<T> _list<T>(String key, T Function(Map<String, dynamic>) f) {
    final v = _read(key);
    if (v is! List) return [];
    final out = <T>[];
    for (final x in v) {
      try {
        out.add(f(x as Map<String, dynamic>));
      } catch (_) {
        /* skip bad entry */
      }
    }
    return out;
  }

  void _write(String key, Object? value) {
    final p = _prefs;
    if (p == null) return;
    if (value == null) {
      p.remove(key);
    } else {
      p.setString(key, jsonEncode(value));
    }
  }

  void updateSettings(Settings s) {
    settings = s;
    Net.instance.webProxy = s.webProxy;
    _write('settings', s.toJson());
    notifyListeners();
  }

  bool isFavorite(Place from, Place to) => favorites.any((r) => r.from.name == from.name && r.to.name == to.name);

  void toggleFavorite(Place from, Place to) {
    if (isFavorite(from, to)) {
      favorites.removeWhere((r) => r.from.name == from.name && r.to.name == to.name);
    } else {
      favorites.add(SavedRoute(from, to));
    }
    _write('favorites', favorites.map((r) => r.toJson()).toList());
    notifyListeners();
  }

  void removeFavorite(SavedRoute r) {
    favorites.removeWhere((x) => x.key == r.key);
    _write('favorites', favorites.map((r) => r.toJson()).toList());
    notifyListeners();
  }

  void reorderFavorites(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    favorites.insert(newIndex, favorites.removeAt(oldIndex));
    _write('favorites', favorites.map((r) => r.toJson()).toList());
    notifyListeners();
  }

  void rememberSearch(Place from, Place to) {
    for (final p in [to, from]) {
      recentPlaces.removeWhere((x) => x.name == p.name);
      recentPlaces.insert(0, p);
    }
    if (recentPlaces.length > 10) recentPlaces = recentPlaces.sublist(0, 10);
    final r = SavedRoute(from, to);
    recentRoutes.removeWhere((x) => x.key == r.key);
    recentRoutes.insert(0, r);
    if (recentRoutes.length > 6) recentRoutes = recentRoutes.sublist(0, 6);
    _write('recentPlaces', recentPlaces.map((p) => p.toJson()).toList());
    _write('recentRoutes', recentRoutes.map((r) => r.toJson()).toList());
    notifyListeners();
  }

  void clearRecents() {
    recentPlaces = [];
    recentRoutes = [];
    _write('recentPlaces', null);
    _write('recentRoutes', null);
    notifyListeners();
  }

  void saveLastSearch(SavedSearch s) {
    lastSearch = s;
    _write('lastSearch', s.toJson());
  }

  void _sortTrips() => trips.sort((a, b) => a.journey.departure.compareTo(b.journey.departure));
  void _writeTrips() => _write('trips', trips.map((t) => t.toJson()).toList());

  SavedTrip? tripById(String id) => trips.where((t) => t.id == id).firstOrNull;

  bool isSaved(Journey j) => trips.any((t) => t.id == j.id);

  /// The trip to show in the bar at the bottom: the one underway, else the next one today.
  SavedTrip? get activeTrip {
    final now = DateTime.now();
    return trips.where((t) => t.ongoing).firstOrNull ??
        trips.where((t) => t.journey.departure.isAfter(now) && t.journey.departure.difference(now).inHours < 12).firstOrNull;
  }

  SavedTrip saveTrip(Journey j, SavedRoute route) {
    final existing = tripById(j.id);
    if (existing != null) return existing;
    final t = SavedTrip(id: j.id, journey: j, route: route, savedAt: DateTime.now(), updatedAt: DateTime.now());
    trips.add(t);
    _sortTrips();
    _writeTrips();
    notifyListeners();
    return t;
  }

  void removeTrip(String id) {
    trips.removeWhere((t) => t.id == id);
    _writeTrips();
    notifyListeners();
  }

  void updateTrip(SavedTrip t) {
    final i = trips.indexWhere((x) => x.id == t.id);
    if (i < 0) return;
    trips[i] = t;
    _writeTrips();
    notifyListeners();
  }
}
