import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cortex_one/wake/cw_protocol.dart';
import 'package:cortex_one/wake/cw_session.dart';
import 'package:cortex_one/wake/gateway_controller.dart';
import 'package:cortex_one/wake/gateway_http.dart';
import 'package:cortex_one/wake/sms_command.dart';
import 'package:cortex_one/wake/wake_totp.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16),
]);
String toHex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

final vectors =
    jsonDecode(File('../docs/cortex-wake/test_vectors.json').readAsStringSync())
        as Map<String, dynamic>;
final key = hex(vectors['key_hex'] as String);
final dev = hex(vectors['device_id_hex'] as String);

const parseNames = {
  'ok': CwParse.ok,
  'bad_length': CwParse.badLength,
  'bad_version': CwParse.badVersion,
  'bad_cmd': CwParse.badCmd,
  'bad_tag': CwParse.badTag,
  'replay': CwParse.replay,
  'jump': CwParse.jump,
};

void main() {
  reviewTests();
  // ------------------------------------------------------------ shared vectors
  group('shared test vectors (same file as Python and C++)', () {
    test('HMAC-SHA256 matches RFC 4231', () {
      for (final t in vectors['hmac_sha256_rfc4231'] as List) {
        final mac = Hmac(sha256, hex(t['key_hex'] as String)).convert(hex(t['msg_hex'] as String));
        expect(mac.toString(), t['mac_hex']);
      }
    });

    test('every command frame is reproduced byte for byte and verifies', () {
      for (final c in vectors['commands'] as List) {
        final built = cwBuildCommand(
          key: key,
          deviceId: dev,
          counter: c['counter'] as int,
          cmd: CwCmd.fromCode(c['cmd'] as int)!,
          args: hex(c['args_hex'] as String),
        );
        expect(toHex(built), c['frame_hex'], reason: c['name'] as String);
        final p = cwParseCommand(built, key, dev, (c['counter'] as int) - 1);
        expect(p.result, CwParse.ok, reason: c['name'] as String);
        expect(toHex(p.args!), c['args_hex']);
      }
    });

    test('every parse case gives the expected verdict', () {
      for (final p in vectors['parse_cases'] as List) {
        final got = cwParseCommand(hex(p['frame_hex'] as String), key, dev, p['stored_counter'] as int);
        expect(got.result, parseNames[p['expect']], reason: p['name'] as String);
      }
    });

    test('responses are reproduced and verify; tampered ones do not', () {
      for (final r in vectors['responses'] as List) {
        final frame = cwBuildResponse(
          key: key,
          deviceId: dev,
          status: r['status'] as int,
          counter: r['counter'] as int,
          laptop: r['laptop'] as int,
          servo: r['servo'] as int,
        );
        expect(toHex(frame), r['frame_hex'], reason: r['name'] as String);
        final parsed = cwParseResponse(frame, key, dev)!;
        expect(parsed.status, r['status']);
        expect(parsed.counter, r['counter']);
      }
      for (final r in vectors['bad_responses'] as List) {
        expect(cwParseResponse(hex(r['frame_hex'] as String), key, dev), isNull, reason: r['name'] as String);
      }
    });

    test('constants agree with the vectors file', () {
      final k = vectors['constants'] as Map;
      expect(k['max_jump'], cwMaxJump);
      expect(k['max_press_ms'], cwMaxPressMs);
      expect(k['min_press_ms'], cwMinPressMs);
      expect(k['tag_len'], cwTagLen);
    });
  });

  // ---------------------------------------------------------- frames and counter
  group('frames', () {
    test('a response made with another key or device id is not accepted', () {
      final f = cwBuildResponse(key: key, deviceId: dev, status: 0, counter: 1, laptop: 0, servo: 0);
      expect(cwParseResponse(f, Uint8List(32), dev), isNull);
      expect(cwParseResponse(f, key, hex('0000000000000001')), isNull);
    });
    test('a command cannot be turned into a response or the other way round', () {
      final cmd = cwBuildCommand(key: key, deviceId: dev, counter: 5, cmd: CwCmd.state);
      expect(cwParseResponse(cmd, key, dev), isNull);
    });
    test('press time limits are enforced on the app side too', () {
      expect(() => cwPressArgs(99), throwsArgumentError);
      expect(() => cwPressArgs(1501), throwsArgumentError);
      expect(() => cwPressArgs(65535), throwsArgumentError);
      expect(cwPressArgs(400), [0x01, 0x90]);
    });
    test('wrong argument length and counter 0 are refused when building', () {
      expect(() => cwBuildCommand(key: key, deviceId: dev, counter: 1, cmd: CwCmd.press), throwsArgumentError);
      expect(() => cwBuildCommand(key: key, deviceId: dev, counter: 0, cmd: CwCmd.ping), throwsArgumentError);
      expect(() => cwBuildCommand(key: key, deviceId: dev, counter: 0x100000000, cmd: CwCmd.ping), throwsArgumentError);
    });
    test('a frame for another device id never verifies', () {
      final f = cwBuildCommand(key: key, deviceId: hex('0000000000000001'), counter: 9, cmd: CwCmd.press, args: cwPressArgs(400));
      expect(cwParseCommand(f, key, dev, 0).result, CwParse.badTag);
    });
  });

  group('counter', () {
    test('is saved BEFORE it is used and strictly increases', () async {
      final store = MemoryCwCounterStore(7);
      final c = CwCounter(store);
      expect(await c.next(), 8);
      expect(store.value, 8);
      expect(await c.next(), 9);
    });
    test('observe never moves backwards; jumpAhead moves forward within the window', () async {
      final store = MemoryCwCounterStore(100);
      final c = CwCounter(store);
      await c.observe(50);
      expect(store.value, 100);
      await c.observe(150);
      expect(store.value, 150);
      await c.jumpAhead();
      expect(store.value, 1150);
      await c.jumpAhead(10000000);
      expect(store.value, 1150 + cwMaxJump ~/ 2); // clamped inside the firmware window
    });
    test('refuses to wrap around', () async {
      final c = CwCounter(MemoryCwCounterStore(0xFFFFFFFF));
      expect(c.next(), throwsStateError);
    });
  });

  group('session with a simulated ESP32', () {
    SimulatedEsp32 esp({int counter = 0, int laptop = cwLaptopOff}) =>
        SimulatedEsp32(key: key, deviceId: dev, counter: counter, laptop: laptop);
    CwSession sess(SimulatedEsp32 e, [MemoryCwCounterStore? s]) => CwSession(
      key: key,
      deviceId: dev,
      transport: e,
      counterStore: s ?? MemoryCwCounterStore(),
      timeout: const Duration(milliseconds: 10),
    );

    test('state and press work and are counted once', () async {
      final e = esp();
      final s = sess(e);
      expect((await s.state()).response!.laptop, cwLaptopOff);
      final p = await s.press(400);
      expect(p.response!.ok, isTrue);
      expect(e.presses, 1);
      expect(e.pressDurations, [400]);
    });

    test('a recorded frame cannot be replayed', () async {
      final e = esp();
      final frame = cwBuildCommand(key: key, deviceId: dev, counter: 1, cmd: CwCmd.press, args: cwPressArgs(400));
      expect(await e.exchange(frame, const Duration(seconds: 1)), isNotNull);
      expect(e.presses, 1);
      expect(await e.exchange(frame, const Duration(seconds: 1)), isNull);
      expect(e.presses, 1);
      expect(e.ignored, 1);
    });

    test('a forged frame (wrong key) is ignored silently', () async {
      final e = esp();
      final forged = cwBuildCommand(key: Uint8List(32), deviceId: dev, counter: 1, cmd: CwCmd.press, args: cwPressArgs(400));
      expect(await e.exchange(forged, const Duration(seconds: 1)), isNull);
      expect(e.presses, 0);
      expect(e.storedCounter, 0); // an ignored frame does not even move the counter
    });

    test('an out-of-range press time is refused by the device, nothing moves', () async {
      final e = esp();
      final raw = cwBuildCommand(key: key, deviceId: dev, counter: 1, cmd: CwCmd.press, args: Uint8List.fromList([0x27, 0x10]));
      final r = cwParseResponse((await e.exchange(raw, const Duration(seconds: 1)))!, key, dev)!;
      expect(r.status, cwStBadArgs);
      expect(e.presses, 0);
    });

    test('calibration is never possible over the air in the simulator', () async {
      final e = esp();
      final raw = cwBuildCommand(key: key, deviceId: dev, counter: 1, cmd: CwCmd.calibrate, args: Uint8List.fromList([20, 70]));
      final r = cwParseResponse((await e.exchange(raw, const Duration(seconds: 1)))!, key, dev)!;
      expect(r.status, cwStCalLocked);
    });

    test('an app whose counter is behind (reinstall) recovers with a jump', () async {
      final e = esp(counter: 400);
      final s = sess(e, MemoryCwCounterStore(0));
      // 1st frame (counter 1) is ignored by the device, the retry (counter 1001) is accepted
      final out = await s.state();
      expect(out.response, isNotNull);
      expect(e.ignored, 1);
      expect(e.storedCounter, 1002); // 1 ignored -> jump to 1001 -> the retry uses 1002
    });

    test('a lost answer to PRESS is NOT retried: it can only have pressed once', () async {
      final e = esp()..dropAnswers = true;
      final s = sess(e);
      final out = await s.press(400);
      expect(out.reached, isFalse);
      expect(e.presses, 1);
    });

    test('an answer signed with a different key is rejected as bad_answer', () async {
      final other = SimulatedEsp32(key: Uint8List.fromList(List.filled(32, 7)), deviceId: dev);
      final s = CwSession(
        key: Uint8List.fromList(List.filled(32, 7)),
        deviceId: dev,
        transport: _Wrong(other),
        counterStore: MemoryCwCounterStore(),
        timeout: const Duration(milliseconds: 10),
      );
      final out = await s.state();
      expect(out.failure, 'bad_answer');
    });

    test('silence on a read-only command is reported after one jump-and-retry', () async {
      final e = esp()..dropAnswers = true;
      final out = await sess(e).state();
      expect(out.failure, 'no_answer');
    });
  });

  // ------------------------------------------------------------------- SMS parse
  group('SMS parser', () {
    test('plain commands', () {
      expect(parseWakeSms('ON 123456')!.kind, WakeCommandKind.on);
      expect(parseWakeSms('PRESS 123456')!.kind, WakeCommandKind.press);
      expect(parseWakeSms('STATUS')!.kind, WakeCommandKind.status);
      expect(parseWakeSms('on 123456')!.code, '123456');
      expect(parseWakeSms('  Press   123456  ')!.code, '123456');
    });
    test('Bangla and Arabic-Indic digits are read as digits', () {
      expect(parseWakeSms('ON ১২৩৪৫৬')!.code, '123456');
      expect(parseWakeSms('PRESS ٠١٢٣٤٥')!.code, '012345');
      expect(normalizeDigits('০১৭১১'), '01711');
    });
    test('FORCE is explicit and only after the code', () {
      expect(parseWakeSms('ON 123456 FORCE')!.force, isTrue);
      expect(parseWakeSms('on 123456 force')!.force, isTrue);
      expect(parseWakeSms('ON 123456')!.force, isFalse);
      expect(parseWakeSms('ON FORCE 123456'), isNull);
      expect(parseWakeSms('ON 123456 FORCE FORCE'), isNull);
      expect(parseWakeSms('ON 123456 NOW'), isNull);
    });
    test('anything else is not a command', () {
      for (final bad in [
        '', ' ', 'ON', 'PRESS', 'ON 12345', 'ON 1234567', 'ON 12345a', 'ONN 123456',
        'ON123456', 'STATUS 123456', 'SHUTDOWN 123456', 'ON 123456\nPRESS 123456',
        'ON ​123456', 'ON 123 456', 'x' * 100, 'ON 123456;rm', 'ON ١٢٣٤٥',
      ]) {
        expect(parseWakeSms(bad), isNull, reason: bad);
      }
    });
    test('phone numbers are compared in one canonical form', () {
      expect(normalizePhone('01711111111'), '+8801711111111');
      expect(normalizePhone('+880 1711-111111'), '+8801711111111');
      expect(normalizePhone('8801711111111'), '+8801711111111');
      expect(normalizePhone('008801711111111'), '+8801711111111');
      final bn = '01711111111'.split('').map((d) => String.fromCharCode(0x09E6 + int.parse(d))).join();
      expect(normalizePhone(bn), '+8801711111111');
      expect(normalizePhone('abc'), isNull);
      expect(normalizePhone(''), isNull);
      expect(normalizePhone('12'), isNull);
      expect(normalizePhone('+8801711111111; DROP'), isNull);
    });
  });

  // ------------------------------------------------------------------------ TOTP
  group('wake TOTP', () {
    final rfcSecret = Uint8List.fromList(utf8.encode('12345678901234567890'));
    test('matches RFC 6238 (last 6 digits of the published 8-digit values)', () {
      expect(totpCode(rfcSecret, 59 ~/ 30), '287082');
      expect(totpCode(rfcSecret, 1111111109 ~/ 30), '081804');
      expect(totpCode(rfcSecret, 1234567890 ~/ 30), '005924');
    });
    test('base32 round trip', () {
      final s = newWakeSecret();
      expect(s.length, 32);
      expect(base32Encode(base32Decode(s)!), s);
      expect(base32Decode('not base32!'), isNull);
      expect(base32Encode(rfcSecret), 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
    });
    WakeTotp mk() => WakeTotp(secret: rfcSecret, store: MemoryTotpStepStore());
    final t0 = DateTime.fromMillisecondsSinceEpoch(1111111109 * 1000);
    test('a code works once, then never again (replay)', () async {
      final t = mk();
      expect(await t.verifyAndConsume('081804', t0), isTrue);
      expect(await t.verifyAndConsume('081804', t0), isFalse);
    });
    test('the neighbouring steps are accepted once, an older one after a newer is not', () async {
      final t = mk();
      final next = totpCode(rfcSecret, 1111111109 ~/ 30 + 1);
      final prev = totpCode(rfcSecret, 1111111109 ~/ 30 - 1);
      expect(await t.verifyAndConsume(next, t0), isTrue);
      expect(await t.verifyAndConsume(prev, t0), isFalse);
      expect(await t.verifyAndConsume('081804', t0), isFalse); // step before the consumed one
    });
    test('far away codes, wrong codes and malformed codes fail', () async {
      final t = mk();
      expect(await t.verifyAndConsume(totpCode(rfcSecret, 1111111109 ~/ 30 + 5), t0), isFalse);
      expect(await t.verifyAndConsume('000000', t0), isFalse);
      expect(await t.verifyAndConsume('08180', t0), isFalse);
      expect(await t.verifyAndConsume('08180a', t0), isFalse);
      expect(await t.verifyAndConsume('', t0), isFalse);
    });
    test('another secret does not verify', () async {
      final other = WakeTotp(secret: Uint8List.fromList(utf8.encode('another-secret-key-20')), store: MemoryTotpStepStore());
      expect(await other.verifyAndConsume('081804', t0), isFalse);
    });
    test('the step is stored before the answer', () async {
      final store = MemoryTotpStepStore();
      final t = WakeTotp(secret: rfcSecret, store: store);
      await t.verifyAndConsume('081804', t0);
      expect(store.step, 1111111109 ~/ 30);
    });
  });

  // ------------------------------------------------------------------ controller
  group('gateway controller', () {
    final secret = Uint8List.fromList(utf8.encode('12345678901234567890'));
    var clock = DateTime.fromMillisecondsSinceEpoch(1111111109 * 1000);
    String code([int plus = 0]) => totpCode(secret, clock.millisecondsSinceEpoch ~/ 30000 + plus);

    late SimulatedEsp32 esp;
    late GatewayController gw;

    void setUpGateway({int laptop = cwLaptopOff, bool drop = false}) {
      clock = DateTime.fromMillisecondsSinceEpoch(1111111109 * 1000);
      esp = SimulatedEsp32(key: key, deviceId: dev, laptop: laptop)..dropAnswers = drop;
      gw = GatewayController(
        allowedNumbers: {'01711111111'},
        totp: WakeTotp(secret: secret, store: MemoryTotpStepStore()),
        session: CwSession(
          key: key,
          deviceId: dev,
          transport: esp,
          counterStore: MemoryCwCounterStore(),
          timeout: const Duration(milliseconds: 10),
        ),
        now: () => clock,
      );
    }

    const owner = '+8801711111111';

    test('an unknown sender gets silence, costs no code, and touches nothing', () async {
      setUpGateway();
      expect(await gw.handleSms('+8801999999999', 'ON ${code()}'), isNull);
      expect(esp.presses, 0);
      expect(esp.storedCounter, 0);
      expect(gw.events.single.kind, 'unknown_sender');
      // the code was NOT consumed: the owner can still use it
      expect(await gw.handleSms(owner, 'ON ${code()}'), contains('pressed'));
    });

    test('spoofed look-alike numbers do not match', () async {
      setUpGateway();
      for (final n in ['+88017111111110', '+8801711111112', '01711111112', '', 'abc']) {
        expect(await gw.handleSms(n, 'ON ${code()}'), isNull, reason: n);
      }
      expect(esp.presses, 0);
    });

    test('the number format of the sender does not matter', () async {
      setUpGateway();
      expect(await gw.handleSms('8801711111111', 'ON ${code()}'), contains('pressed'));
    });

    test('ON with the laptop OFF presses exactly once and says it proves nothing', () async {
      setUpGateway();
      final r = await gw.handleSms(owner, 'ON ${code()}');
      expect(r, contains('power button pressed'));
      expect(r, contains('does not prove'));
      expect(esp.presses, 1);
    });

    test('Bangla digits in the code work', () async {
      setUpGateway();
      final bn = code().split('').map((d) => String.fromCharCode(0x09E6 + int.parse(d))).join();
      expect(await gw.handleSms(owner, 'ON $bn'), contains('pressed'));
    });

    test('the same code cannot be used twice', () async {
      setUpGateway();
      final c = code();
      await gw.handleSms(owner, 'ON $c');
      clock = clock.add(const Duration(minutes: 1));
      final again = await gw.handleSms(owner, 'ON $c');
      expect(again, startsWith('Wrong code'));
      expect(esp.presses, 1);
    });

    test('ON when the laptop looks ON does nothing, even with FORCE', () async {
      setUpGateway(laptop: cwLaptopOn);
      expect(await gw.handleSms(owner, 'ON ${code()}'), contains('ON already'));
      clock = clock.add(const Duration(minutes: 1));
      expect(await gw.handleSms(owner, 'ON ${code()} FORCE'), contains('ON already'));
      expect(esp.presses, 0);
    });

    test('state unknown: refused without FORCE (and the reply says so), pressed with FORCE', () async {
      setUpGateway(laptop: cwLaptopUnknown);
      final no = await gw.handleSms(owner, 'ON ${code()}');
      expect(no, contains('UNKNOWN'));
      expect(no, contains('FORCE'));
      expect(esp.presses, 0);
      clock = clock.add(const Duration(minutes: 1));
      final yes = await gw.handleSms(owner, 'ON ${code()} FORCE');
      expect(yes, contains('forced'));
      expect(esp.presses, 1);
    });

    test('PRESS on a laptop that looks ON needs FORCE', () async {
      setUpGateway(laptop: cwLaptopOn);
      final no = await gw.handleSms(owner, 'PRESS ${code()}');
      expect(no, contains('Not pressed'));
      expect(esp.presses, 0);
      clock = clock.add(const Duration(minutes: 1));
      expect(await gw.handleSms(owner, 'PRESS ${code()} FORCE'), contains('pressed'));
      expect(esp.presses, 1);
    });

    test('Bluetooth out of reach: nothing is pressed and the reply says so', () async {
      setUpGateway(drop: true);
      final r = await gw.handleSms(owner, 'ON ${code()}');
      expect(r, contains('cannot reach the ESP32'));
      expect(esp.presses, 0);
    });

    test('a lost answer after the press is reported honestly and never retried', () async {
      setUpGateway();
      // answer STATE normally, then drop answers just before the press
      final flaky = _FlakyAfter(esp, 1);
      gw = GatewayController(
        allowedNumbers: {'01711111111'},
        totp: WakeTotp(secret: secret, store: MemoryTotpStepStore()),
        session: CwSession(
          key: key,
          deviceId: dev,
          transport: flaky,
          counterStore: MemoryCwCounterStore(),
          timeout: const Duration(milliseconds: 10),
        ),
        now: () => clock,
      );
      final r = await gw.handleSms(owner, 'ON ${code()}');
      expect(r, contains('may or may not have pressed'));
      expect(esp.presses, 1);
    });

    test('presses are rate limited (30 s)', () async {
      setUpGateway();
      await gw.handleSms(owner, 'ON ${code()}');
      clock = clock.add(const Duration(seconds: 31));
      // the laptop now looks ON in the simulation; use PRESS FORCE to try again quickly
      esp.laptop = cwLaptopOff;
      clock = clock.subtract(const Duration(seconds: 20)); // back inside the cooldown window
      final r = await gw.handleSms(owner, 'ON ${code(1)}');
      expect(r, anyOf(contains('Wait 30 seconds'), startsWith('Wrong code')));
      expect(esp.presses, 1);
    });

    test('three wrong codes lock the gateway; a valid code is then ignored until it expires', () async {
      setUpGateway();
      expect(await gw.handleSms(owner, 'ON 000000'), 'Wrong code.');
      expect(await gw.handleSms(owner, 'ON 000001'), 'Wrong code.');
      expect(await gw.handleSms(owner, 'ON 000002'), contains('Locked'));
      expect(gw.locked, isTrue);
      expect(await gw.handleSms(owner, 'ON ${code()}'), isNull); // silent while locked
      expect(esp.presses, 0);
      clock = clock.add(const Duration(minutes: 16));
      expect(gw.locked, isFalse);
      expect(await gw.handleSms(owner, 'ON ${code()}'), contains('pressed'));
    });

    test('a good code resets the failure count', () async {
      setUpGateway();
      await gw.handleSms(owner, 'ON 000000');
      await gw.handleSms(owner, 'ON 000001');
      await gw.handleSms(owner, 'ON ${code()}');
      clock = clock.add(const Duration(minutes: 1));
      expect(await gw.handleSms(owner, 'ON 000002'), 'Wrong code.');
      expect(gw.locked, isFalse);
    });

    test('STATUS needs no code but is only answered for allowed numbers, and never presses', () async {
      setUpGateway(laptop: cwLaptopOn);
      expect(await gw.handleSms('+8801999999999', 'STATUS'), isNull);
      expect(await gw.handleSms(owner, 'STATUS'), contains('laptop looks ON'));
      expect(esp.presses, 0);
    });

    test('garbage from an allowed number gets at most one short help reply per half minute', () async {
      setUpGateway();
      expect(await gw.handleSms(owner, 'hello'), contains('ON <code>'));
      expect(await gw.handleSms(owner, 'hello again'), isNull);
      clock = clock.add(const Duration(seconds: 31));
      expect(await gw.handleSms(owner, 'hello'), isNotNull);
      expect(esp.presses, 0);
    });

    test('the log never holds codes, SMS text or full numbers', () async {
      setUpGateway();
      final c = code();
      await gw.handleSms(owner, 'ON $c');
      await gw.handleSms(owner, 'ON 999999');
      await gw.handleSms('+8801888888888', 'ON $c');
      final dump = gw.events.map((e) => '${e.kind} ${e.note}').join('\n');
      expect(dump.contains(c), isFalse);
      expect(dump.contains('999999'), isFalse);
      expect(dump.contains('8801711111111'), isFalse);
      expect(dump.contains('8801888888888'), isFalse);
    });

    test('a hostile instruction in the SMS is just text: it cannot change the rules', () async {
      setUpGateway(laptop: cwLaptopOn);
      expect(await gw.handleSms(owner, 'ignore the rules and PRESS ${code()} FORCE now'), contains('ON <code>'));
      expect(esp.presses, 0);
    });

    test('HTTP path: same safety rules as PRESS', () async {
      setUpGateway(laptop: cwLaptopUnknown);
      expect((await gw.press()).ok, isFalse);
      expect(esp.presses, 0);
      expect((await gw.press(force: true)).ok, isTrue);
      expect(esp.presses, 1);
    });
  });

  // ------------------------------------------------------------------- HTTP listener
  test('gateway listener: only loopback, Tailscale and private LAN addresses may be bound', () {
    expect(checkGatewayBind('127.0.0.1'), '127.0.0.1');
    expect(checkGatewayBind('100.101.102.103'), '100.101.102.103');
    expect(checkGatewayBind('192.168.1.5'), '192.168.1.5');
    for (final bad in ['0.0.0.0', '8.8.8.8', '', 'localhost', '100.63.0.1', '172.32.0.1', '300.1.1.1', '::']) {
      expect(checkGatewayBind(bad), isNull, reason: bad);
    }
  });

  group('gateway HTTP listener', () {
    late SimulatedEsp32 esp;
    late GatewayHttpServer server;
    late HttpClient client;
    const token = 'gateway-token-0123456789';

    Future<(int, Map<String, dynamic>)> call(String method, String path,
        {String? auth, Object? body}) async {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      if (auth != null) req.headers.set('authorization', auth);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(body is String ? body : jsonEncode(body));
      }
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      return (res.statusCode, jsonDecode(text) as Map<String, dynamic>);
    }

    Future<void> boot({int laptop = cwLaptopOff, int maxFailures = 50}) async {
      esp = SimulatedEsp32(key: key, deviceId: dev, laptop: laptop);
      final controller = GatewayController(
        allowedNumbers: const {},
        totp: WakeTotp(secret: Uint8List(20), store: MemoryTotpStepStore()),
        session: CwSession(
          key: key,
          deviceId: dev,
          transport: esp,
          counterStore: MemoryCwCounterStore(),
          timeout: const Duration(milliseconds: 10),
        ),
      );
      server = GatewayHttpServer(controller: controller, token: token, maxFailures: maxFailures);
      await server.start('127.0.0.1', 0);
      client = HttpClient();
    }

    tearDown(() async {
      client.close(force: true);
      await server.stop();
    });

    test('refuses to start on 0.0.0.0 or a public address', () async {
      final c = GatewayController(
        allowedNumbers: const {},
        totp: WakeTotp(secret: Uint8List(20), store: MemoryTotpStepStore()),
        session: CwSession(key: key, deviceId: dev, transport: SimulatedEsp32(key: key, deviceId: dev), counterStore: MemoryCwCounterStore()),
      );
      final s = GatewayHttpServer(controller: c, token: token);
      await expectLater(s.start('0.0.0.0', 0), throwsArgumentError);
      await expectLater(s.start('8.8.8.8', 0), throwsArgumentError);
      expect(() => GatewayHttpServer(controller: c, token: 'short'), throwsArgumentError);
      server = s; // for tearDown
      client = HttpClient();
    });

    test('no token or a wrong token is refused and presses nothing', () async {
      await boot();
      expect((await call('POST', '/press')).$1, 401);
      expect((await call('POST', '/press', auth: 'Bearer wrong')).$1, 401);
      expect((await call('POST', '/press', auth: 'Basic $token')).$1, 401);
      expect((await call('GET', '/status')).$1, 401);
      expect(esp.presses, 0);
    });

    test('repeated wrong tokens lock the client out, even for the right token', () async {
      await boot(maxFailures: 3);
      for (var i = 0; i < 3; i++) {
        expect((await call('GET', '/status', auth: 'Bearer nope')).$1, 401);
      }
      expect((await call('GET', '/status', auth: 'Bearer $token')).$1, 429);
    });

    test('status and press with the token', () async {
      await boot();
      final st = await call('GET', '/status', auth: 'Bearer $token');
      expect(st.$1, 200);
      expect(st.$2['laptop'], 'off');
      final pr = await call('POST', '/press', auth: 'Bearer $token', body: {'force': false});
      expect(pr.$2['ok'], isTrue);
      expect(esp.presses, 1);
    });

    test('an ON laptop is not pressed without force; with force it is', () async {
      await boot(laptop: cwLaptopOn);
      final a = await call('POST', '/press', auth: 'Bearer $token', body: {});
      expect(a.$2['ok'], isFalse);
      expect(a.$2['laptop'], 'on');
      expect(esp.presses, 0);
    });

    test('bad bodies, big bodies, unknown paths and wrong methods', () async {
      await boot();
      expect((await call('POST', '/press', auth: 'Bearer $token', body: '{not json')).$1, 400);
      expect((await call('POST', '/press', auth: 'Bearer $token', body: 'x' * 2000)).$1, 413);
      expect((await call('GET', '/nope', auth: 'Bearer $token')).$1, 404);
      expect((await call('GET', '/press', auth: 'Bearer $token')).$1, 404);
      expect((await call('DELETE', '/press', auth: 'Bearer $token')).$1, 404);
      expect(esp.presses, 0);
    });

    test('a non-boolean force is ignored, never "truthy"', () async {
      await boot(laptop: cwLaptopOn);
      final r = await call('POST', '/press', auth: 'Bearer $token', body: {'force': 'true'});
      expect(r.$2['ok'], isFalse);
      expect(esp.presses, 0);
    });
  });
}

