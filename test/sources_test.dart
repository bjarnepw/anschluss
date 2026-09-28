import 'dart:convert';
import 'dart:io';

import 'package:anschluss/core/util.dart';
import 'package:anschluss/models/journey.dart';
import 'package:anschluss/sources/db.dart';
import 'package:anschluss/sources/flix.dart';
import 'package:anschluss/sources/oebb.dart';
import 'package:anschluss/sources/source.dart';
import 'package:anschluss/sources/transitous.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> fixture(String name) => jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

void main() {
  final opts = SearchOptions(when: DateTime.utc(2026, 9, 29, 6));

  group('Transitous (real response)', () {
    final js = parseTransitousPlan(fixture('transitous_plan.json'), opts);

    test('parses itineraries with exact geometry', () {
      expect(js, isNotEmpty);
      final ice = js.first.transit.first;
      expect(ice.line, 'ICE 804');
      expect(ice.mode, Mode.long);
      expect(ice.pathExact, isTrue);
      expect(ice.path.length, greaterThan(10));
      expect(ice.depPlatform, '8');
      expect(ice.dep, DateTime.utc(2026, 9, 29, 8, 9));
    });

    test('dticket-only filter drops long-distance', () {
      final dOnly = parseTransitousPlan(fixture('transitous_plan.json'), SearchOptions(when: opts.when, dticketOnly: true));
      expect(dOnly.every((j) => j.dticket), isTrue);
    });
  });

  group('ÖBB HAFAS (real response)', () {
    final js = parseOebbTrips(fixture('oebb_tripsearch.json')['svcResL'][0]['res'] as Map<String, dynamic>, opts);

    test('parses connections, times with day offset and time zone', () {
      expect(js, isNotEmpty);
      final j = js.first;
      final first = j.transit.first;
      expect(first.line, 'S15');
      expect(first.mode, Mode.suburban);
      expect(first.from.name, 'Berlin Hbf (S-Bahn)');
      // 22:37 CEST on 29.09. = 20:37 UTC
      expect(first.dep, DateTime.utc(2026, 9, 29, 20, 37));
      expect(first.depPlatform, '22');
      // RE5 arrives "01012100" = next day 01:21 CEST
      final re = j.transit[1];
      expect(re.line, 'RE5');
      expect(re.mode, Mode.regional);
      expect(re.arr, DateTime.utc(2026, 9, 29, 23, 21));
      expect(re.operator, isNotEmpty);
      expect(j.transfers, 2);
    });

    test('hafasTime handles offsets', () {
      expect(hafasTime('20260101', '120000', 60), DateTime.utc(2026, 1, 1, 11));
      expect(hafasTime('20260101', '02000500', null), DateTime.utc(2026, 1, 2, 23, 5)); // day +2, 00:05 CET = 23:05 UTC
    });
  });

  group('Flix (real response)', () {
    final data = fixture('flix_search.json');
    final cities = data['cities'] as Map<String, dynamic>;
    final ids = cities.keys.toList();
    const from = (id: '40d8f682-8646-11e6-9066-549f350fcb0c', name: 'Berlin', lat: 52.52, lon: 13.37);
    final to = (id: ids.firstWhere((k) => k != from.id), name: 'Hamburg', lat: 53.55, lon: 10.0);

    test('trains only unless coaches are wanted, price includes platform fee', () {
      final trains = parseFlixSearch(data, from, to, opts);
      expect(trains, isNotEmpty);
      expect(trains.every((j) => j.legs.every((l) => l.mode == Mode.long)), isTrue);
      expect(trains.first.prices.single.amount, greaterThan(0));
      final withBus = parseFlixSearch(data, from, to, SearchOptions(when: opts.when, coach: true));
      expect(withBus.length, greaterThan(trains.length));
    });

    test('city query strips station words', () {
      expect(flixCityQuery('Berlin Hbf (tief)'), 'Berlin');
      expect(flixCityQuery('S+U Berlin Hauptbahnhof'), 'Berlin');
      expect(flixCityQuery('Hamburg Hbf'), 'Hamburg');
    });
  });

  group('DB (real response)', () {
    test('flat movas legs: line name, product, platform, price', () {
      final js = parseDbJourneys(fixture('db_journeys.json'), bookingUrl: 'u');
      expect(js, isNotEmpty);
      final l = js.first.transit.first;
      expect(l.line, 'ICE 604');
      expect(l.mode, Mode.long);
      expect(l.direction, 'Hamburg-Altona');
      expect(l.depPlatform, '6');
      expect(l.from.name, 'Berlin Hbf');
      expect(l.from.hasCoords, isTrue);
      expect(l.dep, DateTime.utc(2026, 9, 29, 7, 37));
      expect(js.first.bestPrice!.amount, 59.99);
    });
  });

  group('DB (synthetic response with realtime and stopovers)', () {
    // DB blocks many networks, so this fixture is built from the fields db-vendo-client reads.
    final res = {
      'verbindungen': [
        {
          'verbindung': {
            'verbindungsAbschnitte': [
              {
                'typ': 'FAHRZEUG',
                'abgangsDatum': '2026-09-29T10:00:00+02:00',
                'ezAbgangsDatum': '2026-09-29T10:04:00+02:00',
                'ankunftsDatum': '2026-09-29T11:00:00+02:00',
                'verkehrsmittel': {
                  'name': 'ICE 123',
                  'produktGattung': 'ICE',
                  'richtung': 'Hamburg-Altona',
                  'zugattribute': [
                    {'key': 'BEF', 'value': 'DB Fernverkehr AG'},
                  ],
                },
                'halte': [
                  {
                    'id': 'A=1@O=Berlin Hbf@X=13369549@Y=52525589@L=8011160@',
                    'abgangsDatum': '2026-09-29T10:00:00+02:00',
                    'ezAbgangsDatum': '2026-09-29T10:04:00+02:00',
                    'gleis': '14',
                  },
                  {
                    'id': 'A=1@O=Berlin-Spandau@X=13196898@Y=52534794@L=8010404@',
                    'ankunftsDatum': '2026-09-29T10:15:00+02:00',
                    'abgangsDatum': '2026-09-29T10:16:00+02:00',
                  },
                  {
                    'id': 'A=1@O=Hamburg Hbf@X=10006909@Y=53552733@L=8002549@',
                    'ankunftsDatum': '2026-09-29T11:00:00+02:00',
                    'gleis': '7',
                    'ezGleis': '8',
                  },
                ],
                'echtzeitNotizen': [
                  {'text': 'Verspätung aus vorheriger Fahrt'},
                ],
              },
            ],
          },
          'angebotsPreis': {'betrag': 29.99, 'waehrung': 'EUR'},
        },
      ],
    };

    test('parses legs, realtime, platforms, stops and price', () {
      final js = parseDbJourneys(res, bookingUrl: 'https://www.bahn.de/x');
      expect(js, hasLength(1));
      final l = js.single.legs.single;
      expect(l.line, 'ICE 123');
      expect(l.mode, Mode.long);
      expect(l.operator, 'DB Fernverkehr AG');
      expect(l.depDelay, 4);
      expect(l.dep, DateTime.utc(2026, 9, 29, 8, 4));
      expect(l.arrPlatform, '8');
      expect(l.from.dbId, '8011160');
      expect(l.from.lat, closeTo(52.5256, 0.001));
      expect(l.stops.single.name, 'Berlin-Spandau');
      expect(l.remarks, contains('Verspätung aus vorheriger Fahrt'));
      expect(js.single.bestPrice!.amount, 29.99);
    });

    test('parseLid', () {
      expect(parseLid('A=1@O=Berlin Hbf@L=8011160@'), {'A': '1', 'O': 'Berlin Hbf', 'L': '8011160'});
    });
  });

  group('time zone helpers', () {
    test('CET/CEST switch', () {
      expect(cetOffset(DateTime.utc(2026, 7, 1)), const Duration(hours: 2));
      expect(cetOffset(DateTime.utc(2026, 1, 15)), const Duration(hours: 1));
      expect(cetOffset(DateTime.utc(2026, 3, 29, 0, 59)), const Duration(hours: 1)); // last Sunday of March 2026
      expect(cetOffset(DateTime.utc(2026, 3, 29, 1)), const Duration(hours: 2));
      expect(cetOffset(DateTime.utc(2026, 10, 25, 1)), const Duration(hours: 1));
      expect(cetIso(DateTime.utc(2026, 9, 29, 6)), '2026-09-29T08:00:00+02:00');
    });

    test('polyline decoding', () {
      expect(decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@'), [
        [38.5, -120.2],
        [40.7, -120.95],
        [43.252, -126.453],
      ]);
    });
  });
}
