// Deutsche Bahn via db-vendo-client (DB Navigator "movas" API).
// Covers DB Fernverkehr, nearly all regional operators in Germany (ODEG, Metronom, erixx, NX, ...),
// local transport, plus FlixTrain / Nightjet / European Sleeper timetables (usually without prices).
import { createClient } from 'db-vendo-client';
import { profile as dbnavProfile } from 'db-vendo-client/p/dbnav/index.js';
import { data as loyaltyCards } from 'db-vendo-client/format/loyalty-cards.js';
import { USER_AGENT, cached } from '../lib/util.js';
import { normalizeFptfJourney } from '../lib/fptf.js';

const client = createClient(dbnavProfile, USER_AGENT, { enrichStations: true });

export const id = 'db';
export const label = 'Deutsche Bahn';

export async function locations(q) {
  const res = await cached(`db:loc:${q}`, 3600e3, () =>
    client.locations(q, { results: 8, addresses: false, poi: false, stops: true }));
  return res
    .filter((l) => l.type === 'stop' || l.type === 'station')
    .map((l) => ({
      name: l.name,
      lat: l.location?.latitude ?? null,
      lon: l.location?.longitude ?? null,
      dbId: l.id,
    }));
}

async function resolve(place) {
  if (place.dbId) return place.dbId;
  const [hit] = await locations(place.name);
  if (!hit) throw new Error(`DB does not know "${place.name}"`);
  return hit.dbId;
}

function bookingUrl(from, to, when, opts) {
  const p = new URLSearchParams({
    sts: 'true', so: from.name, zo: to.name, hd: new Date(when).toISOString().slice(0, 19),
    kl: opts.firstClass ? '1' : '2',
  });
  return `https://www.bahn.de/buchung/fahrplan/suche#${p}`;
}

export async function journeys(from, to, opts) {
  const [fromId, toId] = await Promise.all([resolve(from), resolve(to)]);
  const q = {
    results: opts.results || 6,
    stopovers: true,
    remarks: true,
    firstClass: !!opts.firstClass,
    language: 'en',
    deutschlandTicketDiscount: !!opts.dticket,
    deutschlandTicketConnectionsOnly: !!opts.dticketOnly,
    bestprice: !!opts.bestprice,
  };
  if (opts.arriveBy) q.arrival = new Date(opts.when); else q.departure = new Date(opts.when);
  if (opts.bahncard) {
    q.loyaltyCard = { type: loyaltyCards.BAHNCARD, discount: Number(opts.bahncard), class: opts.firstClass ? 1 : 2 };
  }
  if (opts.age) q.age = Number(opts.age);

  const res = await client.journeys(fromId, toId, q);
  const url = bookingUrl(from, to, opts.when, opts);
  return (res.journeys || [])
    .map((j) => normalizeFptfJourney(j, id, { bookingUrl: url }))
    .filter(Boolean);
}
