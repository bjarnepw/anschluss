import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/net.dart';
import '../../models/settings.dart';
import '../app_scope.dart';
import '../line_colors.dart';

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
          ListTile(
            title: Text(s.theme),
            trailing: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 0, label: Text(s.system)),
                ButtonSegment(value: 1, label: Text(s.light)),
                ButtonSegment(value: 2, label: Text(s.dark)),
              ],
              selected: {st.themeMode},
              onSelectionChanged: (v) => set(st.copyWith(themeMode: v.first)),
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
        ],
      ),
    );
  }
}
