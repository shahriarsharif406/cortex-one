import 'dart:convert';
import 'dart:typed_data';

import 'package:cortex_one/storage/stores.dart';
import 'package:cortex_one/wake/gateway_config.dart';
import 'package:cortex_one/wake/gateway_controller.dart';
import 'package:cortex_one/wake/gateway_platform.dart';
import 'package:cortex_one/wake/gateway_runtime.dart';
import 'package:cortex_one/wake/wake_totp.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Finder key(String k) => find.byKey(Key(k));

Future<Harness> openGateway(WidgetTester tester, {FakeGatewayPlatform? platform}) async {
  final h = Harness(gatewayPlatform: platform);
  await h.pump(tester);
  await flush(tester);
  await tester.tap(key('settings_menu'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('Cortex Wake গেটওয়ে (এই ফোন পাওয়ার-বোতাম রোবটের সাথে)'));
  await flush(tester);
  return h;
}

void main() {
  group('gateway setup screen', () {
    testWidgets('explains the permissions before anything is asked', (tester) async {
      final p = FakeGatewayPlatform();
      await openGateway(tester, platform: p);
      expect(key('gw_why'), findsOneWidget);
      expect(find.textContaining('RECEIVE_SMS'), findsOneWidget);
      expect(find.textContaining('SEND_SMS'), findsOneWidget);
      expect(find.textContaining('পরীক্ষা করা হয়নি'), findsOneWidget); // honest: hardware untested
      expect(p.calls, isEmpty); // nothing requested yet
      expect(key('gw_state'), findsOneWidget);
      expect(find.text('গেটওয়ে বন্ধ'), findsOneWidget);
    });

    testWidgets('starting without numbers and keys is refused and starts nothing', (tester) async {
      final p = FakeGatewayPlatform();
      await openGateway(tester, platform: p);
      await tester.tap(key('gw_toggle'));
      await flush(tester);
      expect(key('gw_error'), findsOneWidget);
      expect(p.calls, isNot(contains('start')));
    });

    testWidgets('a bad phone number or a 0.0.0.0 address is rejected and nothing is saved', (tester) async {
      final p = FakeGatewayPlatform();
      final h = await openGateway(tester, platform: p);
      await tester.enterText(key('gw_numbers'), '01711111111\nnot-a-number');
      await tester.tap(key('gw_save'));
      await flush(tester);
      expect(find.textContaining('একটি নম্বর ঠিক নয়'), findsOneWidget);
      expect(h.secrets.values.containsKey('wake_gateway_config'), isFalse);
      await tester.enterText(key('gw_numbers'), '01711111111');
      await tester.enterText(key('gw_bind'), '0.0.0.0');
      await tester.tap(key('gw_save'));
      await flush(tester);
      expect(find.textContaining('0.0.0.0 কখনো নয়'), findsOneWidget);
      await tester.enterText(key('gw_bind'), '8.8.8.8');
      await tester.tap(key('gw_save'));
      await flush(tester);
      expect(key('gw_error'), findsOneWidget);
      expect(h.secrets.values.containsKey('wake_gateway_config'), isFalse);
    });

    testWidgets('numbers are stored in one canonical form', (tester) async {
      final h = await openGateway(tester);
      await tester.enterText(key('gw_numbers'), '01711111111, +880 1811-111111\n01711111111');
      await tester.enterText(key('gw_bind'), '100.101.102.103');
      await tester.tap(key('gw_save'));
      await flush(tester);
      final cfg = await GatewayConfigStore(h.secrets).load();
      expect(cfg.allowedNumbers, ['+8801711111111', '+8801811111111']);
      expect(cfg.httpBind, '100.101.102.103');
    });

    testWidgets('new keys are shown once and kept only in the secure store', (tester) async {
      final h = await openGateway(tester);
      await tester.tap(key('gw_create'));
      await flush(tester);
      await tester.tap(key('gw_create_yes'));
      await flush(tester);
      expect(key('gw_secrets_dialog'), findsOneWidget);
      final wake = tester.widget<SelectableText>(key('gw_show_wake')).data!;
      final fw = tester.widget<SelectableText>(key('gw_show_fw')).data!;
      final token = tester.widget<SelectableText>(key('gw_show_token')).data!;
      expect(wake.length, 32);
      expect(fw, contains('CW_KEY[32]'));
      expect(fw, contains('CW_DEVICE_ID[8]'));
      await tester.tap(key('gw_secrets_done'));
      await flush(tester);
      final cfg = await GatewayConfigStore(h.secrets).load();
      expect(cfg.hasSecrets, isTrue);
      expect(cfg.wakeSecretB32, wake);
      expect(cfg.httpToken, token);
      // never in plain preferences
      final prefsDump = h.prefs.values.values.join(' ');
      for (final secret in [wake, token, cfg.bleKeyHex]) {
        expect(prefsDump.contains(secret), isFalse);
      }
      // and the dialog's text is gone from the screen afterwards
      expect(find.text(wake), findsNothing);
      expect(find.text(token), findsNothing);
    });

    testWidgets('start: permissions asked, service started, config enabled', (tester) async {
      final p = FakeGatewayPlatform();
      final h = await openGateway(tester, platform: p);
      await tester.enterText(key('gw_numbers'), '01711111111');
      await tester.tap(key('gw_create'));
      await flush(tester);
      await tester.tap(key('gw_create_yes'));
      await flush(tester);
      await tester.tap(key('gw_secrets_done'));
      await flush(tester);
      await tester.tap(key('gw_toggle'));
      await flush(tester);
      expect(p.calls, containsAllInOrder(['request', 'start']));
      expect(find.text('গেটওয়ে চলছে'), findsOneWidget);
      expect((await GatewayConfigStore(h.secrets).load()).enabled, isTrue);
      // stop again
      await tester.tap(key('gw_toggle'));
      await flush(tester);
      expect(p.calls.last, 'stop');
      expect((await GatewayConfigStore(h.secrets).load()).enabled, isFalse);
    });

    testWidgets('permission refused: the service is not started', (tester) async {
      final p = FakeGatewayPlatform()..grantOnRequest = false;
      await openGateway(tester, platform: p);
      await tester.enterText(key('gw_numbers'), '01711111111');
      await tester.tap(key('gw_create'));
      await flush(tester);
      await tester.tap(key('gw_create_yes'));
      await flush(tester);
      await tester.tap(key('gw_secrets_done'));
      await flush(tester);
      await tester.tap(key('gw_toggle'));
      await flush(tester);
      expect(p.calls, isNot(contains('start')));
      expect(find.textContaining('অনুমতি দেওয়া হয়নি'), findsOneWidget);
    });
  });

  // ------------------------------------------------------------ config and runtime
  group('gateway config', () {
    test('malformed or hostile stored values fall back to safe ones', () {
      expect(GatewayConfig.fromJson('nope').enabled, isFalse);
      final c = GatewayConfig.fromJson({
        'enabled': true,
        'allowed_numbers': ['01711111111', 'abc', 5, '01711111111', '+8801811111111'],
        'http_bind': '0.0.0.0',
        'http_port': 70000,
        'press_ms': 99999,
        'wake_secret': 5,
      });
      expect(c.allowedNumbers, ['+8801711111111', '+8801811111111']);
      expect(c.httpBind, '');
      expect(c.httpPort, 65535);
      expect(c.pressMs, 1500);
      expect(c.wakeSecretB32, '');
      expect(c.hasSecrets, isFalse);
    });

    test('a corrupt store gives the disabled default', () async {
      final s = MemorySecretStore()..values['wake_gateway_config'] = '{broken';
      expect((await GatewayConfigStore(s).load()).enabled, isFalse);
    });

    test('generated secrets have the right shapes and differ every time', () {
      final a = NewGatewaySecrets.generate();
      final b = NewGatewaySecrets.generate();
      expect(a.bleKeyHex.length, 64);
      expect(a.deviceIdHex.length, 16);
      expect(a.wakeSecretB32.length, 32);
      expect(a.httpToken.length, 48);
      expect(a.bleKeyHex, isNot(b.bleKeyHex));
      expect(hexToBytes(a.bleKeyHex), isNotNull);
      expect(hexToBytes('xyz'), isNull);
      expect(a.firmwareText().split('\n').length, 2);
    });
  });

  group('gateway runtime', () {
    late MemorySecretStore secrets;
    late MemoryPrefsStore prefs;
    late FakeGatewayPlatform platform;
    late GatewayConfig cfg;
    late SimulatedEsp32 esp;
    final clock = DateTime.fromMillisecondsSinceEpoch(1111111109 * 1000);

    Future<GatewayRuntime> make({bool enabled = true, List<String>? numbers}) async {
      secrets = MemorySecretStore();
      prefs = MemoryPrefsStore();
      platform = FakeGatewayPlatform();
      final fresh = NewGatewaySecrets.generate();
      cfg = GatewayConfig(
        enabled: enabled,
        allowedNumbers: numbers ?? ['+8801711111111'],
        wakeSecretB32: fresh.wakeSecretB32,
        bleKeyHex: fresh.bleKeyHex,
        deviceIdHex: fresh.deviceIdHex,
        httpToken: fresh.httpToken,
      );
      esp = SimulatedEsp32(
        key: hexToBytes(cfg.bleKeyHex)!,
        deviceId: hexToBytes(cfg.deviceIdHex)!,
      );
      return GatewayRuntime(
        config: cfg,
        secrets: secrets,
        prefs: prefs,
        platform: platform,
        transport: esp,
        now: () => clock,
      );
    }

    String code() => totpCode(
      Uint8List.fromList(base32Decode(cfg.wakeSecretB32)!),
      clock.millisecondsSinceEpoch ~/ 30000,
    );

    test('does nothing unless enabled, fully set up and with at least one number', () async {
      expect(await (await make(enabled: false)).start(), isNull);
      expect(platform.handler, isNull);
      expect(await (await make(numbers: [])).start(), isNull);
      expect(platform.handler, isNull);
      final r = await make();
      final noKeys = GatewayRuntime(
        config: const GatewayConfig(enabled: true, allowedNumbers: ['+8801711111111']),
        secrets: secrets,
        prefs: prefs,
        platform: platform,
        transport: esp,
      );
      expect(await noKeys.start(), isNull);
      expect(r, isNotNull);
    });

    test('an SMS from the owner with a valid code presses and gets a reply SMS', () async {
      final r = await make();
      await r.start();
      await platform.handler!('+8801711111111', 'ON ${code()}');
      expect(esp.presses, 1);
      expect(platform.sent.single.$1, '+8801711111111');
      expect(platform.sent.single.$2, contains('pressed'));
    });

    test('an SMS from anyone else is silent: no reply, no press, no code consumed', () async {
      final r = await make();
      await r.start();
      await platform.handler!('+8801999999999', 'ON ${code()}');
      expect(platform.sent, isEmpty);
      expect(esp.presses, 0);
      await platform.handler!('+8801711111111', 'ON ${code()}');
      expect(esp.presses, 1);
    });

    test('the replay guard survives a restart (last step is in the secure store)', () async {
      final r = await make();
      await r.start();
      final c = code();
      await platform.handler!('+8801711111111', 'ON $c');
      expect(esp.presses, 1);
      // a brand-new runtime on the same secure store, same clock: the old code is dead
      final again = GatewayRuntime(
        config: cfg,
        secrets: secrets,
        prefs: prefs,
        platform: platform,
        transport: esp,
        now: () => clock.add(const Duration(minutes: 1)),
      );
      await again.start();
      await platform.handler!('+8801711111111', 'ON $c');
      expect(esp.presses, 1);
      expect(platform.sent.last.$2, startsWith('Wrong code'));
    });

    test('the saved event log holds no code, no SMS text and no full number', () async {
      final r = await make();
      await r.start();
      final c = code();
      await platform.handler!('+8801711111111', 'ON $c');
      await platform.handler!('+8801711111111', 'ON 999999');
      await platform.handler!('+8801555555555', 'ON $c');
      final dump = prefs.values[gatewayEventsKey]!;
      expect(dump.contains(c), isFalse);
      expect(dump.contains('999999'), isFalse);
      expect(dump.contains('8801711111111'), isFalse);
      expect(dump.contains('8801555555555'), isFalse);
      expect(jsonDecode(dump), isA<List>());
    });

    test('no key, token or secret reaches plain preferences', () async {
      final r = await make();
      await r.start();
      await platform.handler!('+8801711111111', 'ON ${code()}');
      final plain = prefs.values.values.join(' ');
      for (final s in [cfg.bleKeyHex, cfg.wakeSecretB32, cfg.httpToken, cfg.deviceIdHex]) {
        expect(plain.contains(s), isFalse);
      }
    });

    test('a listener address that is not up is survived (SMS keeps working)', () async {
      final r = await make();
      final withBind = GatewayRuntime(
        config: cfg.copyWith(httpBind: '100.64.0.250', httpPort: 8780),
        secrets: secrets,
        prefs: prefs,
        platform: platform,
        transport: esp,
        now: () => clock,
      );
      expect(await withBind.start(), isNotNull);
      expect(withBind.http, isNull); // could not bind on this PC: no crash
      await platform.handler!('+8801711111111', 'ON ${code()}');
      expect(esp.presses, 1);
      expect(r, isNotNull);
    });
  });
}
