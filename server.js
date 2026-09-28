// Anschluss – local server. Runs every source in parallel, merges and ranks the results,
// and serves the web UI. Start with `npm start`, then open http://localhost:5173
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { withTimeout, distKm } from './lib/util.js';
import { merge, rank } from './lib/merge.js';

const PORT = Number(process.env.PORT || 5173);
const ROOT = join(fileURLToPath(new URL('.', import.meta.url)), 'public');

// Load sources defensively: one broken dependency must not take the app down.
const SOURCES = {};
for (const name of ['db', 'transitous', 'flix', 'oebb']) {
  try { SOURCES[name] = await import(`./sources/${name}.js`); }
  catch (e) { console.warn(`[${name}] disabled: ${e.message}`); }
}

const json = (res, code, body) => {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
};

async function handleLocations(q) {
  const [db, tr] = await Promise.allSettled([
    SOURCES.db ? withTimeout(SOURCES.db.locations(q), 5000, 'db') : Promise.resolve([]),
    SOURCES.transitous ? withTimeout(SOURCES.transitous.locations(q), 5000, 'transitous') : Promise.resolve([]),
  ]);
  const out = [];
  const add = (list) => {
    for (const l of list) {
      const twin = out.find((o) => o.name.toLowerCase() === l.name.toLowerCase() || distKm(o, l) < 0.3);
      if (twin) Object.assign(twin, { ...l, ...twin, lat: twin.lat ?? l.lat, lon: twin.lon ?? l.lon });
      else out.push({ ...l });
    }
  };
  if (db.status === 'fulfilled') add(db.value);
  if (tr.status === 'fulfilled') add(tr.value);
  return out.slice(0, 10);
}

async function handleJourneys(p) {
  const from = JSON.parse(p.get('from') || 'null');
  const to = JSON.parse(p.get('to') || 'null');
  if (!from?.name || !to?.name) throw Object.assign(new Error('Choose a start and a destination.'), { code: 400 });
  const opts = {
    when: p.get('when') || new Date().toISOString(),
    arriveBy: p.get('arriveBy') === '1',
    coach: p.get('coach') === '1',
    dticket: p.get('dticket') === '1',
    dticketOnly: p.get('dticketOnly') === '1',
    bahncard: Number(p.get('bahncard') || 0) || null,
    firstClass: p.get('class') === '1',
    age: p.get('age') || null,
    results: 6,
  };
  const wanted = (p.get('sources') || 'db,transitous,flix,oebb').split(',').filter((s) => SOURCES[s]);

  const status = {};
  const lists = await Promise.all(wanted.map(async (s) => {
    const t0 = Date.now();
    try {
      const list = await withTimeout(SOURCES[s].journeys(from, to, opts), 25000, s);
      status[s] = { ok: true, count: list.length, ms: Date.now() - t0 };
      return list;
    } catch (e) {
      status[s] = { ok: false, error: e.message, ms: Date.now() - t0 };
      console.warn(`[${s}] ${e.message}`);
      return [];
    }
  }));
  const journeys = rank(merge(lists), opts);
  return { journeys, status, query: { from, to, ...opts } };
}

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.json': 'application/json' };

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if (url.pathname === '/api/locations') {
      const q = (url.searchParams.get('q') || '').trim();
      return json(res, 200, q.length < 2 ? [] : await handleLocations(q));
    }
    if (url.pathname === '/api/journeys') return json(res, 200, await handleJourneys(url.searchParams));
    if (url.pathname === '/api/sources') {
      return json(res, 200, Object.fromEntries(Object.entries(SOURCES).map(([k, m]) => [k, m.label])));
    }
    const file = normalize(join(ROOT, url.pathname === '/' ? 'index.html' : url.pathname));
    if (!file.startsWith(ROOT)) return json(res, 403, { error: 'forbidden' });
    const body = await readFile(file);
    res.writeHead(200, { 'Content-Type': MIME[extname(file)] || 'application/octet-stream' });
    res.end(body);
  } catch (e) {
    if (e.code === 'ENOENT') return json(res, 404, { error: 'not found' });
    json(res, e.code === 400 ? 400 : 500, { error: e.message });
  }
});

server.listen(PORT, () => {
  console.log(`Anschluss running on http://localhost:${PORT}`);
  console.log(`Sources: ${Object.keys(SOURCES).join(', ')}`);
});
