import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/net.dart';
import '../../models/settings.dart';
import '../app_scope.dart';
import '../../core/tiles/tile_cache.dart';
import '../../offline/offline_pack.dart';
import '../line_colors.dart';
import '../widgets/route_map.dart';
import '../widgets/intro.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final st = store.settings;
    final s = context.s;
    final t = Theme.of(context).textTheme;
    void set(Settings n) => store.updateSettings(n);

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Text(
        text,
        style: t.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(s.settings)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // ---------- transfers ----------
          header(s.transfers),
          ListTile(
            title: Text(s.minTransfer),
            subtitle: Text(s.minTransferHelp),
            trailing: Text(s.minTransferValue(st.minTransferMinutes), style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Slider(
              value: st.minTransferMinutes.toDouble(),
              min: 0,
              max: 30,
              divisions: 30,
              label: s.minTransferValue(st.minTransferMinutes),
              onChanged: (v) => set(st.copyWith(minTransferMinutes: v.round())),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final m in [0, 5, 10, 15, 20])
                  ChoiceChip(
                    label: Text(m == 0 ? 'Auto' : '$m min'),
                    selected: st.minTransferMinutes == m,
                    onSelected: (_) => set(st.copyWith(minTransferMinutes: m)),
                  ),
              ],
            ),
          ),
          SwitchListTile(
            title: Text(s.hideTight),
            value: st.hideTightTransfers,
            onChanged: st.minTransferMinutes == 0 ? null : (v) => set(st.copyWith(hideTightTransfers: v)),
          ),
          ListTile(
            title: Text(s.maxTransfers),
            trailing: DropdownButton<int?>(
              value: st.maxTransfers,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(value: null, child: Text(s.unlimited)),
                for (final n in [0, 1, 2, 3, 4, 5]) DropdownMenuItem(value: n, child: Text(n == 0 ? s.direct : '$n')),
              ],
              onChanged: (v) => set(st.copyWith(maxTransfers: () => v)),
            ),
          ),

          // ---------- tickets ----------
          header(s.tickets),
          ListTile(
            title: Text(s.bahncard),
            trailing: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 0, label: Text(s.none)),
                const ButtonSegment(value: 25, label: Text('25')),
                const ButtonSegment(value: 50, label: Text('50')),
                const ButtonSegment(value: 100, label: Text('100')),
              ],
              selected: {st.bahncard},
              onSelectionChanged: (v) => set(st.copyWith(bahncard: v.first)),
            ),
          ),
          SwitchListTile(
            title: Text(s.firstClass),
            value: st.firstClass,
            onChanged: (v) => set(st.copyWith(firstClass: v)),
          ),
          SwitchListTile(
            title: Text(s.dticket),
            value: st.dticket,
            onChanged: (v) => set(st.copyWith(dticket: v)),
          ),
          SwitchListTile(
            title: Text(s.dticketOnly),
            value: st.dticketOnly,
            onChanged: (v) => set(st.copyWith(dticketOnly: v)),
          ),
          ListTile(
            title: Text(s.age),
            trailing: DropdownButton<int?>(
              value: st.age,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(value: null, child: Text(s.adult)),
                for (final a in [5, 10, 14, 18, 22, 26, 30, 45, 65, 70]) DropdownMenuItem(value: a, child: Text('$a')),
              ],
              onChanged: (v) => set(st.copyWith(age: () => v)),
            ),
          ),

          // ---------- travel ----------
          header(s.travel),
          SwitchListTile(
            title: Text(s.bike),
            secondary: const Icon(Icons.pedal_bike),
            value: st.bike,
            onChanged: (v) => set(st.copyWith(bike: v)),
          ),
          SwitchListTile(
            title: Text(s.coach),
            secondary: const Icon(Icons.directions_bus),
            value: st.coach,
            onChanged: (v) => set(st.copyWith(coach: v)),
          ),
          ListTile(
            leading: const Icon(Icons.directions_walk),
            title: Text(s.de ? 'Max. Fußweg zum/vom Bahnhof' : 'Max. walk to/from stations'),
            trailing: Text('${st.maxWalkMinutes} min', style: t.titleSmall),
            subtitle: Slider(
              value: st.maxWalkMinutes.toDouble(),
              min: 5,
              max: 40,
              divisions: 7,
              label: '${st.maxWalkMinutes} min',
              onChanged: (v) => set(st.copyWith(maxWalkMinutes: v.round())),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.hiking),
            title: Text(s.de ? 'Komplett zu Fuß anzeigen, wenn schneller' : 'Show walking the whole way when faster'),
            value: st.includeWalking,
            onChanged: (v) => set(st.copyWith(includeWalking: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.alt_route),
            title: Text(s.de ? 'Mehr Alternativen suchen' : 'Search more alternatives'),
            subtitle: Text(
              s.de
                  ? 'Günstigere/langsamere DB-Verbindungen und Flix-Kombis mit Regionalzug-Zubringern (Salzwedel → RE → Hannover → FlixTrain)'
                  : 'Cheaper/slower DB routes and Flix combos with regional feeders (Salzwedel → RE → Hannover → FlixTrain)',
            ),
            value: st.moreAlternatives,
            onChanged: (v) => set(st.copyWith(moreAlternatives: v)),
          ),

          // ---------- offline ----------
          header(s.de ? 'Offline' : 'Offline'),
          const _OfflineSection(),
          SwitchListTile(
            secondary: const Icon(Icons.update),
            title: Text(s.de ? 'Offline-Fahrplan automatisch aktualisieren' : 'Update the offline timetable automatically'),
            subtitle: Text(
              s.de
                  ? 'Prüft alle 12 h, ob es einen neuen Fahrplan gibt (Baustellen, Ausfälle, Zusatzzüge), und lädt ihn dann (~12 MB).'
                  : 'Checks every 12 h for a new timetable (construction work, cancellations, extra trains) and downloads it (~12 MB).',
            ),
            value: st.autoUpdateOffline,
            onChanged: (v) => set(st.copyWith(autoUpdateOffline: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.signal_cellular_off),
            title: Text(s.de ? 'Nur offline planen' : 'Plan offline only'),
            subtitle: Text(
              s.de ? 'Keine mobilen Daten – nur der heruntergeladene Fahrplan.' : 'No mobile data – only the downloaded timetable.',
            ),
            value: st.offlineOnly,
            onChanged: OfflinePack.instance.available ? (v) => set(st.copyWith(offlineOnly: v)) : null,
          ),
          if (!kIsWeb) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextFormField(
                initialValue: st.tileUrl,
                decoration: InputDecoration(
                  labelText: s.de ? 'Eigener Kartenserver (optional)' : 'Own map tile server (optional)',
                  hintText: 'https://…/{z}/{x}/{y}.png',
                  helperText: s.de
                      ? 'Leer = OpenStreetMap. Angesehene Karten werden immer offline gespeichert; komplette Strecken vorab laden geht nur mit einem Server, der das erlaubt (z.B. mit eigenem API-Key).'
                      : 'Empty = OpenStreetMap. Viewed map areas are always kept offline; pre-downloading whole routes needs a server that allows it (e.g. with your own API key).',
                  helperMaxLines: 4,
                ),
                onChanged: (v) => set(st.copyWith(tileUrl: v.trim())),
              ),
            ),
            const _TileCacheTile(),
          ],

          // ---------- sources ----------
          header(s.sources),
          for (final id in allSources)
            CheckboxListTile(
              title: Text(s.sourceLabel(id)),
              subtitle: Text(s.sourceDesc(id)),
              value: st.sources.contains(id),
              onChanged: (v) {
                final next = [...st.sources]..remove(id);
                if (v == true) next.add(id);
                if (next.isEmpty) return; // keep at least one
                set(st.copyWith(sources: allSources.where(next.contains).toList()));
              },
            ),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: Text(s.resetSources),
            onTap: () {
              breaker.reset();
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.resetSources)));
            },
          ),

          // ---------- appearance ----------
          header(s.appearance),
          SwitchListTile(
            secondary: const Icon(Icons.brightness_auto_outlined),
            title: Text(s.de ? 'An System anpassen' : 'Follow the system'),
            subtitle: Text(s.de ? 'Hell oder dunkel wie am Handy eingestellt' : 'Light or dark like your phone'),
            value: st.themeMode == 0,
            onChanged: (v) => set(st.copyWith(themeMode: v ? 0 : (MediaQuery.platformBrightnessOf(context) == Brightness.dark ? 2 : 1))),
          ),
          if (st.themeMode != 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
              child: SegmentedButton<int>(
                segments: [
                  ButtonSegment(value: 1, icon: const Icon(Icons.light_mode_outlined), label: Text(s.light)),
                  ButtonSegment(value: 2, icon: const Icon(Icons.dark_mode_outlined), label: Text(s.dark)),
                ],
                selected: {st.themeMode},
                onSelectionChanged: (v) => set(st.copyWith(themeMode: v.first)),
              ),
            ),
          SwitchListTile(
            secondary: const Icon(Icons.contrast),
            title: const Text('AMOLED'),
            subtitle: Text(
              s.de
                  ? 'Echtes Schwarz im dunklen Design – spart Akku bei OLED-Displays'
                  : 'True black in dark mode – saves battery on OLED screens',
            ),
            value: st.amoled,
            onChanged: (v) => set(st.copyWith(amoled: v)),
          ),
          const _ColorSettings(),
          if (RouteMap.vectorSupported)
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: Text(s.de ? 'Kartenstil' : 'Map style'),
              subtitle: Text(s.de ? 'Im dunklen Design gibt es einen eigenen dunklen Stil.' : 'Dark mode uses its own dark style.'),
              trailing: DropdownButton<int>(
                value: st.mapStyle,
                underline: const SizedBox.shrink(),
                items: [
                  DropdownMenuItem(value: 0, child: Text(s.de ? 'Bunt' : 'Colourful')),
                  DropdownMenuItem(value: 1, child: Text(s.de ? 'Hell' : 'Bright')),
                  DropdownMenuItem(value: 2, child: Text(s.de ? 'Schlicht' : 'Minimal')),
                ],
                onChanged: (v) => v == null ? null : set(st.copyWith(mapStyle: v)),
              ),
            ),
          ListTile(
            title: Text(s.language),
            trailing: SegmentedButton<AppLanguage>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: AppLanguage.de, label: Text('DE')),
                ButtonSegment(value: AppLanguage.en, label: Text('EN')),
              ],
              selected: {st.language},
              onSelectionChanged: (v) => set(st.copyWith(language: v.first)),
            ),
          ),
          ListTile(
            title: Text(s.defaultSort),
            trailing: DropdownButton<SortMode>(
              value: st.defaultSort,
              underline: const SizedBox.shrink(),
              items: [for (final m in SortMode.values) DropdownMenuItem(value: m, child: Text(s.sortName(m)))],
              onChanged: (v) => v == null ? null : set(st.copyWith(defaultSort: v)),
            ),
          ),
          ExpansionTile(
            title: Text(s.legend),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final f in families.where((f) => f.key != 'walk' && f.key != 'other'))
                      Chip(
                        avatar: CircleAvatar(backgroundColor: familyColor(f, Theme.of(context).brightness)),
                        label: Text(f.label),
                      ),
                  ],
                ),
              ),
            ],
          ),

          // ---------- tracking ----------
          header(s.liveTracking),
          ListTile(
            title: Text(s.refreshEvery(st.trackRefreshSeconds)),
            subtitle: Slider(
              value: st.trackRefreshSeconds.toDouble(),
              min: 30,
              max: 300,
              divisions: 9,
              onChanged: (v) => set(st.copyWith(trackRefreshSeconds: v.round())),
            ),
          ),

          // ---------- advanced ----------
          header(s.advanced),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: Text(s.de ? 'Einführung erneut zeigen' : 'Show the introduction again'),
            onTap: () => showIntro(context),
          ),
          ListTile(leading: const Icon(Icons.delete_sweep_outlined), title: Text(s.clearHistory), onTap: store.clearRecents),
          if (kIsWeb)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextFormField(
                initialValue: st.webProxy,
                decoration: InputDecoration(labelText: s.webProxy, helperText: s.webProxyHelp, helperMaxLines: 3),
                onChanged: (v) => set(st.copyWith(webProxy: v.trim())),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              'Anschluss $appVersion',
              textAlign: TextAlign.center,
              style: t.labelMedium?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

class _OfflineSection extends StatelessWidget {
  const _OfflineSection();

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final pack = OfflinePack.instance;
    if (!pack.supported) {
      return ListTile(
        leading: const Icon(Icons.cloud_off),
        title: Text(
          s.de ? 'Offline-Fahrplan nur in der App (Android, iOS, Desktop).' : 'Offline timetable only in the app (Android, iOS, desktop).',
        ),
      );
    }
    return ListenableBuilder(
      listenable: pack,
      builder: (context, _) {
        final info = pack.info;
        final t = Theme.of(context).textTheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.de
                    ? 'Alle Fern- und Regionalzüge in Deutschland inkl. S-Bahn (~12 MB). Züge fahren nach festen Mustern, daher reicht ein Download für mehrere Wochen: ohne Netz wird dann mit planmäßigen Zeiten geplant (ohne Verspätungen und Preise). Busse, Trams und U-Bahn sind nicht enthalten.'
                    : 'All long-distance and regional trains in Germany incl. S-Bahn (~12 MB). Trains run on fixed patterns, so one download lasts several weeks: without network, trips are planned with scheduled times (no delays or prices). Buses, trams and U-Bahn are not included.',
                style: t.bodySmall,
              ),
              const SizedBox(height: 8),
              if (info != null)
                Text(
                  s.de
                      ? 'Heruntergeladen ${fmtAgo(info.downloadedAt, true)} · gültig bis ${fmtDate(info.validToDate, true)} · ${(info.bytes / 1e6).toStringAsFixed(1)} MB${pack.stale ? ' · Update empfohlen' : ''}${info.lastChecked != null ? ' · geprüft ${fmtAgo(info.lastChecked!, true)}' : ''}'
                      : 'Downloaded ${fmtAgo(info.downloadedAt, false)} · valid until ${fmtDate(info.validToDate, false)} · ${(info.bytes / 1e6).toStringAsFixed(1)} MB${pack.stale ? ' · update recommended' : ''}${info.lastChecked != null ? ' · checked ${fmtAgo(info.lastChecked!, false)}' : ''}',
                  style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              if (pack.error != null) Text(pack.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (pack.progress != null) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: pack.progress == 0 ? null : pack.progress),
                const SizedBox(height: 4),
                Text(s.de ? 'Wird geladen und aufbereitet…' : 'Downloading and preparing…', style: t.bodySmall),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    icon: Icon(info == null ? Icons.download : Icons.sync),
                    label: Text(
                      info == null ? (s.de ? 'Fahrplan herunterladen' : 'Download timetable') : (s.de ? 'Aktualisieren' : 'Update'),
                    ),
                    onPressed: pack.progress != null ? null : pack.download,
                  ),
                  if (info != null)
                    TextButton(
                      onPressed: pack.progress != null
                          ? null
                          : () async {
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                final newer = await pack.updateAvailable();
                                if (newer) {
                                  await pack.download();
                                } else {
                                  messenger.showSnackBar(
                                    SnackBar(content: Text(s.de ? 'Fahrplan ist aktuell.' : 'Timetable is up to date.')),
                                  );
                                }
                              } catch (_) {
                                messenger.showSnackBar(SnackBar(content: Text(s.de ? 'Keine Verbindung.' : 'No connection.')));
                              }
                            },
                      child: Text(s.de ? 'Nach Updates suchen' : 'Check for updates'),
                    ),
                  if (info != null)
                    TextButton(onPressed: pack.progress != null ? null : pack.delete, child: Text(s.de ? 'Löschen' : 'Delete')),
                ],
              ),
              Text(
                s.de ? 'Daten: gtfs.de / DELFI e.V., CC BY 4.0' : 'Data: gtfs.de / DELFI e.V., CC BY 4.0',
                style: t.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TileCacheTile extends StatefulWidget {
  const _TileCacheTile();

  @override
  State<_TileCacheTile> createState() => _TileCacheTileState();
}

class _TileCacheTileState extends State<_TileCacheTile> {
  late Future<int> _size = tileCacheBytes();

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return FutureBuilder<int>(
      future: _size,
      builder: (context, snap) => ListTile(
        leading: const Icon(Icons.layers_clear_outlined),
        title: Text(s.de ? 'Gespeicherte Karten löschen' : 'Delete saved map tiles'),
        subtitle: Text('${((snap.data ?? 0) / 1e6).toStringAsFixed(1)} MB'),
        onTap: () async {
          await clearTileCache();
          if (mounted) setState(() => _size = tileCacheBytes());
        },
      ),
    );
  }
}

