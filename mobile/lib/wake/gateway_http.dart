import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'gateway_controller.dart';

/// Where the gateway listener may bind. Same rule as the laptop agent: loopback, a Tailscale
/// address (100.64.0.0/10), or a private LAN address the owner typed in. Never 0.0.0.0.
String? checkGatewayBind(String address) {
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(address.trim());
  if (m == null) return null;
  final o = [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
  if (o.any((n) => n > 255) || (o[0] == 0)) return null;
  final ok = o[0] == 127 ||
      (o[0] == 100 && o[1] >= 64 && o[1] <= 127) ||
      o[0] == 10 ||
      (o[0] == 172 && o[1] >= 16 && o[1] <= 31) ||
      (o[0] == 192 && o[1] == 168);
  return ok ? o.join('.') : null;
}

bool _ctEqual(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  if (x.length != y.length) return false;
  var d = 0;
  for (var i = 0; i < x.length; i++) {
    d |= x[i] ^ y[i];
  }
  return d == 0;
}

/// A tiny listener so the app can trigger the gateway over the internet (Tailscale).
///   GET  /status           -> {"ok":true,"laptop":"on|off|unknown","message":"..."}
///   POST /press {"force"}  -> {"ok":bool,"laptop":"...","message":"..."}
/// Every request needs `Authorization: Bearer <token>`. Wrong tokens are counted per client
/// address and the address is locked out after a few failures.
class GatewayHttpServer {
  GatewayHttpServer({
    required this.controller,
    required this.token,
    this.maxFailures = 5,
    this.lockout = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (token.length < 16) throw ArgumentError('the gateway token is too short');
  }

  final GatewayController controller;
  final String token;
  final int maxFailures;
  final Duration lockout;
  final DateTime Function() _now;
  HttpServer? _server;
  final Map<String, int> _failures = {};
  final Map<String, DateTime> _lockedUntil = {};

  int? get port => _server?.port;

  Future<void> start(String address, int port) async {
    final ok = checkGatewayBind(address);
    if (ok == null) {
      throw ArgumentError('refusing to listen on that address (0.0.0.0 and public addresses are never allowed)');
    }
    _server = await HttpServer.bind(ok, port, shared: false);
    unawaited(_server!.forEach(_handle));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _reply(HttpRequest req, int code, Map<String, Object?> body) async {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.json;
    req.response.headers.set('Cache-Control', 'no-store');
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final client = req.connectionInfo?.remoteAddress.address ?? 'unknown';
      final until = _lockedUntil[client];
      if (until != null && _now().isBefore(until)) {
        return _reply(req, 429, {'ok': false, 'message': 'Too many attempts.'});
      }
      final header = req.headers.value('authorization') ?? '';
      final given = header.toLowerCase().startsWith('bearer ') ? header.substring(7).trim() : '';
      if (given.isEmpty || !_ctEqual(given, token)) {
        final n = (_failures[client] ?? 0) + 1;
        _failures[client] = n;
        if (n >= maxFailures) {
          _lockedUntil[client] = _now().add(lockout);
          _failures[client] = 0;
        }
        return _reply(req, 401, {'ok': false, 'message': 'Not authorised.'});
      }
      _failures.remove(client);
      if (req.method == 'GET' && req.uri.path == '/status') {
        final r = await controller.status();
        return _reply(req, 200, {'ok': r.ok, 'laptop': r.laptop, 'message': r.message});
      }
      if (req.method == 'POST' && req.uri.path == '/press') {
        var force = false;
        final bytes = <int>[];
        var tooLarge = false;
        var seen = 0;
        await for (final chunk in req.timeout(const Duration(seconds: 5))) {
          seen += chunk.length;
          if (seen > 512) {
            tooLarge = true;
            bytes.clear();
            // read (and drop) a bounded amount more so the client sees our answer, not a reset
            if (seen > 65536) break;
          } else if (!tooLarge) {
            bytes.addAll(chunk);
          }
        }
        if (tooLarge) {
          req.response.persistentConnection = false;
          return _reply(req, 413, {'ok': false, 'message': 'Too large.'});
        }
        final raw = utf8.decode(bytes, allowMalformed: true);
        if (raw.trim().isNotEmpty) {
          final j = jsonDecode(raw);
          if (j is Map && j['force'] is bool) force = j['force'] as bool;
        }
        final r = await controller.press(force: force);
        return _reply(req, 200, {'ok': r.ok, 'laptop': r.laptop, 'message': r.message});
      }
      return _reply(req, 404, {'ok': false, 'message': 'Not found.'});
    } on FormatException {
      return _reply(req, 400, {'ok': false, 'message': 'Bad request.'});
    } catch (_) {
      return _reply(req, 500, {'ok': false, 'message': 'The gateway failed.'});
    }
  }
}
