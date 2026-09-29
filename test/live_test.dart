// Hits the real APIs. Not part of the normal run: `flutter test --tags live`
@Tags(['live'])
library;

import 'package:anschluss/models/journey.dart';
import 'package:anschluss/services/search.dart';
import 'package:anschluss/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const berlin = Place(name: 'Berlin Hbf', lat: 52.525589, lon: 13.369549, dbId: '8011160');
  const hamburg = Place(name: 'Hamburg Hbf', lat: 53.552733, lon: 10.006909, dbId: '8002549');

  String fmt(Journey j) =>
      '${j.departure.toLocal()} → ${j.arrival.toLocal()} ${j.transit.map((l) => l.line).join(' / ')} '
      '${j.prices.map((p) => '${p.source}:${p.amount}').join(',')} [${j.sources.join(',')}]';

  for (final id in sources.keys.where((k) => k != 'offline' && k != 'regiojet')) {
    test('$id returns journeys in the future', () async {
      final when = DateTime.now().add(const Duration(hours: 12));
      final js = await sources[id]!.journeys(berlin, hamburg, SearchOptions(when: when));
      for (final j in js) {
        // ignore: avoid_print
        print('$id: ${fmt(j)}');
      }
      expect(js, isNotEmpty);
      expect(js.every((j) => j.arrival.isAfter(when.subtract(const Duration(hours: 1)))), isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  test('merged search', () async {
    final when = DateTime.now().add(const Duration(hours: 12));
    SearchResult? last;
    await for (final r in searchJourneys(berlin, hamburg, SearchOptions(when: when), sources.keys.where((k) => k != 'offline').toList())) {
      last = r;
    }
    for (final j in last!.journeys) {
      // ignore: avoid_print
      print('merged: ${fmt(j)}');
    }
    // ignore: avoid_print
    print(last.status.map((k, v) => MapEntry(k, '${v.state.name} ${v.count} ${v.error ?? ''}')));
    expect(last.journeys, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('locations', () async {
    final l = await searchLocations('Berlin Hbf');
    // ignore: avoid_print
    print(l.map((p) => '${p.name} db=${p.dbId} tr=${p.transitousId}').join('\n'));
    expect(l, isNotEmpty);
  });

  test('Flix combos where the start has no Flix stop', () async {
    const salzwedel = Place(name: 'Salzwedel', lat: 52.8516, lon: 11.1592);
    const koeln = Place(name: 'Köln Hbf', lat: 50.9430, lon: 6.9589);
    const pasewalk = Place(name: 'Pasewalk', lat: 53.5049, lon: 13.9849);
    for (final to in [koeln, pasewalk]) {
      final when = DateTime.now().add(const Duration(hours: 12));
      SearchResult? last;
      await for (final r in searchJourneys(
        salzwedel,
        to,
        SearchOptions(when: when, results: 8),
        sources.keys.where((k) => k != 'offline').toList(),
      )) {
        last = r;
      }
      // ignore: avoid_print
      print('--- Salzwedel → ${to.name}: ${last!.status.map((k, v) => MapEntry(k, '${v.state.name} ${v.count} ${v.error ?? ''}'))}');
      for (final j in last.journeys) {
        // ignore: avoid_print
        print('${j.sources.contains('flix') ? 'FLIX ' : '     '}${fmt(j)}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('RegioJet Prague → Vienna with fares converted from CZK', () async {
    const praha = Place(name: 'Praha hl.n.', lat: 50.0831, lon: 14.4353);
    const wien = Place(name: 'Wien Hbf', lat: 48.1852, lon: 16.3760);
    final js = await regioJetSource.journeys(praha, wien, SearchOptions(when: DateTime.now().add(const Duration(hours: 12))));
    for (final j in js) {
      final p = j.bestPrice!;
      // ignore: avoid_print
      print('${fmt(j)} = ${p.originalAmount} ${p.originalCurrency}');
    }
    expect(js, isNotEmpty);
    expect(js.first.bestPrice!.originalCurrency, 'CZK');
  });

  test('address search and routing from an address', () async {
    final hits = await searchLocations('Friedrich-Ebert-Straße 79 Potsdam');
    final addr = hits.firstWhere((p) => p.kind == PlaceKind.address);
    // ignore: avoid_print
    print('address: ${addr.name} (${addr.area}) ${addr.lat},${addr.lon}');
    SearchResult? last;
    await for (final r in searchJourneys(addr, berlin, SearchOptions(when: DateTime.now().add(const Duration(hours: 12))), [
      'db',
      'transitous',
    ])) {
      last = r;
    }
    for (final j in last!.journeys.take(5)) {
      // ignore: avoid_print
      print('${fmt(j)}  legs: ${j.legs.map((l) => l.isWalk ? 'walk${l.minutes}' : l.line).join(' / ')}');
    }
    expect(last.journeys, isNotEmpty);
    expect(last.journeys.first.legs.first.isWalk, isTrue);
  });
}
