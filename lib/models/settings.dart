// User preferences. Persisted as JSON; unknown/missing keys fall back to defaults,
// so adding a setting never breaks an existing install.

enum AppLanguage { de, en }

enum SortMode { best, fast, cheap, early, transfers }

const allSources = ['db', 'transitous', 'flix', 'oebb'];

class Settings {
  /// Minimum transfer time (Umstiegszeit) in minutes. 0 = let each operator decide.
  final int minTransferMinutes;

  /// Hide connections whose transfers are shorter than [minTransferMinutes]
  /// (instead of only flagging them).
  final bool hideTightTransfers;

  /// null = unlimited.
  final int? maxTransfers;

  final int bahncard; // 0, 25, 50, 100
  final bool firstClass;
  final bool dticket;
  final bool dticketOnly;
  final bool bike;
  final bool coach;
  final int? age;

  final List<String> sources;
  final SortMode defaultSort;

  /// 0 = system, 1 = light, 2 = dark
  final int themeMode;
  final AppLanguage language;

  /// Web builds only: CORS proxy prefix for DB/ÖBB, e.g. http://localhost:8787/
  final String webProxy;

  /// Auto-refresh interval for a tracked journey, in seconds.
  final int trackRefreshSeconds;

  const Settings({
    this.minTransferMinutes = 0,
    this.hideTightTransfers = false,
    this.maxTransfers,
    this.bahncard = 0,
    this.firstClass = false,
    this.dticket = false,
    this.dticketOnly = false,
    this.bike = false,
    this.coach = false,
    this.age,
    this.sources = allSources,
    this.defaultSort = SortMode.best,
    this.themeMode = 0,
    this.language = AppLanguage.de,
    this.webProxy = '',
    this.trackRefreshSeconds = 60,
  });

  Settings copyWith({
    int? minTransferMinutes,
    bool? hideTightTransfers,
    int? Function()? maxTransfers,
    int? bahncard,
    bool? firstClass,
    bool? dticket,
    bool? dticketOnly,
    bool? bike,
    bool? coach,
    int? Function()? age,
    List<String>? sources,
    SortMode? defaultSort,
    int? themeMode,
    AppLanguage? language,
    String? webProxy,
    int? trackRefreshSeconds,
  }) => Settings(
    minTransferMinutes: minTransferMinutes ?? this.minTransferMinutes,
    hideTightTransfers: hideTightTransfers ?? this.hideTightTransfers,
    maxTransfers: maxTransfers != null ? maxTransfers() : this.maxTransfers,
    bahncard: bahncard ?? this.bahncard,
    firstClass: firstClass ?? this.firstClass,
    dticket: dticket ?? this.dticket,
    dticketOnly: dticketOnly ?? this.dticketOnly,
    bike: bike ?? this.bike,
    coach: coach ?? this.coach,
    age: age != null ? age() : this.age,
    sources: sources ?? this.sources,
    defaultSort: defaultSort ?? this.defaultSort,
    themeMode: themeMode ?? this.themeMode,
    language: language ?? this.language,
    webProxy: webProxy ?? this.webProxy,
    trackRefreshSeconds: trackRefreshSeconds ?? this.trackRefreshSeconds,
  );

  Map<String, dynamic> toJson() => {
    'minTransferMinutes': minTransferMinutes,
    'hideTightTransfers': hideTightTransfers,
    'maxTransfers': maxTransfers,
    'bahncard': bahncard,
    'firstClass': firstClass,
    'dticket': dticket,
    'dticketOnly': dticketOnly,
    'bike': bike,
    'coach': coach,
    'age': age,
    'sources': sources,
    'defaultSort': defaultSort.name,
    'themeMode': themeMode,
    'language': language.name,
    'webProxy': webProxy,
    'trackRefreshSeconds': trackRefreshSeconds,
  };

  factory Settings.fromJson(Map<String, dynamic> j) {
    const d = Settings();
    T pick<T>(String k, T fallback) => j[k] is T ? j[k] as T : fallback;
    return Settings(
      minTransferMinutes: pick('minTransferMinutes', d.minTransferMinutes).clamp(0, 60),
      hideTightTransfers: pick('hideTightTransfers', d.hideTightTransfers),
      maxTransfers: j['maxTransfers'] is int ? j['maxTransfers'] as int : null,
      bahncard: pick('bahncard', d.bahncard),
      firstClass: pick('firstClass', d.firstClass),
      dticket: pick('dticket', d.dticket),
      dticketOnly: pick('dticketOnly', d.dticketOnly),
      bike: pick('bike', d.bike),
      coach: pick('coach', d.coach),
      age: j['age'] is int ? j['age'] as int : null,
      sources: j['sources'] is List ? (j['sources'] as List).whereType<String>().where(allSources.contains).toList() : d.sources,
      defaultSort: SortMode.values.firstWhere((s) => s.name == j['defaultSort'], orElse: () => d.defaultSort),
      themeMode: pick('themeMode', d.themeMode),
      language: AppLanguage.values.firstWhere((s) => s.name == j['language'], orElse: () => d.language),
      webProxy: pick('webProxy', d.webProxy),
      trackRefreshSeconds: pick('trackRefreshSeconds', d.trackRefreshSeconds).clamp(30, 600),
    );
  }
}
