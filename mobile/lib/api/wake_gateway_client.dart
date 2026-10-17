import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../state/computer.dart';

/// What the Cortex Wake gateway phone answered.
class GatewayResult {
  const GatewayResult({
    required this.ok,
    required this.message,
    this.laptopState = 'unknown',
  });

  final bool ok;

  /// Plain sentence from the gateway (English). Never contains the token.
  final String message;

  /// on | off | unknown: what the optional state sensor on the ESP32 says.
  final String laptopState;
}

/// Talks to the gateway phone's tiny listener (see docs/cortex-wake/PROTOCOL.md):
///   GET  /status           -> {"laptop": "on|off|unknown", "ble": true|false}
///   POST /press {"force"}  -> {"ok": true|false, "message": "..."}
/// Both need `Authorization: Bearer <gateway token>`.
abstract class WakeGatewayClient {
  Future<GatewayResult> status(WakeGateway gateway);
  Future<GatewayResult> press(WakeGateway gateway, {bool force = false});
}

class HttpWakeGatewayClient implements WakeGatewayClient {
  HttpWakeGatewayClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  Future<GatewayResult> _call(
    WakeGateway g,
    String method,
    String path, [
    Object? body,
  ]) async {
    final uri = Uri.parse('${g.address}$path');
    final headers = {
      'Authorization': 'Bearer ${g.token}',
      'Accept': 'application/json',
      if (method == 'POST') 'Content-Type': 'application/json',
    };
    try {
      final res = await (method == 'GET'
              ? _client.get(uri, headers: headers)
              : _client.post(uri, headers: headers, body: jsonEncode(body ?? {})))
          .timeout(timeout);
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is! Map) {
        return const GatewayResult(ok: false, message: 'Bad answer.');
      }
      return GatewayResult(
        ok: res.statusCode >= 200 && res.statusCode < 300 && j['ok'] != false,
        message: (j['message'] ?? '').toString(),
        laptopState: (j['laptop'] ?? 'unknown').toString(),
      );
    } on TimeoutException {
      return const GatewayResult(ok: false, message: 'The gateway phone did not answer.');
    } on SocketException {
      return const GatewayResult(ok: false, message: 'The gateway phone is not reachable.');
    } on http.ClientException {
      return const GatewayResult(ok: false, message: 'The gateway phone is not reachable.');
    } on FormatException {
      return const GatewayResult(ok: false, message: 'Bad answer.');
    }
  }

  @override
  Future<GatewayResult> status(WakeGateway gateway) =>
      _call(gateway, 'GET', '/status');

  @override
  Future<GatewayResult> press(WakeGateway gateway, {bool force = false}) =>
      _call(gateway, 'POST', '/press', {'force': force});
}
