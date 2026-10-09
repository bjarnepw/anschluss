import 'package:anschluss/core/net.dart';
import 'package:anschluss/models/journey.dart';
import 'package:anschluss/models/settings.dart';
import 'package:anschluss/services/merge.dart';
import 'package:anschluss/services/tricks.dart';
import 'package:anschluss/services/via_search.dart';
import 'package:anschluss/sources/source.dart';
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

  test('routes only ÖBB knows must be competitive', () {
    Leg at(String line, double lat1, double lon1, double lat2, double lon2, int dep, int arr) => Leg(
      mode: Mode.long,
      line: line,
      from: Place(name: line, lat: lat1, lon: lon1),
      to: Place(name: line, lat: lat2, lon: lon2),
      dep: DateTime.utc(2026, 10, 1, 8).add(Duration(minutes: dep)),
      arr: DateTime.utc(2026, 10, 1, 8).add(Duration(minutes: arr)),
    );
    const berlin = Place(name: 'Berlin', lat: 52.52, lon: 13.37), mannheim = Place(name: 'Mannheim', lat: 49.48, lon: 8.47);
    final db = Journey(source: 'db', dticket: false, legs: [at('ICE 1', 52.52, 13.37, 49.48, 8.47, 0, 290)]);
    final oebb = Journey(
      source: 'oebb',
      dticket: false,
      legs: [
        at('ICE 2', 52.52, 13.37, 49.45, 11.08, 0, 180), // Nürnberg
        at('ICE 3', 49.45, 11.08, 48.14, 11.56, 190, 260), // München
        at('EC 4', 48.14, 11.56, 49.48, 8.47, 270, 520),
      ],
    );
    expect(pruneImplausible([db, oebb], berlin, mannheim), [db]);
  });

  test('tricks: kept only when clearly cheaper than normal options about as fast', () {
    Journey j(String line, int dep, int arr, double price, {Trick? trick}) => Journey(
      source: trick == null ? 'db' : 'trick',
      dticket: false,
      legs: [leg(line, Mode.long, dep, arr)],
      prices: [Price(amount: price, source: 'db')],
      trick: trick,
    );
    final plain = [j('ICE 1', 0, 120, 60), j('RE 5', 0, 240, 30)];
    final cheapSplit = j('ICE 1', 0, 120, 45, trick: const Trick('split', 'Hannover Hbf'));
    final notCheaper = j('ICE 1', 0, 120, 59, trick: const Trick('split', 'Hannover Hbf'));
    final kept = usefulTricks([cheapSplit, notCheaper], plain, dticket: false);
    expect(kept, hasLength(1));
    expect(kept.single.trick!.saves, 15); // vs. the 60 € ICE, the 30 € RE arrives two hours later

    // Not merged into the normal ICE entry with the same train.
    final merged = mergeJourneys([plain, kept]);
    expect(merged, hasLength(3));
    expect(merged.where((m) => m.trick != null).single.bestPrice!.amount, 45);
  });

  test('split ticket on the same train: one leg, no transfer', () {
    final legs = seatedLegs([
      leg('ICE 1', Mode.long, 0, 100, from: 'Berlin', to: 'Hannover'),
      leg('ICE 1', Mode.long, 102, 220, from: 'Hannover', to: 'Köln'),
      leg('S 12', Mode.suburban, 230, 250, from: 'Köln', to: 'Bonn'),
    ]);
    expect(legs.map((l) => '${l.line} ${l.from.name}-${l.to.name}'), ['ICE 1 Berlin-Köln', 'S 12 Köln-Bonn']);
    expect(legs.first.stops.single.name, 'Hannover');
    expect(legs.first.minutes, 220);
  });

  test('trick hubs: on the way, not at either end', () {
    Leg ice(int dep, int arr) => Leg(
      mode: Mode.long,
      line: 'ICE 1',
      from: const Place(name: 'Berlin', lat: 52.52, lon: 13.37),
      to: const Place(name: 'Köln', lat: 50.94, lon: 6.96),
      dep: DateTime.utc(2026, 9, 29, 8),
      arr: DateTime.utc(2026, 9, 29, 12, 30),
      stops: const [
        Stopover(name: 'Spandau', lat: 52.53, lon: 13.20), // too close to the start
        Stopover(name: 'Hannover Hbf', lat: 52.38, lon: 9.74),
        Stopover(name: 'München Hbf', lat: 48.14, lon: 11.56), // far off the way
      ],
    );
    final hubs = trickHubs(const Place(name: 'Berlin', lat: 52.52, lon: 13.37), const Place(name: 'Köln', lat: 50.94, lon: 6.96), [
      Journey(source: 'db', dticket: false, legs: [ice(0, 270)]),
    ]);
    expect(hubs.map((h) => h.place.name), ['Hannover Hbf']);
    expect(hubs.single.onLongLeg, isTrue);
  });

  test('cache: one request for two calls at once, failures not kept', () async {
    final c = TtlCache();
    var calls = 0;
    Future<int> slow() async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return 7;
    }

    expect(await Future.wait([c.get('k', const Duration(minutes: 1), slow), c.get('k', const Duration(minutes: 1), slow)]), [7, 7]);
    expect(calls, 1);
    await expectLater(c.get<int>('e', const Duration(minutes: 1), () async => throw Exception('down')), throwsException);
    expect(await c.get('e', const Duration(minutes: 1), () async => 1), 1);
  });

  test('train types: switched-off groups are saved and filter results', () {
    final st = Settings.fromJson(const Settings(excludedModes: ['long', 'night']).toJson());
    final opts = SearchOptions.from(st, DateTime.utc(2026, 10, 9, 8));
    expect(opts.excludedModes, {Mode.long, Mode.night});
    Journey j(Mode m) => Journey(source: 'db', dticket: false, legs: [leg('X 1', m, 0, 60)]);
    expect(opts.allows(j(Mode.regional)), isTrue);
    expect(opts.allows(j(Mode.long)), isFalse);
  });
}
