// UI strings in German and English. Kept in one small table instead of ARB code generation.
import '../models/journey.dart';
import '../models/settings.dart';

class S {
  final AppLanguage lang;
  const S(this.lang);

  bool get de => lang == AppLanguage.de;
  String _(String de, String en) => this.de ? de : en;

  String get appTagline =>
      _('DB, FlixTrain, ÖBB und alle Regionalbahnen in einer Suche.', 'DB, FlixTrain, ÖBB and every regional operator in one search.');
  String get from => _('Von', 'From');
  String get to => _('Nach', 'To');
  String get stationHint => _('Bahnhof oder Stadt', 'Station or city');
  String get swap => _('Tauschen', 'Swap');
  String get depart => _('Ab', 'Depart');
  String get arrive => _('An', 'Arrive');
  String get now => _('Jetzt', 'Now');
  String get search => _('Verbindungen suchen', 'Find connections');
  String get searching => _('Suche bei allen Anbietern…', 'Searching all operators…');
  String get earlier => _('Früher', 'Earlier');
  String get later => _('Später', 'Later');
  String get settings => _('Einstellungen', 'Settings');
  String get favorites => _('Favoriten', 'Favourites');
  String get recent => _('Zuletzt', 'Recent');
  String get clear => _('Leeren', 'Clear');
  String get myLocation => _('Mein Standort', 'My location');
  String get locating => _('Standort wird ermittelt…', 'Finding your location…');
  String get noLocation => _('Standort nicht verfügbar', 'Location unavailable');
  String get pickStations => _('Bitte Start und Ziel wählen.', 'Choose a start and a destination.');
  String get noResults => _(
    'Keine Verbindung gefunden. Andere Zeit probieren, Fernbusse einschalten oder Bahnhöfe aus den Vorschlägen wählen.',
    'No connection found. Try another time, turn on long-distance buses, or pick stations from the suggestions.',
  );
  String get someSourcesFailed => _('Einige Quellen haben nicht geantwortet.', 'Some sources did not answer.');
  String get retry => _('Erneut versuchen', 'Retry');
  String offline(String ago) => _('Offline – gespeicherte Ergebnisse von $ago', 'Offline – saved results from $ago');
  String get direct => _('Direkt', 'Direct');
  String changes(int n) => de ? '$n× Umstieg' : '$n change${n == 1 ? '' : 's'}';
  String get noPrice => _('kein Preis', 'no price');
  String get partPrice => _('Teilpreis', 'part price');
  String onlyFor(String trains) => _('nur $trains', 'only $trains');
  String paidRestDticket(String trains) => _('$trains · Rest D-Ticket', '$trains · rest D-Ticket');
  String get withDticket => _('mit Deutschlandticket', 'with Deutschlandticket');
  String offers(int n) => de ? '$n Angebote' : '$n offers';
  String get fastest => _('Schnellste', 'Fastest');
  String get cheapest => _('Günstigste', 'Cheapest');
  String get bestOverall => _('Beste', 'Best overall');
  String get cancelled => _('Fällt aus', 'Cancelled');
  String get soldOut => _('Ausgebucht', 'Sold out');
  String get beaten => _('Andere Option ist besser', 'Another option beats this');
  String tightTransfer(int m) => de ? 'Knapper Umstieg: $m min' : 'Tight transfer: $m min';
  String get missedTransfer => _('Anschluss gefährdet', 'Connection at risk');
  String get walk => _('Fußweg', 'Walk');
  String walkMin(int m, double? dist) => de
      ? 'Fußweg $m min${dist != null && dist > 0 ? ', ${dist.round()} m' : ''}'
      : 'Walk $m min${dist != null && dist > 0 ? ', ${dist.round()} m' : ''}';
  String transfer(int m, int walk) =>
      de ? 'Umstieg $m min${walk > 0 ? ' · $walk min Fußweg' : ''}' : 'Change $m min${walk > 0 ? ' · $walk min walk' : ''}';
  String towards(String d) => de ? 'Richtung $d' : 'towards $d';
  String platform(String p) => de ? 'Gl. $p' : 'Pl. $p';
  String stopsBetween(int n) => de ? '$n Zwischenhalt${n == 1 ? '' : 'e'}' : '$n stop${n == 1 ? '' : 's'} in between';
  String get onTime => _('pünktlich', 'on time');
  String get book => _('Buchen', 'Book');
  String get bookFlix => _('Bei Flix buchen', 'Book at Flix');
  String get openBahn => _('Auf bahn.de öffnen', 'Open on bahn.de');
  String get openBahn2 => _('2. Ticket auf bahn.de', '2nd ticket on bahn.de');
  String trick(Trick t, String Function(double) eur) {
    final what = switch (t.kind) {
      'split' => _('2 Tickets, geteilt in ${t.at}', 'Split ticket at ${t.at}'),
      'dticket' => _('D-Ticket bis ${t.at}', 'D-Ticket to ${t.at}'),
      'start' => _('Start: ${t.at}', 'Start at ${t.at}'),
      _ => _('Ziel: ${t.at}', 'End at ${t.at}'),
    };
    final saves = t.saves;
    return saves == null || saves <= 0 ? what : '$what · ${_('${eur(saves)} günstiger', '${eur(saves)} cheaper')}';
  }

