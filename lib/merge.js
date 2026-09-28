// Merges journeys from all sources: the same connection found by DB, Transitous and Flix
// becomes one entry that carries every price and the best map geometry available.

const PRIORITY = { db: 0, oebb: 1, transitous: 2, flix: 3 }; // whose leg details win (realtime, platforms)

const minuteKey = (iso) => (iso ? new Date(iso).toISOString().slice(0, 16) : '');
const transitSig = (j) => j.legs.filter((l) => l.mode !== 'walk');

function sameJourney(a, b) {
  if (minuteKey(a.plannedDeparture) !== minuteKey(b.plannedDeparture)) {
    // Sources disagree slightly on walking to/from the first stop; compare first transit departure instead.
    const ta = transitSig(a)[0], tb = transitSig(b)[0];
    if (!ta || !tb || minuteKey(ta.plannedDep) !== minuteKey(tb.plannedDep)) return false;
  }
  const la = transitSig(a).at(-1), lb = transitSig(b).at(-1);
  if (!la || !lb || minuteKey(la.plannedArr) !== minuteKey(lb.plannedArr)) return false;
  // Same times but clearly different train families (e.g. ICE vs FLX) -> different connections.
  const fam = (j) => (transitSig(j)[0]?.line.match(/^[A-Za-z]+/)?.[0] || '').toLowerCase();
  const fa = fam(a), fb = fam(b);
  return !fa || !fb || fa === fb || fa.startsWith('flix') || fb.startsWith('flix');
}

function absorb(primary, other) {
  for (const s of other.sources) if (!primary.sources.includes(s)) primary.sources.push(s);
  for (const p of other.prices) {
    if (!primary.prices.some((q) => q.source === p.source && q.amount === p.amount)) primary.prices.push(p);
  }
  primary.soldOut = primary.soldOut || other.soldOut;
  primary.bookingUrls = { ...(primary.bookingUrls || {}), ...(other.bookingUrl ? { [other.source]: other.bookingUrl } : {}) };
  // Borrow exact track geometry (Transitous) for matching transit legs.
  const pt = transitSig(primary), ot = transitSig(other);
  if (pt.length === ot.length) {
    pt.forEach((leg, i) => {
      if (!leg.pathExact && ot[i].pathExact) { leg.path = ot[i].path; leg.pathExact = true; }
      if (!leg.stops.length && ot[i].stops.length) leg.stops = ot[i].stops;
      if (!leg.depPlatform) leg.depPlatform = ot[i].depPlatform;
      if (!leg.arrPlatform) leg.arrPlatform = ot[i].arrPlatform;
    });
  }
}

export function merge(lists) {
  const all = lists.flat().filter(Boolean)
    .sort((a, b) => (PRIORITY[a.source] ?? 9) - (PRIORITY[b.source] ?? 9));
  const merged = [];
  for (const j of all) {
    const twin = merged.find((m) => sameJourney(m, j));
    if (twin) absorb(twin, j);
    else merged.push({ ...j, sources: [...j.sources], prices: [...j.prices], bookingUrls: j.bookingUrl ? { [j.source]: j.bookingUrl } : {} });
  }
  for (const j of merged) {
    j.prices.sort((a, b) => a.amount - b.amount);
    j.bestPrice = j.prices.find((p) => !p.partial) || j.prices[0] || null;
    j.id = `${minuteKey(j.plannedDeparture)}_${minuteKey(j.plannedArrival)}_${j.transfers}`;
  }
  return merged;
}

// "Best" = travel time + transfer penalty + money + waiting, all expressed in minutes.
export function rank(journeys, { when, arriveBy, dticket }) {
  const t = new Date(when).getTime();
  const prices = journeys.map((j) => effectivePrice(j, dticket)).filter((p) => p != null);
  const medianPrice = prices.length ? prices.sort((a, b) => a - b)[Math.floor(prices.length / 2)] : 30;
  for (const j of journeys) {
    const price = effectivePrice(j, dticket);
    const wait = arriveBy
      ? Math.max(0, (t - new Date(j.arrival).getTime()) / 60000)
      : Math.max(0, (new Date(j.departure).getTime() - t) / 60000);
    j.score = Math.round(
      j.duration + 12 * j.transfers + 0.6 * (price ?? medianPrice) + 0.35 * wait +
      (j.cancelled ? 10000 : 0) + (j.soldOut ? 5000 : 0));
    j.effectivePrice = price;
  }
  // Pareto: flag connections that another one beats on time, transfers AND price at once.
  for (const j of journeys) {
    j.dominated = journeys.some((o) => o !== j && !o.cancelled &&
      new Date(o.departure) >= new Date(j.departure) && new Date(o.arrival) <= new Date(j.arrival) &&
      o.transfers <= j.transfers && (o.effectivePrice ?? Infinity) <= (j.effectivePrice ?? Infinity) &&
      (new Date(o.arrival) < new Date(j.arrival) || o.transfers < j.transfers || (o.effectivePrice ?? Infinity) < (j.effectivePrice ?? Infinity)));
  }
  return journeys.sort((a, b) => a.score - b.score);
}

export function effectivePrice(j, dticket) {
  if (dticket && j.dticket) return 0;
  return j.bestPrice ? j.bestPrice.amount : null;
}
