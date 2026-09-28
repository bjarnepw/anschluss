// Download, storage and loading of the offline timetable, and the "offline" search source.
// Data: gtfs.de (CC BY 4.0, data by DELFI e.V.) – long-distance + regional trains incl. S-Bahn, all of Germany.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/net.dart';
import '../models/journey.dart';
import '../sources/source.dart';
import 'router.dart';
import 'timetable.dart';

const offlineFeeds = {
  'fv': 'https://download.gtfs.de/germany/fv_free/latest.zip', // ICE, IC, EC, Nightjet (~0.5 MB)
  'rv': 'https://download.gtfs.de/germany/rv_free/latest.zip', // RE, RB, S-Bahn (~11 MB)
};

class OfflineInfo {
  final DateTime downloadedAt;
  final int validFrom, validTo, bytes;

  /// Last-Modified of each feed at download time – compared on update checks.
  final Map<String, String> versions;
  final DateTime? lastChecked;
  const OfflineInfo(this.downloadedAt, this.validFrom, this.validTo, this.bytes, {this.versions = const {}, this.lastChecked});

  OfflineInfo checkedNow() => OfflineInfo(downloadedAt, validFrom, validTo, bytes, versions: versions, lastChecked: DateTime.now());

  DateTime get validToDate => DateTime(validTo ~/ 10000, validTo ~/ 100 % 100, validTo % 100);
  bool coversDate(DateTime d) {
    final k = d.year * 10000 + d.month * 100 + d.day;
    return k >= validFrom && k <= validTo;
  }

  Map<String, dynamic> toJson() => {
    'downloadedAt': downloadedAt.toIso8601String(),
    'validFrom': validFrom,
    'validTo': validTo,
    'bytes': bytes,
    'versions': versions,
    'lastChecked': lastChecked?.toIso8601String(),
  };
  static OfflineInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final d = DateTime.tryParse(j['downloadedAt']?.toString() ?? '');
    if (d == null) return null;
    return OfflineInfo(
      d,
      j['validFrom'] as int? ?? 0,
      j['validTo'] as int? ?? 0,
      j['bytes'] as int? ?? 0,
      versions: ((j['versions'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
      lastChecked: DateTime.tryParse(j['lastChecked']?.toString() ?? ''),
    );
  }
}

Timetable _parseInIsolate(List<Uint8List> zips) => parseGtfsZips(zips);

/// Singleton: state of the offline timetable. Listen to it for download progress.
class OfflinePack extends ChangeNotifier {
  OfflinePack._();
  static final instance = OfflinePack._();

  bool get supported => !kIsWeb;

  OfflineInfo? info;
  double? progress; // 0..1 while downloading
  String? error;
  bool loading = false;

  OfflineRouter? _router;
  Future<OfflineRouter?>? _loadFuture;

  Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}/offline');
    await d.create(recursive: true);
    return d;
  }

  /// Reads the metadata on startup (cheap; the timetable itself is parsed only when needed).
  Future<void> init() async {
    if (!supported) return;
    try {
      final f = File('${(await _dir()).path}/info.json');
      if (await f.exists()) info = OfflineInfo.fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {}
    notifyListeners();
  }

  bool get available => info != null;

  Future<void> download() async {
    if (!supported || progress != null) return;
    progress = 0;
    error = null;
    notifyListeners();
    final client = HttpClient()..userAgent = userAgent;
    try {
      final dir = await _dir();
      final files = <Uint8List>[];
      final versions = <String, String>{};
      var i = 0;
      for (final entry in offlineFeeds.entries) {
        final req = await client.getUrl(Uri.parse(entry.value));
        final res = await req.close();
        if (res.statusCode != 200) throw SourceException('HTTP ${res.statusCode} from gtfs.de');
        final total = res.contentLength;
        versions[entry.key] = res.headers.value(HttpHeaders.lastModifiedHeader) ?? '';
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in res) {
          bytes.add(chunk);
          if (total > 0) {
            progress = (i + bytes.length / total) / offlineFeeds.length;
            notifyListeners();
          }
        }
        final data = bytes.takeBytes();
        await File('${dir.path}/${entry.key}.zip.part').writeAsBytes(data, flush: true);
        files.add(data);
        i++;
      }
      // Parse once to validate the download and learn the validity period.
      final tt = await compute(_parseInIsolate, files);
      for (final k in offlineFeeds.keys) {
        await File('${dir.path}/$k.zip.part').rename('${dir.path}/$k.zip');
      }
      info = OfflineInfo(
        DateTime.now(),
        tt.validFrom,
        tt.validTo,
        files.fold(0, (a, b) => a + b.length),
        versions: versions,
        lastChecked: DateTime.now(),
      );
      await _saveInfo();
      _router = OfflineRouter(tt);
      _loadFuture = Future.value(_router);
    } catch (e) {
      error = e.toString();
    } finally {
      client.close(force: true);
      progress = null;
      notifyListeners();
    }
  }

