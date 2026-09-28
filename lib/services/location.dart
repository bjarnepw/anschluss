// Current position, shared by the map (blue dot) and the trip screen ("where you are").
// Never prompts on its own: only after the user taps "locate me" / "my location" once.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class LocationService {
  LocationService._();
  static final instance = LocationService._();

  final position = ValueNotifier<Position?>(null);
  StreamSubscription<Position>? _sub;

  /// Starts following the position if permission was already granted (no dialog).
  Future<void> resumeIfAllowed() async {
    try {
      final p = await Geolocator.checkPermission();
      if (p == LocationPermission.always || p == LocationPermission.whileInUse) _follow();
    } catch (e) {
      debugPrint('location unavailable: $e'); // e.g. no location service on this desktop
    }
  }

  /// Asks for permission if needed. Returns false if location can't be used.
  Future<bool> enable() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return false;
      _follow();
      position.value ??= await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high))
          .timeout(const Duration(seconds: 15));
      return true;
    } catch (e) {
      debugPrint('location unavailable: $e');
      return false;
    }
  }

  void _follow() {
    _sub ??= Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 15))
        .listen((p) => position.value = p, onError: (Object e) => debugPrint('location stream: $e'));
  }
}
