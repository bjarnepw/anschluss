// Merges journeys from all sources: the same connection found by DB, Transitous and Flix becomes one entry
// that carries every price and the best map geometry available. Then ranks them.
import '../models/journey.dart';

const _priority = {
  'db': 0,
  'oebb': 1,
  'transitous': 2,
  'flix': 3,
  'regiojet': 3,
  'flixcombo': 4,
}; // whose leg details win (realtime, platforms)

String _minute(DateTime d) => d.toUtc().toIso8601String().substring(0, 16);

String _family(Journey j) {
  final t = j.transit;
  if (t.isEmpty) return '';
  final f = (RegExp(r'^[A-Za-z]+').firstMatch(t.first.line)?.group(0) ?? '').toLowerCase();
  return f == 'flixtrain' ? 'flx' : f;
}

String _trainNo(String line) => RegExp(r'\d{2,}').firstMatch(line)?.group(0) ?? '';

bool _close(DateTime a, DateTime b) => a.difference(b).inMinutes.abs() <= 3;

bool sameJourney(Journey a, Journey b) {
  final ta = a.transit, tb = b.transit;
  if (ta.isEmpty || tb.isEmpty) return false;
  // Same train numbers on every leg: sources may differ by a couple of minutes (platform-level vs station
  // times) or in category (ICE 178 vs RJ 178), but it is the same connection.
  if (ta.length == tb.length) {
    var allNumbered = true;
    for (var i = 0; i < ta.length && allNumbered; i++) {
      final na = _trainNo(ta[i].line), nb = _trainNo(tb[i].line);
      allNumbered = na.isNotEmpty && na == nb && _close(ta[i].plannedDep, tb[i].plannedDep) && _close(ta[i].plannedArr, tb[i].plannedArr);
    }
    if (allNumbered) return true;
  }
  // Sources disagree slightly on walking to/from the first stop; compare transit legs.
  if (_minute(ta.first.plannedDep) != _minute(tb.first.plannedDep)) return false;
  if (_minute(ta.last.plannedArr) != _minute(tb.last.plannedArr)) return false;
  // Same times but clearly different train families (e.g. ICE vs FLX) -> different connections.
  final fa = _family(a), fb = _family(b);
  return fa.isEmpty || fb.isEmpty || fa == fb;
}

Journey _absorb(Journey primary, Journey other) {
  for (final s in other.sources) {
    if (!primary.sources.contains(s)) primary.sources.add(s);
  }
  for (final p in other.prices) {
    if (!primary.prices.any((q) => q.source == p.source && q.amount == p.amount)) primary.prices.add(p);
  }
  primary.bookingUrls.addAll(other.bookingUrls);
  final pt = primary.transit, ot = other.transit;
  if (pt.length == ot.length) {
    for (var i = 0; i < pt.length; i++) {
      final leg = pt[i], o = ot[i];
      // Borrow exact track geometry (Transitous), stops, platforms and a more specific line name.
      if (!leg.pathExact && o.pathExact) {
        leg.path = o.path;
        leg.pathExact = true;
      }
      if (leg.stops.isEmpty && o.stops.isNotEmpty) leg.stops = o.stops;
      leg.depPlatform ??= o.depPlatform;
      leg.arrPlatform ??= o.arrPlatform;
      if (RegExp(r'^(FLX|FlixBus)$').hasMatch(leg.line) && o.line.length > leg.line.length) leg.line = o.line;
    }
  }
  final soldOut = primary.soldOut || other.soldOut;
  if (soldOut == primary.soldOut) return primary;
  return Journey(
    source: primary.source,
    sources: primary.sources,
    legs: primary.legs,
    prices: primary.prices,
    dticket: primary.dticket,
    soldOut: soldOut,
    bookingUrls: primary.bookingUrls,
  );
}

List<Journey> mergeJourneys(Iterable<List<Journey>> lists) {
  final all = lists.expand((l) => l).toList()..sort((a, b) => (_priority[a.source] ?? 9).compareTo(_priority[b.source] ?? 9));
  final merged = <Journey>[];
  for (final j in all) {
    final i = merged.indexWhere((m) => sameJourney(m, j));
    if (i >= 0) {
      merged[i] = _absorb(merged[i], j);
    } else {
      // copy mutable lists so absorbing never touches another source's cached object
      merged.add(
        Journey(
          source: j.source,
          sources: [...j.sources],
          legs: j.legs,
          prices: [...j.prices],
          dticket: j.dticket,
          soldOut: j.soldOut,
          bookingUrls: {...j.bookingUrls},
        ),
      );
    }
  }
  // Same id can still occur (e.g. two different routes with identical times) – make ids unique.
  final seen = <String, int>{};
  for (final j in merged) {
    j.prices.sort((a, b) => a.amount.compareTo(b.amount));
    j.refreshId();
    final n = seen[j.id] = (seen[j.id] ?? 0) + 1;
    if (n > 1) j.id = '${j.id}#$n';
  }
  return merged;
}

double? effectivePrice(Journey j, bool dticket) => j.walkOnly || (dticket && j.dticket) ? 0 : j.bestPrice?.amount;

/// "Best" = travel time + transfer penalty + money + waiting + transfer risk, all in minutes.
List<Journey> rankJourneys(
  List<Journey> journeys, {
  required DateTime when,
  required bool arriveBy,
  required bool dticket,
  int minTransfer = 0,
}) {
  final prices = journeys.map((j) => effectivePrice(j, dticket)).whereType<double>().toList()..sort();
  final median = prices.isNotEmpty ? prices[prices.length ~/ 2] : 30.0;
  for (final j in journeys) {
    final price = effectivePrice(j, dticket);
    final wait = arriveBy ? when.difference(j.arrival).inMinutes.clamp(0, 100000) : j.departure.difference(when).inMinutes.clamp(0, 100000);
    final buffer = j.tightestBuffer;
    final risk = buffer == null ? 0 : (buffer < 0 ? 120 : (buffer < minTransfer ? 25 : (buffer < 4 ? 8 : 0)));
    j.score =
        (j.duration + 12 * j.transfers + 0.6 * (price ?? median) + 0.35 * wait + risk + (j.cancelled ? 10000 : 0) + (j.soldOut ? 5000 : 0))
            .round();
    j.effectivePrice = price;
  }
  // Pareto: flag connections that another one beats on time, transfers AND price at once.
  for (final j in journeys) {
    j.dominated = journeys.any(
      (o) =>
          !identical(o, j) &&
          !o.cancelled &&
          !o.soldOut &&
          !o.departure.isBefore(j.departure) &&
          !o.arrival.isAfter(j.arrival) &&
          o.transfers <= j.transfers &&
          (o.effectivePrice ?? double.infinity) <= (j.effectivePrice ?? double.infinity) &&
          (o.arrival.isBefore(j.arrival) ||
              o.transfers < j.transfers ||
              (o.effectivePrice ?? double.infinity) < (j.effectivePrice ?? double.infinity)),
    );
  }
  return journeys..sort((a, b) => a.score.compareTo(b.score));
}
