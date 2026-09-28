@Tags(['live'])
library;

import 'dart:io';

import 'package:anschluss/models/journey.dart';
import 'package:anschluss/offline/router.dart';
import 'package:anschluss/offline/timetable.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parse + route real gtfs.de feeds', () {
    final dir = Platform.environment['GTFS_DIR']!;
    final sw = Stopwatch()..start();
    final tt = parseGtfsZips([File('$dir/fv_free.zip').readAsBytesSync(), File('$dir/rv_free.zip').readAsBytesSync()]);
    // ignore: avoid_print
    print(
      'parse ${sw.elapsedMilliseconds} ms: ${tt.stopCount} stops, ${tt.tripCount} trips, ${tt.stStop.length} stop times, valid ${tt.validFrom}-${tt.validTo}',
    );
    final r = OfflineRouter(tt);
    const salzwedel = Place(name: 'Salzwedel', lat: 52.8516, lon: 11.1592);
    const pasewalk = Place(name: 'Pasewalk', lat: 53.5049, lon: 13.9849);
    const koeln = Place(name: 'Köln Hbf', lat: 50.9430, lon: 6.9589);
    const berlin = Place(name: 'Berlin Hbf', lat: 52.525589, lon: 13.369549);
    const hamburg = Place(name: 'Hamburg Hbf', lat: 53.552733, lon: 10.006909);
    for (final (a, b) in [(salzwedel, pasewalk), (salzwedel, koeln), (berlin, hamburg)]) {
      sw.reset();
      final js = r.route(a, b, DateTime.now().add(const Duration(hours: 12)), count: 4, minTransferMinutes: 5);
      // ignore: avoid_print
      print('${a.name} → ${b.name}: ${sw.elapsedMilliseconds} ms');
      for (final j in js) {
        // ignore: avoid_print
        print(
          '  ${j.departure.toLocal()} → ${j.arrival.toLocal()} ${j.duration} min: ${j.legs.map((l) => l.isWalk ? 'walk${l.minutes}' : '${l.line}(${l.from.name}→${l.to.name})').join(' / ')}',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