  String get oebbTickets => _('ÖBB-Tickets', 'ÖBB tickets');
  String get track => _('Verfolgen', 'Track');
  String get stopTracking => _('Nicht mehr verfolgen', 'Stop tracking');
  String get tracking => _('Deine Reise', 'Your trip');
  String updated(String t) => de ? 'Aktualisiert $t' : 'Updated $t';
  String get notFoundAnymore => _(
    'Verbindung nicht mehr gefunden – evtl. ausgefallen. Alternativen suchen?',
    'Connection not found anymore – it may be cancelled. Look for alternatives?',
  );
  String get alternatives => _('Alternativen', 'Alternatives');
  String get modes => _('Verkehrsmittel', 'Train types');
  String modeGroup(String g) => switch (g) {
    'long' => _('Fernverkehr (ICE, IC/EC, Nachtzug)', 'Long distance (ICE, IC/EC, night)'),
    'regional' => _('Regionalverkehr (RE, RB)', 'Regional (RE, RB)'),
    'suburban' => 'S-Bahn',
    'metro' => _('U-Bahn und Tram', 'Metro and tram'),
    _ => _('Bus und Fähre', 'Bus and ferry'),
  };
  String vsPlan(int min) => min < -1
      ? _('${-min} min früher als dein Plan', '${-min} min earlier than your plan')
      : min > 1
      ? _('$min min später als dein Plan', '$min min later than your plan')
      : _('Ankunft wie dein Plan', 'Arrives like your plan');
  String get takeThis => _('Diese nehmen', 'Take this');
  String get switched => _('Reise auf die Alternative umgestellt', 'Trip switched to the alternative');
  String switchedLog(String line, String time) => _('Umgestiegen auf $line ab $time', 'Switched to $line at $time');
  String get undo => _('Rückgängig', 'Undo');
  String cancelledAhead(String line) => _('$line fällt aus.', '$line is cancelled.');
  String get share => _('Teilen', 'Share');
  String get copied => _('In die Zwischenablage kopiert', 'Copied to clipboard');
  String get map => _('Karte', 'Map');
  String get details => _('Details', 'Details');
  String get sort => _('Sortieren', 'Sort');
  String sortName(SortMode m) => switch (m) {
    SortMode.best => _('Beste', 'Best'),
    SortMode.fast => _('Schnellste', 'Fastest'),
    SortMode.cheap => _('Günstigste', 'Cheapest'),
    SortMode.early => _('Früheste Ankunft', 'Earliest arrival'),
    SortMode.transfers => _('Wenigste Umstiege', 'Fewest changes'),
  };
  String get addFavorite => _('Als Favorit speichern', 'Save as favourite');
  String get removeFavorite => _('Favorit entfernen', 'Remove favourite');

