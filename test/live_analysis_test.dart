import 'package:anschluss/models/journey.dart';
import 'package:anschluss/services/live_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Train due north along longitude 13.0: A (52.0) 10:00 → B (52.1) 10:10 → C (52.2) 10:20,
  // then a 5-minute change at C to a second train at 10:25.
  final t0 = DateTime.utc(2026, 10, 1, 8);
  DateTime at(int min) => t0.add(Duration(minutes: min));
  final path = [
    for (var i = 0; i <= 20; i++) [52.0 + i * 0.01, 13.0],
  ];
  final re1 = Leg(
    mode: Mode.regional,
    line: 'RE 1',
    from: const Place(name: 'A', lat: 52.0, lon: 13.0),
    to: const Place(name: 'C', lat: 52.2, lon: 13.0),
    dep: at(0),
    arr: at(20),
    stops: [Stopover(name: 'B', lat: 52.1, lon: 13.0, arr: at(10), dep: at(10))],
    path: path,
    pathExact: true,
  );
  final re2 = Leg(
    mode: Mode.regional,
    line: 'RE 2',
    from: const Place(name: 'C', lat: 52.2, lon: 13.0),
    to: const Place(name: 'D', lat: 52.3, lon: 13.0),
    dep: at(25),
    arr: at(40),
  );
  final j = Journey(source: 'db', dticket: true, legs: [re1, re2]);

  test('on schedule: expected position half way, no GPS delay', () {
    final a = analyseTrip(j, at(5), lat: 52.05, lon: 13.0);
    expect(a.leg, same(re1));
    expect(a.expected!.$1, closeTo(52.05, 0.002));
    expect(a.gpsDelay, 0);
    expect(a.offsetKm, lessThan(0.3));
    expect(a.risks, isEmpty);
    expect(a.atRisk, isFalse);
  });

  test('behind schedule: position says +6 min and the transfer breaks', () {
    // At 10:15 the train should be at 52.15 but you are only at 52.09 (→ time 10:09).
    final a = analyseTrip(j, at(15), lat: 52.09, lon: 13.0);
    expect(a.gpsDelay, 6);
    expect(a.offsetKm!, greaterThan(5));
    expect(a.risks.single.buffer, -1); // 5 min buffer − 6 min delay
    expect(a.atRisk, isTrue);
  });

  test('off the route', () {
    final a = analyseTrip(j, at(5), lat: 52.05, lon: 13.2);
    expect(a.offRoute, isTrue);
    expect(a.gpsDelay, isNull);
  });

  test('before departure: too far away from the station', () {
    final a = analyseTrip(j, at(-5), lat: 51.97, lon: 13.0); // ~3.3 km away, 5 min left
    expect(a.reachStation!.$1, greaterThan(a.reachStation!.$2));
    expect(a.atRisk, isTrue);
  });

  test('alternatives start at the next stop while riding', () {
    expect(alternativesStart(j, at(5)).name, 'B');
    expect(alternativesStart(j, at(12)).name, 'C');
  });
}
