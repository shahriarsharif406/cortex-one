import 'dart:async';

import 'package:flutter/services.dart';

/// The Android side of gateway mode (SmsReceiver, GatewayService, runtime permissions).
/// Kotlin forwards each incoming SMS here; the Dart handler returns the reply text (or null
/// to stay silent) and Kotlin sends it. Tests use [FakeGatewayPlatform].
abstract class GatewayPlatform {
  Future<bool> hasPermissions();

  /// Shows the system permission prompts (SMS, Bluetooth, notifications). The app explains
  /// WHY first (see GatewaySetupScreen).
  Future<bool> requestPermissions();
  Future<void> startService();
  Future<void> stopService();
  Future<bool> isRunning();
  Future<void> sendSms(String to, String text);

  /// Called by the service engine: the handler receives (sender, body).
  void setSmsHandler(Future<String?> Function(String sender, String body) handler);
}

class MethodChannelGatewayPlatform implements GatewayPlatform {
  MethodChannelGatewayPlatform([MethodChannel? channel])
    : _c = channel ?? const MethodChannel('ai.futuretech.cortex_one/gateway');

  final MethodChannel _c;

  @override
  Future<bool> hasPermissions() async => (await _c.invokeMethod<bool>('hasPermissions')) ?? false;

  @override
  Future<bool> requestPermissions() async =>
      (await _c.invokeMethod<bool>('requestPermissions')) ?? false;

  @override
  Future<void> startService() => _c.invokeMethod<void>('startService');

  @override
  Future<void> stopService() => _c.invokeMethod<void>('stopService');

  @override
  Future<bool> isRunning() async => (await _c.invokeMethod<bool>('isRunning')) ?? false;

  @override
  Future<void> sendSms(String to, String text) =>
      _c.invokeMethod<void>('sendSms', {'to': to, 'text': text});

  @override
  void setSmsHandler(Future<String?> Function(String sender, String body) handler) {
    _c.setMethodCallHandler((call) async {
      if (call.method == 'onSms') {
        final a = call.arguments;
        if (a is Map && a['sender'] is String && a['body'] is String) {
          return handler(a['sender'] as String, a['body'] as String);
        }
      }
      return null;
    });
    // tell Kotlin the engine is ready to receive queued messages
    unawaited(_c.invokeMethod<void>('engineReady'));
  }
}

class FakeGatewayPlatform implements GatewayPlatform {
  bool granted = false;
  bool grantOnRequest = true;
  bool running = false;
  final List<String> calls = [];
  final List<(String, String)> sent = [];
  Future<String?> Function(String, String)? handler;

  @override
  Future<bool> hasPermissions() async => granted;

  @override
  Future<bool> requestPermissions() async {
    calls.add('request');
    if (grantOnRequest) granted = true;
    return granted;
  }

  @override
  Future<void> startService() async {
    calls.add('start');
    running = true;
  }

  @override
  Future<void> stopService() async {
    calls.add('stop');
    running = false;
  }

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<void> sendSms(String to, String text) async => sent.add((to, text));

  @override
  void setSmsHandler(Future<String?> Function(String sender, String body) h) => handler = h;
}