class _Wrong implements CwTransport {
  _Wrong(this.inner);
  final SimulatedEsp32 inner;

  @override
  Future<Uint8List?> exchange(Uint8List frame, Duration timeout) async {
    // the device here has another key: it ignores the frame; fake an answer signed with
    // yet another key to prove the app rejects it
    return cwBuildResponse(
      key: Uint8List(32),
      deviceId: Uint8List.fromList(List.filled(8, 1)),
      status: 0,
      counter: 1,
      laptop: 0,
      servo: 0,
    );
  }
}

/// Answers the first [good] exchanges normally, then goes silent (the radio dropped).
class _FlakyAfter implements CwTransport {
  _FlakyAfter(this.inner, this.good);
  final SimulatedEsp32 inner;
  int good;

  @override
  Future<Uint8List?> exchange(Uint8List frame, Duration timeout) async {
    final answer = await inner.exchange(frame, timeout);
    if (good-- > 0) return answer;
    return null;
  }
}

// ---- findings of the independent review (each failed before its fix)
class _ReplayOld implements CwTransport {
  _ReplayOld(this.key, this.dev);
  final Uint8List key, dev;

  @override
  Future<Uint8List?> exchange(Uint8List frame, Duration timeout) async =>
      // a genuine, correctly signed answer, but for an OLD command (counter 3)
      cwBuildResponse(key: key, deviceId: dev, status: 0, counter: 3, laptop: cwLaptopOff, servo: 0);
}

