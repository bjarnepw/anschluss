import 'package:anschluss/models/journey.dart';
import 'package:anschluss/models/settings.dart';
import 'package:anschluss/services/merge.dart';
import 'package:anschluss/services/via_search.dart';
import 'package:anschluss/ui/line_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Leg leg(String line, Mode mode, int depMin, int arrMin, {String from = 'A', String to = 'B'}) {
  final base = DateTime.utc(2026, 9, 29, 8);
  return Leg(
    mode: mode,
    line: line,
    from: Place(name: from),
    to: Place(name: to),
    dep: base.add(Duration(minutes: depMin)),
    arr: base.add(Duration(minutes: arrMin)),
  );
}

void main() {
  group('transfers', () {
    test('buffer subtracts walking time', () {
      final j = Journey(
        source: 'db',
        dticket: false,
        legs: [
          leg('RE 1', Mode.regional, 0, 30, to: 'X'),
          leg('Walk', Mode.walk, 30, 35, from: 'X', to: 'X2'),
          leg('S 3', Mode.suburban, 38, 50, from: 'X2'),
        ],
      );
      final t = j.transferList.single;
      expect(t.minutes, 8);
      expect(t.walkMinutes, 5);
      expect(t.buffer, 3);
      expect(j.tightestBuffer, 3);
      expect(j.transfers, 1);
    });

    test('direct journeys have no transfer', () {
      final j = Journey(source: 'db', dticket: false, legs: [leg('ICE 1', Mode.long, 0, 60)]);
      expect(j.tightestBuffer, isNull);
    });
  });

  group('merge', () {
    test('same connection from two sources becomes one with both prices', () {
      final a = Journey(
        source: 'db',
        dticket: false,
        legs: [leg('FLX 10', Mode.long, 0, 120)],
        prices: [const Price(amount: 40, source: 'db')],
      );
      final b = Journey(
        source: 'flix',
        dticket: false,
        legs: [leg('FLX', Mode.long, 0, 120)],
        prices: [const Price(amount: 19.99, source: 'flix')],
        bookingUrls: {'flix': 'u'},
      );
      final c = Journey(source: 'transitous', dticket: false, legs: [leg('ICE 5', Mode.long, 0, 120)]);
      final m = mergeJourneys([
        [a],
        [b],
        [c],
      ]);
      expect(m, hasLength(2), reason: 'ICE is a different train than FLX at the same time');
      final flx = m.firstWhere((j) => j.sources.contains('flix'));
      expect(flx.sources, containsAll(['db', 'flix']));
      expect(flx.bestPrice!.amount, 19.99);
      expect(flx.bookingUrls['flix'], 'u');
      expect(m.map((j) => j.id).toSet(), hasLength(2), reason: 'ids stay unique');
    });

    test('ranking penalises missed transfers and flags dominated options', () {
      final good = Journey(
        source: 'db',
        dticket: false,
        legs: [leg('ICE 1', Mode.long, 0, 60)],
        prices: [const Price(amount: 20, source: 'db')],
      );
      final worse = Journey(
        source: 'db',
        dticket: false,
        legs: [
          leg('RE 1', Mode.regional, 0, 30, to: 'X'),
          leg('RE 2', Mode.regional, 28, 70, from: 'X'), // negative buffer
        ],
        prices: [const Price(amount: 30, source: 'db')],
      );
      final ranked = rankJourneys([worse, good], when: DateTime.utc(2026, 9, 29, 8), arriveBy: false, dticket: false);
      expect(ranked.first, same(good));
      expect(worse.dominated, isTrue);
      expect(good.dominated, isFalse);
    });

    test('Deutschlandticket makes covered journeys free', () {
      final j = Journey(
        source: 'db',
        dticket: true,
        legs: [leg('RE 1', Mode.regional, 0, 30)],
        prices: [const Price(amount: 9, source: 'db')],
      );
      expect(effectivePrice(j, true), 0);
      expect(effectivePrice(j, false), 9);
    });
  });

  group('line colours', () {
    double hue(Color c) => HSLColor.fromColor(c).hue;

    test('each line gets its own stable shade of its family colour', () {
      final re1 = lineColor(leg('RE 1', Mode.regional, 0, 1), Brightness.light);
      final re7 = lineColor(leg('RE 7', Mode.regional, 0, 1), Brightness.light);
      final re1b = lineColor(leg('RE1', Mode.regional, 0, 1), Brightness.light);
      expect(re1, isNot(re7));
      expect(re1, re1b, reason: 'spacing does not matter');
      // both stay within the RE family hue range
      expect((hue(re1) - 212).abs(), lessThan(12));
      expect((hue(re7) - 212).abs(), lessThan(12));
    });

    test('families are recognised by line name', () {
      expect(familyOf(leg('ICE 804', Mode.long, 0, 1)).key, 'ice');
      expect(familyOf(leg('IC 2023', Mode.long, 0, 1)).key, 'ic');
      expect(familyOf(leg('FLX 10', Mode.long, 0, 1)).key, 'flx');
      expect(familyOf(leg('NJ 40470', Mode.night, 0, 1)).key, 'night');
      expect(familyOf(leg('RB 23', Mode.regional, 0, 1)).key, 'rb');
      expect(familyOf(leg('S15', Mode.suburban, 0, 1)).key, 's');
      expect(familyOf(leg('U2', Mode.metro, 0, 1)).key, 'u');
      expect(familyOf(leg('Bus 100', Mode.bus, 0, 1)).key, 'bus');
      expect(familyOf(leg('RJX 60', Mode.long, 0, 1)).key, 'rj');
    });
  });

  group('settings', () {
    test('survive round trip and ignore garbage', () {
      const s = Settings(minTransferMinutes: 12, bahncard: 25, sources: ['db', 'flix'], language: AppLanguage.en);
      final back = Settings.fromJson(s.toJson());
      expect(back.minTransferMinutes, 12);
      expect(back.bahncard, 25);
      expect(back.sources, ['db', 'flix']);
      expect(back.language, AppLanguage.en);
      final junk = Settings.fromJson({
        'minTransferMinutes': 'x',
        'sources': ['nope', 'db'],
        'language': 'fr',
        'trackRefreshSeconds': 1,
      });
      expect(junk.minTransferMinutes, 0);
      expect(junk.sources, ['db']);
      expect(junk.language, AppLanguage.de);
      expect(junk.trackRefreshSeconds, 30);
    });

    test('journey JSON round trip (offline cache)', () {
      final j = Journey(
        source: 'db',
        dticket: true,
        legs: [leg('RE 1', Mode.regional, 0, 30)],
        prices: [const Price(amount: 9, source: 'db')],
      );
      final back = Journey.fromJson(j.toJson());
      expect(back.id, j.id);
      expect(back.legs.single.line, 'RE 1');
      expect(back.bestPrice!.amount, 9);
    });
  });

  test('stopover journeys are joined with prices added up', () {
    final a = Journey(
      source: 'db',
      dticket: false,
      legs: [leg('RE 1', Mode.regional, 0, 30, to: 'V')],
      prices: [const Price(amount: 10, source: 'db')],
    );
    final b = Journey(
      source: 'transitous',
      dticket: true,
      legs: [leg('S 2', Mode.suburban, 40, 60, from: 'V')],
      prices: [const Price(amount: 4.5, source: 'db')],
    );
    final j = joinJourneys(a, b);
    expect(j.legs.map((l) => l.line), ['RE 1', 'S 2']);
    expect(j.duration, 60);
    expect(j.transfers, 1);
    expect(j.bestPrice!.amount, 14.5);
    expect(j.bestPrice!.partial, isTrue);
    expect(j.sources, containsAll(['db', 'transitous']));
  });

  test('huge detours are dropped even when cheap', () {
    Leg at(String line, double lat1, double lon1, double lat2, double lon2, int dep, int arr) => Leg(
      mode: Mode.long,
      line: line,
      from: Place(name: line, lat: lat1, lon: lon1),
      to: Place(name: line, lat: lat2, lon: lon2),
      dep: DateTime.utc(2026, 10, 1, 8).add(Duration(minutes: dep)),
      arr: DateTime.utc(2026, 10, 1, 8).add(Duration(minutes: arr)),
    );
    const berlin = Place(name: 'Berlin', lat: 52.52, lon: 13.37), heidelberg = Place(name: 'Heidelberg', lat: 49.40, lon: 8.68);
    final direct = Journey(
      source: 'db',
      dticket: false,
      legs: [at('ICE 1', 52.52, 13.37, 49.40, 8.68, 0, 330)],
      prices: [const Price(amount: 90, source: 'db')],
    );
    final crazy = Journey(
      source: 'db',
      dticket: false,
      legs: [
        at('ICE 2', 52.52, 13.37, 48.14, 11.56, 0, 240), // → München
        at('EC 3', 48.14, 11.56, 47.42, 9.37, 250, 450), // → St. Gallen
        at('IC 4', 47.42, 9.37, 49.40, 8.68, 460, 700), // → Heidelberg
      ],
      prices: [const Price(amount: 30, source: 'db')],
    );
    final kept = pruneImplausible([direct, crazy], berlin, heidelberg);
    expect(kept, [direct]);
  });
}
