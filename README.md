# Anschluss

One search across every train source in Germany, merged into one list with prices, on a map.
Flutter app for Android, iOS, Linux, macOS and the web. No server needed: the app talks to the APIs directly.

| Source | What it adds | Prices |
|---|---|---|
| Deutsche Bahn (DB Navigator API) | ICE/IC, all regional operators (ODEG, Metronom, erixx, NX, …), S-/U-Bahn, realtime, platforms | Yes (from-price, BahnCard, D-Ticket) |
| Transitous (MOTIS, open GTFS) | All of DELFI + FlixTrain GTFS + many European operators, exact track geometry for the map | No |
| Flix | FlixTrain (optionally FlixBus) with live prices and seats | Yes |
| ÖBB (HAFAS) | Nightjet, Westbahn, cross-border second opinion | No |

The same train found by several sources becomes one entry: every price, DB's realtime and platforms, Transitous' exact route.

## Features

- **Map first**: the map is the home screen; search and results live in a bottom sheet you drag up (phones) or a side panel (desktop/tablet). All connections are drawn on the map, the selected one solid, the others faded – tap a faded one to select it.
- **Train colours**: every train family has a base colour (ICE red, IC orange, RE blue, RB teal, S-Bahn green, FlixTrain lime, Nightjet indigo, …) and every line gets its own shade of it, so two REs in one trip are easy to tell apart. Legend in Settings.
- **Minimum transfer time (Umstiegszeit)**: 0–30 min, sent to DB, ÖBB and Transitous; shorter transfers are flagged or hidden. Also max. transfers.
- **Transfer check**: every change shows how many minutes you have (after walking) and warns when it is tight or already missed because of delays.
- **Live tracking**: pin a connection, it refreshes on its own and warns about delays, cancellations and transfers that break. Alternatives are searched from where you are (next stop, or the station you're changing at), compared with your plan, and one tap switches the trip to them.
- **Live notification** (Android): next train, platform, arrival and change with a countdown, kept up to date with the screen off; changes found in the background come as a notification.
- **Tricks**: split tickets (also staying on the same train), D-Ticket to a later ICE stop, a better start/end station for addresses – shown only when clearly cheaper.
- **Favourites and recents**: one-tap routes, recent stations, "my location" for the nearest station.
- **Tickets**: BahnCard 25/50/100, 1st class, age, Deutschlandticket (0 € or D-Ticket-only), bike, long-distance buses.
- **Reliability**: results stream in per source, retries with backoff, per-source circuit breaker (e.g. when DB blocks a network), in-memory caching, offline copy of the last search, sanity check against wrong-day results.
- German and English, light/dark mode, sort by best/fastest/cheapest/earliest/fewest changes, earlier/later, copy a trip as text.

## Run

Requires Flutter 3.47+.

```sh
flutter pub get
flutter run            # pick a device: android, linux, macos, ios, chrome
```

### Web

Browsers may not call DB and ÖBB directly (CORS). Transitous and Flix work as-is. For DB/ÖBB start the bundled proxy (it only forwards to those two hosts):

```sh
dart run tool/cors_proxy.dart          # http://localhost:8787/
```

and enter `http://localhost:8787/` under Settings → Web proxy.

## Tests

```sh
flutter test                               # unit tests on recorded API responses
flutter test --tags live --run-skipped     # hits the real APIs
```

## CI

`.github/workflows/ci.yml` analyzes, tests and builds on every push and PR (Android, Linux, Web; iOS/macOS on tags). It can also be started by hand under **Actions → CI → Run workflow**: choose which platforms to build and whether to run the live API tests. The Flutter SDK, pub, Gradle and CocoaPods are cached, and newer pushes cancel older runs.

## Structure

```
lib/
  sources/        db.dart, transitous.dart, flix.dart, oebb.dart – one file per API, all return the common format
  models/         journey.dart (Journey/Leg/Transfer), settings.dart
  services/       search.dart (parallel fan-out, streaming), merge.dart (dedupe + ranking), store.dart (persistence)
  core/           net.dart (timeouts, retries, circuit breaker, cache), util.dart
  ui/             screens/, widgets/, line_colors.dart, strings.dart (DE/EN)
tool/cors_proxy.dart
```

Adding a source = one class implementing `Source.journeys(from, to, opts)` plus an entry in `services/search.dart`.

## Caveats

- Only Transitous is an official public API. DB is rate-limited and sometimes blocks whole networks (the app pauses it and keeps working with the rest); Flix and ÖBB may change without notice.
- DB prices are the cheapest fare for that connection; the final price is on bahn.de.
- Please respect the [Transitous usage policy](https://transitous.org/api/) and the [OSM tile policy](https://operations.osmfoundation.org/policies/tiles/).
