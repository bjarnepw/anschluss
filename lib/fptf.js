// Normalizes FPTF journeys (db-vendo-client / hafas-client) into Anschluss' common format.
import { DTICKET_MODES, minutesBetween, refineMode } from './util.js';

const PRODUCT_MODE = {
  nationalExpress: 'long', national: 'long', interregional: 'long',
  regionalExpress: 'long', // in DB's data this product is FlixTrain & other open-access trains
  regional: 'regional', suburban: 'suburban', subway: 'metro', tram: 'tram',
  bus: 'bus', ferry: 'ferry', taxi: 'other', onCall: 'bus',
};

const pt = (loc) => {
  const l = loc?.location || loc;
  return l?.latitude != null ? { lat: l.latitude, lon: l.longitude } : {};
};

function normLeg(l) {
  const walking = !!l.walking;
  const name = l.line?.name || '';
  const operator = l.line?.operator?.name || '';
  const mode = walking ? 'walk' : refineMode(PRODUCT_MODE[l.line?.product] || 'other', name, operator);
  const from = { name: l.origin?.name || '', ...pt(l.origin) };
  const to = { name: l.destination?.name || '', ...pt(l.destination) };
  const stops = (l.stopovers || []).map((s) => ({
    name: s.stop?.name, ...pt(s.stop),
    arr: s.arrival || s.plannedArrival || null, dep: s.departure || s.plannedDeparture || null,
    cancelled: !!s.cancelled,
  }));
  let path = stops.filter((s) => s.lat != null).map((s) => [s.lat, s.lon]);
  if (path.length < 2 && from.lat != null && to.lat != null) path = [[from.lat, from.lon], [to.lat, to.lon]];
  return {
    mode,
    line: walking ? 'Walk' : name,
    operator,
    direction: l.direction || '',
    from, to,
    dep: l.departure || l.plannedDeparture,
    arr: l.arrival || l.plannedArrival,
    plannedDep: l.plannedDeparture || l.departure,
    plannedArr: l.plannedArrival || l.arrival,
    depDelay: l.departureDelay != null ? Math.round(l.departureDelay / 60) : null,
    arrDelay: l.arrivalDelay != null ? Math.round(l.arrivalDelay / 60) : null,
    depPlatform: l.departurePlatform || l.plannedDeparturePlatform || null,
    arrPlatform: l.arrivalPlatform || l.plannedArrivalPlatform || null,
    cancelled: !!l.cancelled,
    stops,
    path,
    pathExact: false,
    walkDistance: walking ? l.distance ?? null : null,
    remarks: (l.remarks || [])
      .filter((r) => r.type === 'warning' || r.type === 'status')
      .map((r) => r.summary || r.text).filter(Boolean).slice(0, 3),
  };
}

export function normalizeFptfJourney(j, source, extra = {}) {
  const legs = (j.legs || []).map(normLeg).filter((l) => l.dep && l.arr);
  if (!legs.length) return null;
  const first = legs[0], last = legs[legs.length - 1];
  const transit = legs.filter((l) => l.mode !== 'walk');
  const price = j.price?.amount != null
    ? { amount: j.price.amount, currency: j.price.currency || 'EUR', source, partial: !!j.price.partialFare, url: extra.bookingUrl || null }
    : null;
  return {
    source,
    sources: [source],
    departure: first.dep, arrival: last.arr,
    plannedDeparture: first.plannedDep, plannedArrival: last.plannedArr,
    duration: minutesBetween(first.dep, last.arr),
    transfers: Math.max(0, transit.length - 1),
    legs,
    prices: price ? [price] : [],
    dticket: transit.length > 0 && transit.every((l) => DTICKET_MODES.has(l.mode)),
    cancelled: legs.some((l) => l.cancelled),
    bookingUrl: extra.bookingUrl || null,
  };
}
