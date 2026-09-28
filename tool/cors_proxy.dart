// Tiny CORS proxy for the web build: browsers may not call DB and ÖBB directly.
// Only forwards to an allowlist of hosts, so it can't be abused as an open proxy.
//
//   dart run tool/cors_proxy.dart [port]      (default 8787)
//
// Then set Settings → Web proxy to http://localhost:8787/
import 'dart:io';

const allowedHosts = {'app.services-bahn.de', 'fahrplan.oebb.at'};

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args.first) : 8787;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  final client = HttpClient()..userAgent = 'anschluss-app/0.1 (personal journey planner; github.com/bjarnepw/anschluss)';
  stdout.writeln('Anschluss CORS proxy on http://localhost:$port/  (allowed: ${allowedHosts.join(', ')})');

  await for (final req in server) {
    final res = req.response;
    final origin = req.headers.value('origin') ?? '*';
    res.headers
      ..set('Access-Control-Allow-Origin', origin)
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set('Access-Control-Allow-Headers', req.headers.value('access-control-request-headers') ?? '*')
      ..set('Access-Control-Max-Age', '86400')
      ..set('Vary', 'Origin');
    if (req.method == 'OPTIONS') {
      res.statusCode = HttpStatus.noContent;
      await res.close();
      continue;
    }
    try {
      // Path looks like /https://host/path?query
      final target = Uri.parse(req.uri.toString().substring(1));
      if (target.scheme != 'https' || !allowedHosts.contains(target.host)) {
        res.statusCode = HttpStatus.forbidden;
        res.write('host not allowed');
        await res.close();
        continue;
      }
      final out = await client.openUrl(req.method, target);
      for (final h in ['content-type', 'accept', 'accept-language', 'x-correlation-id']) {
        final v = req.headers.value(h);
        if (v != null) out.headers.set(h, v);
      }
      await out.addStream(req);
      final upstream = await out.close();
      res.statusCode = upstream.statusCode;
      final ct = upstream.headers.contentType;
      if (ct != null) res.headers.contentType = ct;
      await res.addStream(upstream);
    } catch (e) {
      res.statusCode = HttpStatus.badGateway;
      res.write('proxy error: $e');
    }
    await res.close();
  }
}
