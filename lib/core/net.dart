// Networking with the reliability features every source shares:
// timeouts, retries with backoff for transient failures, a small TTL cache,
// and an optional CORS proxy for web builds.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// Keep in sync with pubspec.yaml. Stable product name + contact, as the OSM tile policy and Transitous ask.
const appVersion = '0.6.3';
const userAgent = 'Anschluss/$appVersion (+https://github.com/bjarnepw/anschluss)';

/// An error the user should see in plain words, plus whether retrying makes sense.
class SourceException implements Exception {
  final String message;
  final bool transient;
  final int? status;

  /// Seconds the circuit breaker should pause this source (e.g. when DB blocks us).
  final int? cooldown;

  SourceException(this.message, {this.transient = false, this.status, this.cooldown});

  @override
  String toString() => message;
}

class Net {
  Net._();
  static final Net instance = Net._();

  final http.Client _client = http.Client();

  /// Prefix for hosts that do not allow browser requests (web only).
  String webProxy = '';

  Uri _wrap(Uri url, {bool needsProxy = false}) {
    if (!kIsWeb || !needsProxy) return url;
    if (webProxy.isEmpty) {
      throw SourceException('needs the web proxy (set it in Settings)', cooldown: 3600);
    }
    final base = webProxy.endsWith('/') ? webProxy : '$webProxy/';
    return Uri.parse('$base$url');
  }

  Future<dynamic> getJson(
    Uri url, {
    Duration timeout = const Duration(seconds: 12),
    Map<String, String>? headers,
    bool needsProxy = false,
    int retries = 2,
  }) {
    return _withRetry(
      retries,
      () async {
        final res = await _client
            .get(
              _wrap(url, needsProxy: needsProxy),
              headers: {'Accept': 'application/json', if (!kIsWeb) 'User-Agent': userAgent, ...?headers},
            )
            .timeout(timeout);
        return _decode(res, url.host);
      },
      url.host,
      timeout,
    );
  }

  Future<String> getText(Uri url, {Duration timeout = const Duration(seconds: 12)}) {
    return _withRetry(
      1,
      () async {
        final res = await _client.get(url, headers: {if (!kIsWeb) 'User-Agent': userAgent}).timeout(timeout);
        if (res.statusCode != 200) throw SourceException('HTTP ${res.statusCode} from ${url.host}', transient: res.statusCode >= 500);
        return utf8.decode(res.bodyBytes, allowMalformed: true);
      },
      url.host,
      timeout,
    );
  }

  Future<dynamic> postJson(
    Uri url,
    Object body, {
    Duration timeout = const Duration(seconds: 15),
    Map<String, String>? headers,
    bool needsProxy = false,
    int retries = 1,
  }) {
    return _withRetry(
      retries,
      () async {
        final res = await _client
            .post(
              _wrap(url, needsProxy: needsProxy),
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
                if (!kIsWeb) 'User-Agent': userAgent,
                ...?headers,
              },
              body: jsonEncode(body),
            )
            .timeout(timeout);
        return _decode(res, url.host);
      },
      url.host,
      timeout,
    );
  }

  dynamic _decode(http.Response res, String host) {
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      try {
        return jsonDecode(text);
      } on FormatException {
        throw SourceException('unreadable answer from $host', transient: true);
      }
    }
    if (text.contains('OPS_BLOCKED')) {
      throw SourceException(
        '$host is blocking this network right now (rate limit). Try again later or on mobile data.',
        status: res.statusCode,
        cooldown: 600,
      );
    }
    if (res.statusCode == 429) {
      throw SourceException('too many requests to $host', transient: true, status: 429, cooldown: 120);
    }
    throw SourceException('HTTP ${res.statusCode} from $host', transient: res.statusCode >= 500, status: res.statusCode);
  }

  Future<T> _withRetry<T>(int retries, Future<T> Function() fn, String host, Duration timeout) async {
    final rnd = Random();
    for (var attempt = 0; ; attempt++) {
      try {
        return await fn();
      } on TimeoutException {
        if (attempt >= retries) throw SourceException('$host did not answer within ${timeout.inSeconds} s', transient: true);
      } on SourceException catch (e) {
        if (!e.transient || attempt >= retries || e.status == 429) rethrow;
      } on http.ClientException catch (e) {
        if (attempt >= retries) {
          throw SourceException(
            kIsWeb ? 'browser blocked the request to $host (CORS or offline)' : 'no connection to $host (${e.message})',
            transient: true,
          );
        }
      }
      // Exponential backoff with jitter: ~400 ms, ~1.2 s
      await Future.delayed(Duration(milliseconds: (400 * pow(3, attempt)).round() + rnd.nextInt(250)));
    }
  }
}

/// Small in-memory TTL cache so repeated searches don't hammer rate-limited APIs.
class TtlCache {
  final _map = <String, (DateTime, Object?)>{};
  final int maxEntries;
  TtlCache({this.maxEntries = 300});

  Future<T> get<T>(String key, Duration ttl, Future<T> Function() fn) async {
    final hit = _map[key];
    if (hit != null && hit.$1.isAfter(DateTime.now())) return hit.$2 as T;
    final v = await fn();
    _map[key] = (DateTime.now().add(ttl), v);
    if (_map.length > maxEntries) _map.remove(_map.keys.first);
    return v;
  }
}

final cache = TtlCache();

/// Per-source circuit breaker: after repeated failures (or an explicit cooldown, e.g. DB blocking us)
/// the source is skipped for a while instead of slowing every search down with timeouts.
class CircuitBreaker {
  final _failures = <String, int>{};
  final _openUntil = <String, DateTime>{};

  Duration? pausedFor(String source) {
    final until = _openUntil[source];
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    if (left.isNegative) {
      _openUntil.remove(source);
      return null;
    }
    return left;
  }

  void success(String source) {
    _failures.remove(source);
    _openUntil.remove(source);
  }

  void failure(String source, {int? cooldownSeconds}) {
    final n = (_failures[source] ?? 0) + 1;
    _failures[source] = n;
    if (cooldownSeconds != null) {
      _openUntil[source] = DateTime.now().add(Duration(seconds: cooldownSeconds));
    } else if (n >= 3) {
      _openUntil[source] = DateTime.now().add(Duration(seconds: 60 * (n - 2).clamp(1, 10)));
    }
  }

  /// Let the user force a retry.
  void reset() {
    _failures.clear();
    _openUntil.clear();
  }
}

final breaker = CircuitBreaker();