  // Settings
  String get transfers => _('Umstiege', 'Transfers');
  String get minTransfer => _('Mindest-Umstiegszeit', 'Minimum transfer time');
  String minTransferValue(int m) => m == 0 ? _('Automatisch (Anbieter)', 'Automatic (operator)') : '$m min';
  String get minTransferHelp => _(
    'Gilt für DB, ÖBB und Transitous. Kürzere Umstiege werden markiert.',
    'Applies to DB, ÖBB and Transitous. Shorter transfers are flagged.',
  );
  String get hideTight => _('Kürzere Umstiege ausblenden', 'Hide shorter transfers');
  String get maxTransfers => _('Maximale Umstiege', 'Maximum transfers');
  String get unlimited => _('Beliebig', 'Any');
  String get tickets => _('Tickets & Preise', 'Tickets & prices');
  String get bahncard => 'BahnCard';
  String get none => _('Keine', 'None');
  String get firstClass => _('1. Klasse', '1st class');
  String get dticket => _('Ich habe ein Deutschlandticket', 'I have a Deutschlandticket');
  String get dticketOnly => _('Nur Deutschlandticket-Verbindungen', 'Deutschlandticket connections only');
  String get age => _('Alter (für Preise)', 'Age (for prices)');
  String get adult => _('Erwachsen', 'Adult');
  String get travel => _('Reise', 'Travel');
  String get bike => _('Fahrradmitnahme', 'Bringing a bike');
  String get coach => _('Fernbusse einbeziehen', 'Include long-distance buses');
  String get sources => _('Datenquellen', 'Data sources');
  String get appearance => _('Darstellung', 'Appearance');
  String get theme => _('Design', 'Theme');
  String get system => 'System';
  String get light => _('Hell', 'Light');
  String get dark => _('Dunkel', 'Dark');
  String get language => _('Sprache', 'Language');
  String get defaultSort => _('Standard-Sortierung', 'Default sort');
  String get liveTracking => _('Live-Verfolgung', 'Live tracking');
  String refreshEvery(int s) => de
      ? 'Aktualisieren alle ${s ~/ 60 > 0 && s % 60 == 0 ? '${s ~/ 60} min' : '$s s'}'
      : 'Refresh every ${s ~/ 60 > 0 && s % 60 == 0 ? '${s ~/ 60} min' : '$s s'}';
  String get advanced => _('Erweitert', 'Advanced');
  String get webProxy => _('Web-Proxy (nur Web-Version)', 'Web proxy (web version only)');
  String get webProxyHelp => _(
    'Browser dürfen DB und ÖBB nicht direkt abfragen. Starte tool/cors_proxy.dart und trage z.B. http://localhost:8787/ ein.',
    'Browsers may not call DB and ÖBB directly. Run tool/cors_proxy.dart and enter e.g. http://localhost:8787/.',
  );
  String get resetSources => _('Pausierte Quellen zurücksetzen', 'Reset paused sources');
  String get clearHistory => _('Verlauf löschen', 'Clear history');
  String get legend => _('Farblegende', 'Colour legend');
  String sourceLabel(String id) => switch (id) {
    'db' => 'DB',
    'transitous' => 'Transitous',
    'flix' => 'Flix',
    'oebb' => 'ÖBB',
    'flixcombo' => _('Flix-Kombi', 'Flix combos'),
    'trick' => _('Tricks', 'Tricks'),
    'regiojet' => 'RegioJet',
    'offline' => 'Offline',
    'walk' => _('Zu Fuß', 'Walk'),
    _ => id,
  };
  String sourceDesc(String id) => switch (id) {
    'db' => _('ICE/IC, Regionalverkehr, Echtzeit, Preise', 'ICE/IC, regional trains, realtime, prices'),
    'transitous' => _('Offene Fahrplandaten, exakte Strecken', 'Open timetable data, exact routes'),
    'flix' => _('FlixTrain mit Preisen', 'FlixTrain with prices'),
    'oebb' => _('Nightjet, Österreich, grenzüberschreitend', 'Nightjet, Austria, cross-border'),
    'regiojet' => _(
      'Tschechien, Slowakei, Wien – Preise in Kronen, umgerechnet in €',
      'Czechia, Slovakia, Vienna – fares in CZK, converted to €',
    ),
    _ => '',
  };
  String found(int n) => de ? '$n gefunden' : '$n found';
  String sourcesSummary(int sources, int connections) =>
      de ? '$sources Quellen · $connections Verbindungen' : '$sources sources · $connections connections';
  String get loading => _('lädt…', 'loading…');
}