  Future<void> _saveInfo() async {
    final i = info;
    if (i == null) return;
    await File('${(await _dir()).path}/info.json').writeAsString(jsonEncode(i.toJson()));
  }

  /// Whether gtfs.de has published a newer timetable than ours (HEAD requests only, a few hundred bytes).
  Future<bool> updateAvailable() async {
    final i = info;
    if (i == null) return false;
    final client = HttpClient()..userAgent = userAgent;
    try {
      for (final e in offlineFeeds.entries) {
        final req = await client.headUrl(Uri.parse(e.value)).timeout(const Duration(seconds: 10));
        final res = await req.close().timeout(const Duration(seconds: 10));
        await res.drain<void>();
        final lm = res.headers.value(HttpHeaders.lastModifiedHeader);
        if (lm != null && lm != i.versions[e.key]) return true;
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Regular check (app start, back in the app): timetable changes such as construction work,
  /// cancellations and extra trains are published weekly or more often. Downloads when there is news.
  Future<void> checkForUpdate({bool autoDownload = true, Duration every = const Duration(hours: 12)}) async {
    final i = info;
    if (!supported || i == null || progress != null) return;
    if (i.lastChecked != null && DateTime.now().difference(i.lastChecked!) < every) return;
    try {
      final newer = await updateAvailable();
      info = i.checkedNow();
      await _saveInfo();
      notifyListeners();
      if (newer && autoDownload) await download();
    } catch (_) {
      // offline – try again next time
    }
  }

  Future<void> delete() async {
    try {
      final d = await _dir();
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
    info = null;
    _router = null;
    _loadFuture = null;
    notifyListeners();
  }

  /// Loads and parses the stored timetable (in a background isolate), once.
  Future<OfflineRouter?> router() {
    if (_router != null) return Future.value(_router);
    if (!available) return Future.value(null);
    return _loadFuture ??= () async {
      loading = true;
      notifyListeners();
      try {
        final dir = await _dir();
        final zips = [for (final k in offlineFeeds.keys) await File('${dir.path}/$k.zip').readAsBytes()];
        _router = OfflineRouter(await compute(_parseInIsolate, zips));
        return _router;
      } catch (e) {
        error = e.toString();
        _loadFuture = null;
        return null;
      } finally {
        loading = false;
        notifyListeners();
      }
    }();
  }

  /// Older than a week, or running out: gtfs.de publishes weekly and the calendars reach only ~4 weeks ahead.
  bool get stale =>
      info != null &&
      (DateTime.now().difference(info!.downloadedAt).inDays >= 7 || info!.validToDate.difference(DateTime.now()).inDays < 7);
}

/// Search source working on the offline timetable (planned times, no prices, no delays).
class OfflineSource implements Source, LocationSource {
  @override
  String get id => 'offline';
  @override
  String get label => 'Offline';
  @override
  bool get corsFriendly => true;

  @override
  Future<List<Journey>> journeys(Place from, Place to, SearchOptions opts) async {
    final pack = OfflinePack.instance;
    if (!pack.available) return [];
    if (!pack.info!.coversDate(opts.when)) {
      throw SourceException('offline timetable does not cover this date – update it in Settings');
    }
    final r = await pack.router();
    if (r == null) throw SourceException('offline timetable could not be loaded');
    if (opts.arriveBy) {
      // Earliest-arrival search from a few hours before, keeping the ones that arrive in time.
      final js = r.route(
        from,
        to,
        opts.when.subtract(const Duration(hours: 4)),
        count: 12,
        minTransferMinutes: opts.minTransferMinutes,
        maxWalkMinutes: opts.maxWalkMinutes,
        maxTransfers: opts.maxTransfers,
      );
      final ok = js.where((j) => !j.arrival.isAfter(opts.when)).toList();
      return ok.sublist((ok.length - opts.results).clamp(0, ok.length));
    }
    return r.route(
      from,
      to,
      opts.when,
      count: opts.results,
      minTransferMinutes: opts.minTransferMinutes,
      maxWalkMinutes: opts.maxWalkMinutes,
      maxTransfers: opts.maxTransfers,
    );
  }

  @override
  Future<List<Place>> locations(String q) async {
    final r = await OfflinePack.instance.router();
    return r?.searchStops(q) ?? const [];
  }
}
