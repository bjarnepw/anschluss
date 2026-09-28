// FlixTrain (and optionally FlixBus) with live prices and seat availability,
// via the JSON API behind flixbus.de / flixtrain.de. Unofficial: it can change without notice.
import { fetchJson, distKm, cached, minutesBetween } from '../lib/util.js';

const BASE = 'https://global.api.flixbus.com';
export const id = 'flix';
export const label = 'Flix';

// Flix works with cities, not stations: "Berlin Hbf" -> "Berlin".
function cityQuery(name) {
  return name
    .replace(/\(.*?\)/g, ' ')
    .split(/[,/]/)[0]
    .replace(/\b(Hbf|Hauptbahnhof|Bahnhof|Bf|Süd|Nord|Ost|West|Mitte|Flughafen|Airport|ZOB|Fernbusbahnhof|tief)\b\.?/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim() || name;
}

async function findCity(place) {
  const q = cityQuery(place.name);
  const res = await cached(`flix:city:${q}`, 24 * 3600e3, () =>
    fetchJson(`${BASE}/search/autocomplete/cities?${new URLSearchParams({
      q, lang: 'de', country: 'de', flixbus_cities_only: 'false', stations: 'true',
    })}`, { timeout: 6000 }));
  const list = (Array.isArray(res) ? res : res?.cities || []).map((c) => ({
    id: c.id || c.uuid, name: c.name,
    lat: c.location?.lat ?? c.location?.latitude ?? c.coordinates?.latitude,
    lon: c.location?.lon ?? c.location?.longitude ?? c.coordinates?.longitude,
  })).filter((c) => c.id);
  if (!list.length) throw new Error(`Flix has no city matching "${q}"`);
  if (place.lat != null) {
    list.sort((a, b) => distKm(place, a) - distKm(place, b));
    if (list[0].lat != null && distKm(place, list[0]) > 40) throw new Error(`no Flix stop near ${place.name}`);
  }
  return list[0];
}

const ddmmyyyy = (d) => `${String(d.getDate()).padStart(2, '0')}.${String(d.getMonth() + 1).padStart(2, '0')}.${d.getFullYear()}`;

function stationInfo(data, stationId, fallbackName) {
  const s = data.stations?.[stationId] || {};
  const c = s.coordinates || s.location || {};
  return {
    name: s.name || fallbackName || '',
    lat: c.latitude ?? c.lat ?? null,
    lon: c.longitude ?? c.lon ?? null,
  };
}

function normRide(r, data, fromCity, toCity, when) {
  const rawLegs = r.legs?.length ? r.legs : [{ departure: r.departure, arrival: r.arrival, means_of_transport: r.means_of_transport }];
  const legs = rawLegs.map((l) => {
    const isTrain = /train/i.test(l.means_of_transport || '');
    const from = stationInfo(data, l.departure?.station_id, l.departure?.station_name);
    const to = stationInfo(data, l.arrival?.station_id, l.arrival?.station_name);
    const line = l.line_code || l.line?.code || l.operated_by?.line || '';
    return {
      mode: isTrain ? 'long' : 'coach',
      line: `${isTrain ? 'FLX' : 'FlixBus'}${line ? ' ' + line : ''}`,
      operator: isTrain ? 'FlixTrain' : 'FlixBus',
      direction: l.direction || '',
      from, to,
      dep: l.departure?.date, arr: l.arrival?.date,
      plannedDep: l.departure?.date, plannedArr: l.arrival?.date,
      depDelay: null, arrDelay: null, depPlatform: null, arrPlatform: null,
      cancelled: false, stops: [],
      path: from.lat != null && to.lat != null ? [[from.lat, from.lon], [to.lat, to.lon]] : [],
      pathExact: false, walkDistance: null, remarks: [],
    };
  }).filter((l) => l.dep && l.arr);
  if (!legs.length) return null;
  const total = r.price?.total ?? r.price?.total_with_platform_fee ?? r.price?.average;
  const url = `https://shop.flixbus.de/search?${new URLSearchParams({
    departureCity: fromCity.id, arrivalCity: toCity.id, rideDate: ddmmyyyy(new Date(when)), adult: '1', _locale: 'de',
  })}`;
  const seats = r.available?.seats ?? null;
  return {
    source: id, sources: [id],
    departure: legs[0].dep, arrival: legs.at(-1).arr,
    plannedDeparture: legs[0].dep, plannedArrival: legs.at(-1).arr,
    duration: minutesBetween(legs[0].dep, legs.at(-1).arr),
    transfers: legs.length - 1,
    legs,
    prices: total != null ? [{ amount: Math.round(total * 100) / 100, currency: 'EUR', source: id, url, seats }] : [],
    soldOut: r.status && r.status !== 'available',
    dticket: false,
    cancelled: false,
    bookingUrl: url,
  };
}

async function searchDay(fromCity, toCity, day) {
  const params = new URLSearchParams({
    from_city_id: fromCity.id, to_city_id: toCity.id,
    departure_date: ddmmyyyy(day),
    products: JSON.stringify({ adult: 1 }),
    currency: 'EUR', locale: 'de', search_by: 'cities', include_after_midnight_rides: '1',
  });
  return cached(`flix:${params}`, 120e3, () => fetchJson(`${BASE}/search/service/v4/search?${params}`, { timeout: 12000 }));
}

export async function journeys(from, to, opts) {
  if (opts.dticketOnly) return []; // Flix never accepts the Deutschlandticket
  const [fromCity, toCity] = await Promise.all([findCity(from), findCity(to)]);
  const when = new Date(opts.when);
  const data = await searchDay(fromCity, toCity, when);
  const out = [];
  for (const trip of data.trips || []) {
    const results = Array.isArray(trip.results) ? trip.results : Object.values(trip.results || {});
    for (const r of results) {
      const j = normRide(r, data, fromCity, toCity, when);
      if (!j) continue;
      if (!opts.coach && j.legs.some((l) => l.mode === 'coach')) continue;
      out.push(j);
    }
  }
  out.sort((a, b) => new Date(a.departure) - new Date(b.departure));
  const t = when.getTime();
  const windowed = opts.fullDay ? out
    : opts.arriveBy
      ? out.filter((j) => new Date(j.arrival) <= t).slice(-(opts.results || 6))
      : out.filter((j) => new Date(j.departure) >= t - 15 * 60e3).slice(0, opts.results || 6);
  return windowed;
}
