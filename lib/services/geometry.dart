// Real track geometry for legs that only have straight lines between stops (DB, ÖBB, Flix, offline):
// looks up the same train on Transitous and takes its route along the rail network.
import '../core/util.dart';
import '../models/journey.dart';
import '../sources/transitous.dart';

final _inFlight = <String, Future<bool>>{};

/// Replaces straight-line legs of [j] with the real route where it can be found.
/// Mutates the legs in place (so saved trips keep it) and returns whether anything changed.
Future<bool> enrichGeometry(Journey j) {
  // Trains: the real track. Walks longer than ~100 m: the real footpath.
  final todo = j.legs
      .where((l) => !l.pathExact && l.from.hasCoords && l.to.hasCoords)
      .where((l) => !l.isWalk || distKm(l.from.lat, l.from.lon, l.to.lat, l.to.lon) > 0.1)
      .toList();
  if (todo.isEmpty) return Future.value(false);
  return _inFlight.putIfAbsent(j.id, () async {
    try {
      final tracks = await Future.wait(todo.map((l) => l.isWalk ? walkForLeg(l) : trackForLeg(l)));
      var changed = false;
      for (var i = 0; i < todo.length; i++) {
        final t = tracks[i];
        if (t == null) continue;
        todo[i].path = t;
        todo[i].pathExact = true;
        changed = true;
      }
      return changed;
    } finally {
      _inFlight.remove(j.id);
    }
  });
}
