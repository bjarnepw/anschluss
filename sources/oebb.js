// ÖBB HAFAS via hafas-client. Independent second opinion for cross-border trips,
// Nightjet, Westbahn and trains into Austria/Switzerland/Italy. Usually no prices.
import { createClient } from 'hafas-client';
import { profile as oebbProfile } from 'hafas-client/p/oebb/index.js';
import { USER_AGENT, cached, distKm } from '../lib/util.js';
import { normalizeFptfJourney } from '../lib/fptf.js';

const client = createClient(oebbProfile, USER_AGENT);

export const id = 'oebb';
export const label = 'ÖBB';

async function resolve(place) {
  const res = await cached(`oebb:loc:${place.name}`, 3600e3, () =>
    client.locations(place.name, { results: 5, addresses: false, poi: false }));
  const stops = res.filter((l) => l.type === 'stop' || l.type === 'station');
  if (!stops.length) throw new Error(`ÖBB does not know "${place.name}"`);
  // prefer the candidate closest to the coordinates the user picked
  stops.sort((a, b) =>
    distKm(place, { lat: a.location?.latitude, lon: a.location?.longitude }) -
    distKm(place, { lat: b.location?.latitude, lon: b.location?.longitude }));
  return stops[0].id;
}

export async function journeys(from, to, opts) {
  const [fromId, toId] = await Promise.all([resolve(from), resolve(to)]);
  const q = { results: opts.results || 5, stopovers: true, remarks: true, language: 'en' };
  if (opts.arriveBy) q.arrival = new Date(opts.when); else q.departure = new Date(opts.when);
  const res = await client.journeys(fromId, toId, q);
  return (res.journeys || [])
    .map((j) => normalizeFptfJourney(j, id, { bookingUrl: 'https://shop.oebbtickets.at/' }))
    .filter(Boolean);
}
