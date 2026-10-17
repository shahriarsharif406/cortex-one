import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/stores.dart';
import 'ble_transport.dart';
import 'cw_session.dart';
import 'gateway_config.dart';
import 'gateway_controller.dart';
import 'gateway_http.dart';
import 'gateway_platform.dart';
import 'wake_totp.dart';

/// Where the gateway log is kept for the setup screen: only event kinds and masked notes.
const gatewayEventsKey = 'gateway_events';

/// Wires the config, the secure stores, BLE, the SMS handler and the HTTP listener together.
/// Runs inside the foreground service's Flutter engine (see [gatewayMain]).
class GatewayRuntime {
  GatewayRuntime({
    required this.config,
    required this.secrets,
    required this.prefs,
    required this.platform,
    CwTransport? transport,
    DateTime Function()? now,
  }) : _transport = transport ?? FlutterBlueTransport(),
       _now = now ?? DateTime.now;

  final GatewayConfig config;
  final SecretStore secrets;
  final PrefsStore prefs;
  final GatewayPlatform platform;
  final CwTransport _transport;
  final DateTime Function() _now;

  GatewayController? controller;
  GatewayHttpServer? http;

  /// Returns null (and does nothing) unless the gateway is switched on and fully set up.
  Future<GatewayController?> start() async {
    if (!config.enabled || !config.hasSecrets || config.allowedNumbers.isEmpty) return null;
    final key = hexToBytes(config.bleKeyHex);
    final dev = hexToBytes(config.deviceIdHex);
    final secret = base32Decode(config.wakeSecretB32);
    if (key == null || dev == null || secret == null) return null;
    final c = GatewayController(
      allowedNumbers: config.allowedNumbers.toSet(),
      totp: WakeTotp(secret: Uint8List.fromList(secret), store: SecretTotpStepStore(secrets)),
      session: CwSession(
        key: key,
        deviceId: dev,
        transport: _transport,
        counterStore: SecretCwCounterStore(secrets),
      ),
      now: _now,
      pressMs: config.pressMs,
    );
    controller = c;
    platform.setSmsHandler((sender, body) async {
      final reply = await c.handleSms(sender, body);
      await _saveEvents(c);
      if (reply != null) await platform.sendSms(sender, reply);
      return null; // the reply is sent from here; nothing more for Kotlin to do
    });
    if (config.httpBind.isNotEmpty && config.httpToken.length >= 16) {
      final server = GatewayHttpServer(controller: c, token: config.httpToken);
      try {
        await server.start(config.httpBind, config.httpPort);
        http = server;
      } catch (_) {
        // the address (e.g. Tailscale) is not up yet: SMS still works; the user can restart
      }
    }
    return c;
  }

  Future<void> _saveEvents(GatewayController c) async {
    try {
      await prefs.set(
        gatewayEventsKey,
        jsonEncode([
          for (final e in c.events.reversed.take(20))
            {'t': e.time.millisecondsSinceEpoch, 'k': e.kind, 'n': e.note},
        ]),
      );
    } catch (_) {}
  }

  Future<void> stop() async => http?.stop();
}

Future<PrefsStore> openPrefsForService() async =>
    SharedPrefsStore(await SharedPreferences.getInstance());

/// Entry point of the headless engine that GatewayService starts (kept alive by a foreground
/// notification so incoming SMS can be handled while the app is closed).
@pragma('vm:entry-point')
Future<void> gatewayMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final secrets = KeystoreSecretStore();
  final config = await GatewayConfigStore(secrets).load();
  // SharedPreferences needs a plugin; the setup screen reads the same keys
  final prefs = await openPrefsForService();
  await GatewayRuntime(
    config: config,
    secrets: secrets,
    prefs: prefs,
    platform: MethodChannelGatewayPlatform(),
  ).start();
}
