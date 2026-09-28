// Shared helpers: fetch with timeout, caching, polyline decoding, mode classification.

export const USER_AGENT =
  process.env.USER_AGENT || 'anschluss-local/0.1 (personal journey planner; set USER_AGENT to your contact)';

export async function fetchJson(url, { timeout = 12000, headers = {} } = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeout);
  try {
    const res = await fetch(url, {
      signal: ctrl.signal,
      headers: { Accept: 'application/json', 'User-Agent': USER_AGENT, ...headers },
    });
    if (!res.ok) {
      const err = new Error(`HTTP ${res.status} from ${new URL(url).host}`);
      err.status = res.status;
      throw err;
    }
    return await res.json();
  } catch (e) {
    if (e.name === 'AbortError') throw new Error(`timeout after ${timeout} ms (${new URL(url).host})`);
    throw e;
  } finally {
    clearTimeout(t);
  }
}

export function withTimeout(promise, ms, label) {
  let t;
  return Promise.race([
    promise.finally(() => clearTimeout(t)),
    new Promise((_, rej) => { t = setTimeout(() => rej(new Error(`${label}: timeout after ${ms} ms`)), ms); }),
  ]);
}

// Small TTL cache so repeated searches don't hammer rate-limited APIs.
const cache = new Map();
export async function cached(key, ttlMs, fn) {
  const hit = cache.get(key);
  if (hit && hit.exp > Date.now()) return hit.val;
  const val = await fn();
  cache.set(key, { val, exp: Date.now() + ttlMs });
  if (cache.size > 500) cache.delete(cache.keys().next().value);
  return val;
}

// Google encoded polyline with arbitrary precision.
export function decodePolyline(str, precision = 5) {
  const factor = 10 ** precision;
  const out = [];
  let i = 0, lat = 0, lon = 0;
  while (i < str.length) {
    for (const which of [0, 1]) {
      let shift = 0, result = 0, b;
      do { b = str.charCodeAt(i++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20 && i < str.length);
      const d = result & 1 ? ~(result >> 1) : result >> 1;
      if (which === 0) lat += d; else lon += d;
    }
    out.push([lat / factor, lon / factor]);
  }
  return out;
}

export function distKm(a, b) {
  if (!a || !b || a.lat == null || b.lat == null) return Infinity;
  const R = 6371, rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad, dLon = (b.lon - a.lon) * rad;
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(s));
}

// Normalized mode classes (used for colours and the Deutschlandticket check).
// long: ICE/IC/EC/FlixTrain  night: Nightjet/European Sleeper  regional: RE/RB  suburban: S-Bahn  metro: U-Bahn
export const DTICKET_MODES = new Set(['regional', 'suburban', 'metro', 'tram', 'bus', 'ferry', 'walk']);

export const minutesBetween = (a, b) => Math.round((new Date(b) - new Date(a)) / 60000);

// Nightly/open-access trains that we can recognise by line name in any source.
export function refineMode(mode, name = '', operator = '') {
  const s = `${name} ${operator}`;
  if (/\b(NJ|EN|ES)\s?\d/.test(s) || /nightjet|european sleeper|snälltåget|snalltaget|nachtzug/i.test(s)) return 'night';
  if (/\bFLX\b|flixtrain/i.test(s)) return 'long';
  return mode;
}
