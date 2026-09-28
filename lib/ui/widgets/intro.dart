import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../line_colors.dart';

/// Short introduction: how the map reads (line styles, colours), the sheet, saved trips and offline mode.
Future<void> showIntro(BuildContext context, {int page = 0}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _Intro(initialPage: page),
  );
}

/// Just the map legend (line styles + colours).
Future<void> showMapLegend(BuildContext context) => showIntro(context, page: 1);

class _Intro extends StatefulWidget {
  final int initialPage;
  const _Intro({this.initialPage = 0});

  @override
  State<_Intro> createState() => _IntroState();
}

class _IntroState extends State<_Intro> {
  late final _ctrl = PageController(initialPage: widget.initialPage);
  late int _page = widget.initialPage;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final pages = [_welcome(context), _legend(context), _trips(context)];
    final last = _page == pages.length - 1;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(
          children: [
            Expanded(
              child: PageView(controller: _ctrl, onPageChanged: (p) => setState(() => _page = p), children: pages),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  for (var i = 0; i < pages.length; i++)
                    Container(
                      width: i == _page ? 18 : 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: i == _page ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () =>
                        last ? Navigator.pop(context) : _ctrl.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
                    child: Text(last ? (s.de ? 'Los geht’s' : 'Let’s go') : (s.de ? 'Weiter' : 'Next')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _page0(String title, List<Widget> children) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
    children: [
      Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 16),
      ...children,
    ],
  );

  Widget _point(IconData icon, String title, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(text),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _welcome(BuildContext context) {
    final s = context.s;
    return _page0(s.de ? 'Willkommen bei Anschluss' : 'Welcome to Anschluss', [
      _point(
        Icons.hub_outlined,
        s.de ? 'Alle Anbieter auf einmal' : 'Every operator at once',
        s.de
            ? 'DB, FlixTrain, ÖBB und alle Regionalbahnen – gleiche Züge werden zusammengeführt, mit allen Preisen.'
            : 'DB, FlixTrain, ÖBB and every regional operator – the same train is merged into one entry with all prices.',
      ),
      _point(
        Icons.swipe_up_outlined,
        s.de ? 'Karte und Suche' : 'Map and search',
        s.de
            ? 'Die Suche liegt unten im Blatt – nach oben ziehen für alle Verbindungen. Antippen zeigt sie auf der Karte, nochmal antippen öffnet die Details.'
            : 'Search lives in the sheet at the bottom – drag it up for all connections. Tap one to see it on the map, tap again for details.',
      ),
      _point(
        Icons.touch_app_outlined,
        s.de ? 'Auf der Karte wählen' : 'Pick on the map',
        s.de
            ? 'Alle gefundenen Verbindungen sind blass eingezeichnet – tippe eine Linie an, um sie auszuwählen.'
            : 'All connections found are drawn faded – tap a line to select it.',
      ),
    ]);
  }

  Widget _legend(BuildContext context) {
    final s = context.s;
    final b = Theme.of(context).brightness;
    final ice = familyColor(families.firstWhere((f) => f.key == 'ice'), b);
    Widget sample(Widget line, String title, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 56, height: 20, child: Center(child: line)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(text),
              ],
            ),
          ),
        ],
      ),
    );
    return _page0(s.de ? 'Die Karte lesen' : 'Reading the map', [
      sample(
        _Line(color: ice),
        s.de ? 'Durchgezogen' : 'Solid',
        s.de ? 'Der echte Streckenverlauf auf den Gleisen.' : 'The real route along the tracks.',
      ),
      sample(
        _Line(color: ice, dash: 10, gap: 6),
        s.de ? 'Gestrichelt' : 'Dashed',
        s.de
            ? 'Streckenverlauf unbekannt (z.B. offline oder Flix) – gerade Linien zwischen den Halten. Wird ersetzt, sobald der Verlauf geladen ist.'
            : 'Exact route unknown (e.g. offline or Flix) – straight lines between the stops. Replaced as soon as the route is loaded.',
      ),
      sample(
        _Line(color: Colors.grey, dash: 3, gap: 5, width: 3),
        s.de ? 'Gepunktet' : 'Dotted',
        s.de
            ? 'Fußweg – zum Bahnhof, zwischen Bahnhöfen oder komplett zu Fuß.'
            : 'Walking – to the station, between stations or the whole way.',
      ),
      sample(
        _Line(color: ice.withValues(alpha: 0.3)),
        s.de ? 'Blass' : 'Faded',
        s.de ? 'Andere gefundene Verbindungen. Antippen wählt sie aus.' : 'Other connections found. Tap to select.',
      ),
      const SizedBox(height: 4),
      Text(s.de ? 'Farben' : 'Colours', style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(
        s.de
            ? 'Jede Zugart hat eine Grundfarbe, jede Linie eine eigene Schattierung davon – zwei REs in einer Reise sind so leicht zu unterscheiden.'
            : 'Each type of train has a base colour, each line its own shade of it – two REs in one trip are easy to tell apart.',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final f in families.where((f) => f.key != 'walk' && f.key != 'other'))
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: CircleAvatar(backgroundColor: familyColor(f, b)),
              label: Text(f.label, style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    ]);
  }

  Widget _trips(BuildContext context) {
    final s = context.s;
    return _page0(s.de ? 'Unterwegs' : 'On the go', [
      _point(
        Icons.bookmark_add_outlined,
        s.de ? 'Reisen speichern' : 'Save trips',
        s.de
            ? 'Gespeicherte Reisen liegen auf dem Gerät, zeigen wo du gerade bist und werden unterwegs aktualisiert (Verspätungen, Gleiswechsel).'
            : 'Saved trips live on your device, show where you are and update on the go (delays, platform changes).',
      ),
      _point(
        Icons.cloud_off_outlined,
        s.de ? 'Ohne Netz' : 'Without network',
        s.de
            ? 'Lade in den Einstellungen den Offline-Fahrplan (~12 MB): dann plant die App auch ohne mobile Daten – mit planmäßigen Zeiten.'
            : 'Download the offline timetable in Settings (~12 MB): the app then plans without mobile data – with scheduled times.',
      ),
      _point(
        Icons.tune,
        s.de ? 'Deine Einstellungen' : 'Your settings',
        s.de
            ? 'Umstiegszeit, BahnCard, Deutschlandticket, Fußwege und mehr unter Einstellungen.'
            : 'Transfer time, BahnCard, Deutschlandticket, walking and more in Settings.',
      ),
    ]);
  }
}

class _Line extends StatelessWidget {
  final Color color;
  final double dash, gap, width;
  const _Line({required this.color, this.dash = 0, this.gap = 0, this.width = 5});

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(56, 8), painter: _LinePainter(color, dash, gap, width));
}

class _LinePainter extends CustomPainter {
  final Color color;
  final double dash, gap, width;
  _LinePainter(this.color, this.dash, this.gap, this.width);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (dash == 0) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
      return;
    }
    for (var x = 0.0; x < size.width; x += dash + gap) {
      canvas.drawLine(Offset(x, y), Offset((x + dash).clamp(0, size.width), y), p);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.color != color || old.dash != dash;
}
