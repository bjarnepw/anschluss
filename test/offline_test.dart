import 'dart:convert';
import 'dart:typed_data';

import 'package:anschluss/core/tiles/tile_cache.dart';
import 'package:anschluss/models/journey.dart';
import 'package:anschluss/offline/router.dart';
import 'package:anschluss/offline/timetable.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

Uint8List zip(Map<String, String> files) {
  final a = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    a.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

/// A → B → C by RE 1 (every day), C → D by S 2 (weekdays only, cancelled on 2026-10-05),
/// and a night RB 9 from D that runs past midnight.
final feed = zip({
  'stops.txt':
      'stop_id,stop_name,stop_lat,stop_lon,parent_station\n'
      'a,Aheim,52.00,13.00,\n'
      'b,Bdorf,52.10,13.10,\n'
      'c1,"Cstadt, Hbf",52.20,13.20,C\n'
      'c2,"Cstadt, Hbf",52.2001,13.2001,C\n'
      'd,Dburg,52.30,13.30,\n'
      'e,Eweiler,52.40,13.40,\n',
  'routes.txt': 'route_id,route_short_name,route_type\nr1,RE 1,2\nr2,S 2,2\nr9,RB 9,2\n',
  'calendar.txt':
      'service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n'
      'daily,1,1,1,1,1,1,1,20261001,20261031\n'
      'weekday,1,1,1,1,1,0,0,20261001,20261031\n',
  'calendar_dates.txt': 'service_id,date,exception_type\nweekday,20261005,2\n',
  'trips.txt': 'route_id,service_id,trip_id\nr1,daily,t1\nr2,weekday,t2\nr9,daily,t9\n',
  'stop_times.txt':
      'trip_id,arrival_time,departure_time,stop_id,stop_sequence\n'
      't1,08:00:00,08:00:00,a,1\n'
      't1,08:20:00,08:21:00,b,2\n'
      't1,08:40:00,08:40:00,c1,3\n'
      // listed out of order on purpose
      't2,09:15:00,09:15:00,d,2\n'
      't2,08:50:00,08:50:00,c2,1\n'
      't9,23:50:00,23:50:00,d,1\n'
      't9,24:20:00,24:20:00,e,2\n',
});

DateTime berlin(int y, int m, int d, int h, int min) => DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 2)); // CEST

void main() {
  final tt = parseGtfsZips([feed]);
  final r = OfflineRouter(tt);
  const a = Place(name: 'Aheim', lat: 52.0, lon: 13.0);
  const d = Place(name: 'Dburg', lat: 52.3, lon: 13.3);
  const e = Place(name: 'Eweiler', lat: 52.4, lon: 13.4);

  test('parses stops, trips (sorted by sequence) and calendars', () {
    expect(tt.stopCount, 6);
    expect(tt.tripCount, 3);
    expect(tt.validFrom, 20261001);
    expect(tt.stopName[2], 'Cstadt, Hbf'); // quoted field with comma
    final t2 = 1;
    expect(tt.stStop[tt.tripStart[t2]], 3, reason: 'c2 comes first after sorting by stop_sequence');
    expect(tt.services[1].runsOn(DateTime(2026, 10, 5)), isFalse, reason: 'removed by calendar_dates');
    expect(tt.services[1].runsOn(DateTime(2026, 10, 6)), isTrue);
    expect(tt.services[1].runsOn(DateTime(2026, 10, 10)), isFalse, reason: 'Saturday');
  });

  test('routes with a transfer between platforms of the same station', () {
    final js = r.route(a, d, berlin(2026, 10, 6, 7, 30), count: 1);
    expect(js, hasLength(1));
    final j = js.single;
    expect(j.transit.map((l) => l.line), ['RE 1', 'S 2']);
    expect(j.transit.first.dep, berlin(2026, 10, 6, 8, 0));
    expect(j.arrival, berlin(2026, 10, 6, 9, 15));
    expect(j.transit.first.stops.single.name, 'Bdorf');
    expect(j.transit.last.mode, Mode.suburban);
  });

  test('respects the calendar (no S 2 on the cancelled day)', () {
    expect(r.route(a, d, berlin(2026, 10, 5, 7, 30), count: 1), isEmpty);
  });

  test('minimum transfer time is honoured', () {
    // 10 min between RE arrival 08:40 and S departure 08:50: 15 min minimum → no connection
    expect(r.route(a, d, berlin(2026, 10, 6, 7, 30), count: 1, minTransferMinutes: 15), isEmpty);
  });

  test('trips running past midnight', () {
    final js = r.route(d, e, berlin(2026, 10, 6, 23, 0), count: 1);
    expect(js.single.arrival, berlin(2026, 10, 7, 0, 20));
  });

  test('station search', () {
    expect(r.searchStops('cstadt').single.name, 'Cstadt, Hbf');
  });

  test('tile helpers', () {
    expect(prefetchAllowed(osmTemplate), isFalse);
    expect(prefetchAllowed('https://api.maptiler.com/maps/streets/{z}/{x}/{y}.png?key=x'), isTrue);
    final tiles = tilesAlong([const LatLng(52.52, 13.37), const LatLng(53.55, 10.0)], minZoom: 8, maxZoom: 10);
    expect(tiles, isNotEmpty);
    expect(tiles.every((t) => t.$1 >= 8 && t.$1 <= 10), isTrue);
  });
}
