# Anschluss

One search across every train source in Germany, merged into one list with prices and a map.

| Source | What it adds | Prices |
|---|---|---|
| Deutsche Bahn (db-vendo-client, DB Navigator API) | ICE/IC, all regional operators (ODEG, Metronom, erixx, NX, …), S-/U-Bahn, realtime delays, platforms | Yes (Flexpreis/Sparpreis "from" price, BahnCard, D-Ticket discount) |
| Transitous (MOTIS, open GTFS) | Everything in DELFI + FlixTrain/FlixBus GTFS + many European operators, exact track geometry for the map | No |
| Flix (flixbus/flixtrain web API) | FlixTrain (and optionally FlixBus) with live prices and seats | Yes |
| ÖBB (hafas-client) | Nightjet, Westbahn, cross-border second opinion | Rarely |

Identical connections found by several sources are merged: you see every price for the same train, DB's realtime/platforms, and Transitous' exact route on the map.

## Run

Requires Node.js 18.17+.

```
npm install
USER_AGENT="anschluss (you@example.com)" npm start
```

Open http://localhost:5173.

## Features

- Station autocomplete (DB + Transitous), depart/arrive-by, earlier/later
- Sort by best (time + changes + price + waiting), fastest, cheapest, earliest arrival, fewest changes
- Deutschlandticket: shows 0 € for covered connections, or restrict to covered trains only
- BahnCard 25/50/100 and 1st class for DB prices
- Track strip per connection (segment width = time, colour = type of train)
- Map with exact routes where available (dashed = straight line between stops), OpenRailwayMap overlay
- Per-source status line, so you see when a source is down or rate-limited

## Caveats

- None of these are official public APIs except Transitous. DB's endpoint is rate-limited (~60 req/min) and sometimes blocks; Flix's may change without notice. Each source fails independently and the rest keep working.
- DB prices are the cheapest fare shown for that connection; final price is on bahn.de.
- Please respect the Transitous usage policy: https://transitous.org/api/ (set a USER_AGENT with contact info).
- Self-host MOTIS and set TRANSITOUS_URL if you want to go heavy.

## Structure

```
server.js            HTTP server, parallel fan-out, /api/locations, /api/journeys
sources/db.js        Deutsche Bahn
sources/transitous.js Transitous / MOTIS
sources/flix.js      FlixTrain / FlixBus
sources/oebb.js      ÖBB
lib/merge.js         dedupe across sources, scoring, Pareto check
lib/fptf.js          FPTF → common journey format
public/              UI (Leaflet map)
```

Adding a source = one file exporting `journeys(from, to, opts)` that returns the common format, plus its name in server.js.