/// Material You (system colours) or an own theme colour.
class _ColorSettings extends StatelessWidget {
  const _ColorSettings();

  static const swatches = [
    0xFF0B6E4F, // Anschluss green
    0xFF1565C0, // blue
    0xFF00838F, // teal
    0xFF6A1B9A, // purple
    0xFFAD1457, // pink
    0xFFC62828, // red
    0xFFEF6C00, // orange
    0xFFF9A825, // amber
    0xFF558B2F, // olive
    0xFF455A64, // blue grey
  ];

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final st = store.settings;
    final s = context.s;
    return DynamicColorBuilder(
      builder: (light, _) {
        final available = light != null;
        final usingSystem = st.dynamicColor && available;
        return Column(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.palette_outlined),
              title: Text(s.de ? 'Systemfarben (Material You)' : 'System colours (Material You)'),
              subtitle: Text(
                available
                    ? (s.de ? 'Farben aus deinem Hintergrundbild übernehmen' : 'Use the colours of your wallpaper')
                    : (s.de ? 'Auf diesem Gerät nicht verfügbar (ab Android 12)' : 'Not available on this device (Android 12+)'),
              ),
              value: usingSystem,
              onChanged: available ? (v) => store.updateSettings(st.copyWith(dynamicColor: v)) : null,
            ),
            if (!usingSystem)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final c in swatches)
                      Semantics(
                        label: '#${c.toRadixString(16).substring(2)}',
                        selected: st.seedColor == c,
                        button: true,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => store.updateSettings(st.copyWith(seedColor: c)),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Color(c),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: st.seedColor == c ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                                width: 3,
                              ),
                            ),
                            child: st.seedColor == c ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
