// Journeys with stopovers ("via"): searched segment by segment and joined, so it works with every source
// (not all of them support via stations). A → V: full search; V → B: for each of the best A → V results,
// the earliest onward connection after arriving at V.
import 'dart:async';

import '../models/journey.dart';
import '../sources/source.dart';
import 'merge.dart';
import 'search.dart';

const _keepPerSegment = 6;

SearchOptions _at(SearchOptions o, DateTime when) => SearchOptions(
  when: when,
  minTransferMinutes: o.minTransferMinutes,
  maxTransfers: o.maxTransfers,
  bahncard: o.bahncard,
  firstClass: o.firstClass,
  dticket: o.dticket,
  dticketOnly: o.dticketOnly,
  bike: o.bike,
  coach: o.coach,
  age: o.age,
  results: 3,
  maxWalkMinutes: o.maxWalkMinutes,
  includeWalking: false,
  moreAlternatives: false,
);

/// Joins two consecutive journeys (the second starts where the first ends).
Journey joinJourneys(Journey a, Journey b) {
  final pa = a.bestPrice, pb = b.bestPrice;
  return Journey(
    source: a.source,
    sources: {...a.sources, ...b.sources}.toList(),
    legs: [...a.legs, ...b.legs],
    prices: [
      if (pa != null && pb != null)
        Price(amount: ((pa.amount + pb.amount) * 100).round() / 100, source: pa.source, partial: true, url: pa.url)
      else if (pa != null || pb != null)
        Price(amount: (pa ?? pb)!.amount, source: (pa ?? pb)!.source, partial: true, url: (pa ?? pb)!.url),
    ],
    dticket: a.dticket && b.dticket,
    soldOut: a.soldOut || b.soldOut,
    bookingUrls: {...a.bookingUrls, ...b.bookingUrls},
  );
}

Stream<SearchResult> searchWithVias(
  Place from,
  List<Place> vias,
  Place to,
  SearchOptions opts,
  List<String> wanted, {
  bool hideTight = false,
  bool offlineOnly = false,
  Duration stay = Duration.zero,
}) async* {
  if (vias.isEmpty) {
    yield* searchJourneys(from, to, opts, wanted, hideTight: hideTight, offlineOnly: offlineOnly);
    return;
  }
  final points = [from, ...vias, to];
  final transfer = Duration(minutes: opts.minTransferMinutes > 0 ? opts.minTransferMinutes : 3);
  // Onward segments: fast sources only (many small searches).
  final onward = offlineOnly ? const ['offline'] : wanted.where((w) => w == 'transitous' || w == 'db' || w == 'oebb').toList();

  // Segment 1 with everything, streaming the source status.
  SearchResult? first;
  await for (final r in searchJourneys(points[0], points[1], opts, wanted, hideTight: hideTight, offlineOnly: offlineOnly)) {
    first = r;
    yield SearchResult(const [], r.status, fetchedAt: r.fetchedAt);
  }
  if (first == null) return;
  var partial = first.journeys.where((j) => !j.cancelled && !j.walkOnly).take(_keepPerSegment).toList();

  for (var seg = 1; seg < points.length - 1 && partial.isNotEmpty; seg++) {
    final next = <Journey>[];
    await Future.wait(
      partial.map((j) async {
        final earliest = j.arrival.add(stay).add(transfer);
        SearchResult? r;
        try {
          await for (final x in searchJourneys(points[seg], points[seg + 1], _at(opts, earliest), onward, offlineOnly: offlineOnly)) {
            r = x;
          }
        } catch (_) {}
        final options =
            (r?.journeys ?? const <Journey>[])
                .where((b) => !b.cancelled && !b.departure.isBefore(earliest.subtract(const Duration(minutes: 1))))
                .toList()
              ..sort((x, y) => x.arrival.compareTo(y.arrival));
        if (options.isNotEmpty) next.add(joinJourneys(j, options.first));
      }),
    );
    // Several first parts often reach the same onward train – keep only the one leaving latest
    // (no point in waiting an hour at the stopover).
    final byOnward = <String, Journey>{};
    for (final j in next) {
      final tail = j.legs.skipWhile((l) => l.isWalk).toList().reversed.firstWhere((l) => !l.isWalk);
      final key = '${tail.line}@${tail.plannedDep.toIso8601String()}';
      final old = byOnward[key];
      if (old == null || j.departure.isAfter(old.departure)) byOnward[key] = j;
    }
    partial = byOnward.values.toList();
  }

  final merged = mergeJourneys([partial]);
  rankJourneys(merged, when: opts.when, arriveBy: false, dticket: opts.dticket, minTransfer: opts.minTransferMinutes);
  yield SearchResult(merged, first.status, done: true, fetchedAt: DateTime.now());
}
