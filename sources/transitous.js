// Transitous (https://transitous.org) – free, community-run MOTIS router built on open GTFS data:
// all German public transport (DELFI), FlixBus/FlixTrain GTFS, and many European operators.
// Gives exact route geometry for the map. No prices. Usage policy: https://transitous.org/api/
import { fetchJson, decodePolyline, distKm, cached, DTICKET_MODES, minutesBetween, refineMode } from '../lib/util.js';

const BASE = process.env.TRANSITOUS_URL || 'https://api.transitous.org';
export const id = 'transitous';
export const label = 'Transitous';

const MODE = {
  HIGHSPEED_RAIL: 'long', LONG_DISTANCE: 'long', NIGHT_RAIL: 'night',
  REGIONAL_FAST_RAIL: 'regional', REGIONAL_RAIL: 'regional', RAIL: 'regional',
  SUBURBAN: 'suburban', METRO: 'metro', SUBWAY: 'metro', TRAM: 'tram', CABLE_CAR: 'tram',
  BUS: 'bus', COACH: 'coach', FERRY: 'ferry', WALK: 'walk',
  FUNICULAR: 'other', AERIAL_LIFT: 'other', AREAL_LIFT: 'other', AIRPLANE: 'other', OTHER: 'other',
};

// MOTIS bumps the plan API version now and then; find the newest one the server speaks.
let planVersion = null;
async function plan(params) {
  const versions = planVersion ? [planVersion] : [6, 5, 4, 3, 2, 1];
  let lastErr;
  for (const v of versions) {
    try {
      const data = await fetchJson(`${BASE}/api/v${v}/plan?${params}`, { timeout: 15000 });
      planVersion = v;
      return data;
    } catch (e) {
      lastErr = e;
      if (e.status !== 404 && e.status !== 400) throw e;
    }
  }
  throw lastErr;
}

export async function locations(q) {
  const res = await cached(`tr:geo:${q}`, 3600e3, () =>
    fetchJson(`${BASE}/api/v1/geocode?${new URLSearchParams({ text: q, type: 'STOP', language: 'de' })}`, { timeout: 5000 }));
  return (Array.isArray(res) ? res : []).slice(0, 8).map((m) => ({
    name: m.name, lat: m.lat, lon: m.lon, transitousId: m.id,
    area: (m.areas || []).find((a) => a.default)?.name || '',
  }));
}

function geometry(leg) {
  const g = leg.legGeometry;
  if (!g?.points) return null;
  const want = { lat: leg.from.lat, lon: leg.from.lon };
  const candidates = g.precision ? [g.precision, 7, 6, 5] : [7, 6, 5];
  for (const p of candidates) {
    const pts = decodePolyline(g.points, p);
    if (pts.length && distKm(want, { lat: pts[0][0], lon: pts[0][1] }) < 5) return pts;
  }
  return null;
}

function normLeg(l) {
  const baseMode = MODE[l.mode] || 'other';
  const name = l.displayName || l.routeShortName || l.tripShortName || l.category?.shortName || '';
  const mode = baseMode === 'walk' ? 'walk' : refineMode(baseMode, name, l.agencyName);
  const exact = geometry(l);
  const path = exact || [[l.from.lat, l.from.lon], [l.to.lat, l.to.lon]];
  const delay = (a, b) => (a && b ? minutesBetween(b, a) : null);
  return {
    mode,
    line: mode === 'walk' ? 'Walk' : name,
    operator: l.agencyName || '',
    direction: l.headsign || '',
    from: { name: l.from.name, lat: l.from.lat, lon: l.from.lon },
    to: { name: l.to.name, lat: l.to.lat, lon: l.to.lon },
    dep: l.startTime, arr: l.endTime,
    plannedDep: l.scheduledStartTime || l.startTime, plannedArr: l.scheduledEndTime || l.endTime,
    depDelay: l.realTime ? delay(l.startTime, l.scheduledStartTime) : null,
    arrDelay: l.realTime ? delay(l.endTime, l.scheduledEndTime) : null,
    depPlatform: l.from.track || l.from.scheduledTrack || null,
    arrPlatform: l.to.track || l.to.scheduledTrack || null,
    cancelled: !!l.cancelled,
    stops: (l.intermediateStops || []).map((s) => ({ name: s.name, lat: s.lat, lon: s.lon, arr: s.arrival, dep: s.departure })),
    path,
    pathExact: !!exact,
    walkDistance: mode === 'walk' ? l.distance ?? null : null,
    remarks: [],
  };
}

export async function journeys(from, to, opts) {
  const place = (p) => (p.lat != null ? `${p.lat},${p.lon}` : p.transitousId);
  const fromPlace = place(from), toPlace = place(to);
  if (!fromPlace || !toPlace) throw new Error('Transitous needs coordinates – pick a suggestion from the list');
  const params = new URLSearchParams({
    fromPlace, toPlace,
    time: new Date(opts.when).toISOString(),
    arriveBy: opts.arriveBy ? 'true' : 'false',
    numItineraries: String(opts.results || 6),
    detailedTransfers: 'false',
    joinInterlinedLegs: 'true',
  });
  const data = await plan(params);
  const out = [];
  for (const it of data.itineraries || []) {
    const legs = (it.legs || []).map(normLeg).filter((l) => l.dep && l.arr);
    if (!legs.length) continue;
    // "Trains" app: drop long-distance coaches unless the user wants them.
    if (!opts.coach && legs.some((l) => l.mode === 'coach')) continue;
    const transit = legs.filter((l) => l.mode !== 'walk');
    if (!transit.length) continue;
    const first = legs[0], last = legs[legs.length - 1];
    out.push({
      source: id, sources: [id],
      departure: first.dep, arrival: last.arr,
      plannedDeparture: first.plannedDep, plannedArrival: last.plannedArr,
      duration: minutesBetween(first.dep, last.arr),
      transfers: it.transfers ?? Math.max(0, transit.length - 1),
      legs, prices: [],
      dticket: transit.every((l) => DTICKET_MODES.has(l.mode)),
      cancelled: legs.some((l) => l.cancelled),
      bookingUrl: null,
    });
  }
  if (opts.dticketOnly) return out.filter((j) => j.dticket);
  return out;
}
