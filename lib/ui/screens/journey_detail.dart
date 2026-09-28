import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/journey.dart';
import '../../services/store.dart';
import '../app_scope.dart';
import '../strings.dart';
import '../widgets/journey_card.dart';
import '../widgets/leg_list.dart';
import '../widgets/route_map.dart';
import 'tracking.dart';

String journeyAsText(Journey j, S s) {
  final b = StringBuffer(
    '${fmtDate(j.departure, s.de)} · ${fmtDur(j.duration)} · ${j.transfers == 0 ? s.direct : s.changes(j.transfers)}\n',
  );
  for (final l in j.legs.where((l) => !l.isWalk)) {
    b.writeln('${fmtTime(l.dep)} ${l.from.name}${l.depPlatform != null ? ' (${s.platform(l.depPlatform!)})' : ''}');
    b.writeln('   ${l.line}${l.direction.isNotEmpty ? ' → ${l.direction}' : ''}');
    b.writeln('${fmtTime(l.arr)} ${l.to.name}${l.arrPlatform != null ? ' (${s.platform(l.arrPlatform!)})' : ''}');
  }
  final p = j.bestPrice;
  if (p != null) b.writeln(fmtEur(p.amount));
  return b.toString().trim();
}

List<Widget> bookingButtons(BuildContext context, Journey j) {
  final s = context.s;
  final flix = j.prices.where((p) => p.source == 'flix').map((p) => p.url).whereType<String>().firstOrNull ?? j.bookingUrls['flix'];
  final db = j.bookingUrls['db'];
  final oebb = j.bookingUrls['oebb'];
  Future<void> open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  return [
    if (flix != null)
      FilledButton.icon(icon: const Icon(Icons.confirmation_number_outlined), label: Text(s.bookFlix), onPressed: () => open(flix)),
    if (db != null)
      (flix == null ? FilledButton.icon : OutlinedButton.icon)(
        icon: const Icon(Icons.open_in_new),
        label: Text(s.openBahn),
        onPressed: () => open(db),
      ),
    if (oebb != null && db == null)
      OutlinedButton.icon(icon: const Icon(Icons.open_in_new), label: Text(s.oebbTickets), onPressed: () => open(oebb)),
  ];
}

class JourneyDetailScreen extends StatelessWidget {
  final Journey journey;
  final SavedRoute route;
  const JourneyDetailScreen({super.key, required this.journey, required this.route});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final store = context.store;
    final j = journey;
    final t = Theme.of(context).textTheme;
    final saved = store.isSaved(j);

    return Scaffold(
      appBar: AppBar(
        title: Text('${fmtTime(j.departure)} – ${fmtTime(j.arrival)}'),
        actions: [
          IconButton(
            tooltip: s.share,
            icon: const Icon(Icons.copy_all),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: journeyAsText(j, s)));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.copied)));
            },
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 900;
          final details = ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${fmtDur(j.duration)} · ${j.transfers == 0 ? s.direct : s.changes(j.transfers)} · ${fmtDate(j.departure, s.de)}',
                      style: t.titleMedium,
                    ),
                  ),
                  PriceView(journey: j, dticket: store.settings.dticket),
                ],
              ),
              const SizedBox(height: 10),
              JourneyStrip(journey: j, detailed: true),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: journeyTags(context, j, minTransfer: store.settings.minTransferMinutes, showDominated: false),
              ),
              if (!wide) ...[const SizedBox(height: 16), SizedBox(height: 260, child: RouteMap(journey: j))],
              const SizedBox(height: 12),
              LegList(journey: j),
              const SizedBox(height: 16),
              if (j.prices.length > 1) ...[
                Text(s.offers(j.prices.length), style: t.titleSmall),
                for (final p in j.prices)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${s.sourceLabel(p.source)}${p.partial ? (s.de ? ' (Teilpreis)' : ' (partial fare)') : ''}'),
                    trailing: Text(fmtEur(p.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
                    onTap: p.url == null ? null : () => launchUrl(Uri.parse(p.url!), mode: LaunchMode.externalApplication),
                  ),
                const SizedBox(height: 8),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ...bookingButtons(context, j),
                  FilledButton.tonalIcon(
                    icon: Icon(saved ? Icons.bookmark : Icons.bookmark_add_outlined),
                    label: Text(saved ? (s.de ? 'Gespeichert – öffnen' : 'Saved – open') : (s.de ? 'Reise speichern' : 'Save trip')),
                    onPressed: () {
                      final t = store.saveTrip(j, route);
                      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => TripScreen(tripId: t.id)));
                    },
                  ),
                ],
              ),
            ],
          );
          if (!wide) return details;
          return Row(
            children: [
              SizedBox(width: 520, child: details),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 16, 16),
                  child: RouteMap(journey: j),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
