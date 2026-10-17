import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../storage/stores.dart';
import 'cw_protocol.dart';
import 'gateway_http.dart';
import 'sms_command.dart';
import 'wake_totp.dart';

String _hex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

Uint8List? hexToBytes(String h) {
  final t = h.trim();
  if (t.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(t)) return null;
  return Uint8List.fromList([
    for (var i = 0; i < t.length; i += 2) int.parse(t.substring(i, i + 2), radix: 16),
  ]);
}

/// Everything the gateway needs. It holds the wake secret, the BLE key and the HTTP token, so it
/// lives ONLY in the secure store (`SecretStore`, Android Keystore). Never in plain prefs, logs
/// or SMS.
class GatewayConfig {
  const GatewayConfig({
    this.enabled = false,
    this.allowedNumbers = const [],
    this.wakeSecretB32 = '',
    this.bleKeyHex = '',
    this.deviceIdHex = '',
    this.httpToken = '',
    this.httpBind = '',
    this.httpPort = 8780,
    this.pressMs = 400,
  });

  final bool enabled;
  final List<String> allowedNumbers;
  final String wakeSecretB32;
  final String bleKeyHex;
  final String deviceIdHex;
  final String httpToken;

  /// Where the listener binds (Tailscale address of this phone). Empty = listener off.
  final String httpBind;
  final int httpPort;
  final int pressMs;

  bool get hasSecrets =>
      wakeSecretB32.isNotEmpty && bleKeyHex.length == 64 && deviceIdHex.length == 16;

  GatewayConfig copyWith({
    bool? enabled,
    List<String>? allowedNumbers,
    String? wakeSecretB32,
    String? bleKeyHex,
    String? deviceIdHex,
    String? httpToken,
    String? httpBind,
    int? httpPort,
    int? pressMs,
  }) => GatewayConfig(
    enabled: enabled ?? this.enabled,
    allowedNumbers: allowedNumbers ?? this.allowedNumbers,
    wakeSecretB32: wakeSecretB32 ?? this.wakeSecretB32,
    bleKeyHex: bleKeyHex ?? this.bleKeyHex,
    deviceIdHex: deviceIdHex ?? this.deviceIdHex,
    httpToken: httpToken ?? this.httpToken,
    httpBind: httpBind ?? this.httpBind,
    httpPort: httpPort ?? this.httpPort,
    pressMs: pressMs ?? this.pressMs,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'allowed_numbers': allowedNumbers,
    'wake_secret': wakeSecretB32,
    'ble_key': bleKeyHex,
    'device_id': deviceIdHex,
    'http_token': httpToken,
    'http_bind': httpBind,
    'http_port': httpPort,
    'press_ms': pressMs,
  };

  /// Defensive: anything malformed falls back to the safe default (disabled, empty).
  static GatewayConfig fromJson(Object? j) {
    if (j is! Map) return const GatewayConfig();
    String s(String k) => j[k] is String ? j[k] as String : '';
    final nums = <String>[];
    if (j['allowed_numbers'] is List) {
      for (final n in j['allowed_numbers'] as List) {
        final p = n is String ? normalizePhone(n) : null;
        if (p != null && !nums.contains(p)) nums.add(p);
      }
    }
    final port = j['http_port'] is int ? j['http_port'] as int : 8780;
    final ms = j['press_ms'] is int ? j['press_ms'] as int : 400;
    final bind = s('http_bind');
    return GatewayConfig(
      enabled: j['enabled'] == true,
      allowedNumbers: nums,
      wakeSecretB32: s('wake_secret'),
      bleKeyHex: s('ble_key'),
      deviceIdHex: s('device_id'),
      httpToken: s('http_token'),
      httpBind: bind.isEmpty || checkGatewayBind(bind) != null ? bind : '',
      httpPort: port.clamp(1024, 65535),
      pressMs: ms.clamp(100, 1500),
    );
  }
}

class GatewayConfigStore {
  GatewayConfigStore(this.secrets);
  final SecretStore secrets;
  static const _key = 'wake_gateway_config';

  Future<GatewayConfig> load() async {
    final raw = await secrets.read(_key);
    if (raw == null || raw.isEmpty) return const GatewayConfig();
    try {
      return GatewayConfig.fromJson(jsonDecode(raw));
    } on FormatException {
      return const GatewayConfig();
    }
  }

  Future<void> save(GatewayConfig c) => secrets.write(_key, jsonEncode(c.toJson()));
}

/// Fresh random secrets. The caller shows them to the owner ONCE, then only the secure store
/// keeps them.
class NewGatewaySecrets {
  NewGatewaySecrets._(this.wakeSecretB32, this.bleKeyHex, this.deviceIdHex, this.httpToken);

  final String wakeSecretB32;
  final String bleKeyHex;
  final String deviceIdHex;
  final String httpToken;

  factory NewGatewaySecrets.generate([Random? rng]) {
    final r = rng ?? Random.secure();
    List<int> bytes(int n) => List.generate(n, (_) => r.nextInt(256));
    return NewGatewaySecrets._(
      newWakeSecret(r),
      _hex(bytes(32)),
      _hex(bytes(8)),
      _hex(bytes(24)),
    );
  }

  /// The two lines that go into firmware/cortex-wake/include/secrets.h
  String firmwareText() {
    String arr(String hex) => [
      for (var i = 0; i < hex.length; i += 2) '0x${hex.substring(i, i + 2)}',
    ].join(', ');
    return 'static const uint8_t CW_KEY[32] = {${arr(bleKeyHex)}};\n'
        'static const uint8_t CW_DEVICE_ID[8] = {${arr(deviceIdHex)}};';
  }
}

/// Last accepted TOTP step, kept in the secure store (replay protection survives a restart).
class SecretTotpStepStore implements TotpStepStore {
  SecretTotpStepStore(this.secrets);
  final SecretStore secrets;
  static const _key = 'wake_totp_step';

  @override
  Future<int> lastStep() async => int.tryParse(await secrets.read(_key) ?? '') ?? 0;

  @override
  Future<void> saveStep(int step) => secrets.write(_key, '$step');
}

/// The BLE counter, kept in the secure store.
class SecretCwCounterStore implements CwCounterStore {
  SecretCwCounterStore(this.secrets);
  final SecretStore secrets;
  static const _key = 'wake_ble_counter';

  @override
  Future<int> read() async => int.tryParse(await secrets.read(_key) ?? '') ?? 0;

  @override
  Future<void> write(int value) => secrets.write(_key, '$value');
}