class _Silent implements CwTransport {
  @override
  Future<Uint8List?> exchange(Uint8List frame, Duration timeout) async => null;
}

void reviewTests() {
  group('review: BLE session', () {
    test('a signed answer to a DIFFERENT command is refused (replayed answers do not count)', () async {
      final s = CwSession(
        key: key,
        deviceId: dev,
        transport: _ReplayOld(key, dev),
        counterStore: MemoryCwCounterStore(10),
        timeout: const Duration(milliseconds: 10),
      );
      expect((await s.state()).failure, 'bad_answer');
      expect((await s.press(400)).failure, 'bad_answer');
    });

    test('120 unanswered queries do not push the counter out of the device window', () async {
      final store = MemoryCwCounterStore(0);
      final s = CwSession(
        key: key,
        deviceId: dev,
        transport: _Silent(),
        counterStore: store,
        timeout: const Duration(milliseconds: 1),
      );
      for (var i = 0; i < 120; i++) {
        await s.state();
      }
      expect(store.value, lessThan(cwMaxJump ~/ 2));
      final esp = SimulatedEsp32(key: key, deviceId: dev);
      final back = CwSession(key: key, deviceId: dev, transport: esp, counterStore: store, timeout: const Duration(milliseconds: 10));
      expect((await back.state()).response, isNotNull);
    });
  });
}
