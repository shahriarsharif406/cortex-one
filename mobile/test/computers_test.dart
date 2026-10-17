import 'dart:async';

import 'package:cortex_one/api/api_client.dart';
import 'package:cortex_one/api/failover_api.dart';
import 'package:cortex_one/api/health.dart';
import 'package:cortex_one/api/models.dart';
import 'package:cortex_one/api/wake_gateway_client.dart';
import 'package:cortex_one/l10n/strings.dart';
import 'package:cortex_one/state/computer.dart';
import 'package:cortex_one/state/device_services.dart';
import 'package:cortex_one/state/power_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const tsUrl = 'http://100.64.0.9:8765';
const lanUrl = 'http://192.168.1.20:8765';

Computer comp(
  String id,
  String name, {
  List<String> endpoints = const [tsUrl],
  String? wakeVia,
  WakeGateway? gateway,
  bool lan = false,
}) => Computer(
  id: id,
  name: name,
  endpoints: endpoints,
  token: 'tok-$id',
  allowLanHttp: lan,
  wakeVia: wakeVia,
  wakeGateway: gateway,
);

Finder key(String k) => find.byKey(Key(k));

void main() {
  // ------------------------------------------------------------- power state
  group('classifyPower', () {
    final now = DateTime(2026, 10, 17, 12);
    final seen = now.subtract(const Duration(minutes: 5));
    Health h({int? pct, bool? plugged, LastPowerRequest? p}) => Health(
      computerId: 'a',
      computerName: 'L',
      version: '1',
      batteryPercent: pct,
      plugged: plugged,
      lastPower: p,
    );

    test('reachable is online', () {
      expect(
        classifyPower(reachable: true, now: now).state,
        PowerState.online,
      );
    });
    test('never heard from it is unknown, not offline', () {
      final st = classifyPower(reachable: false, now: now);
      expect(st.state, PowerState.unknown);
      expect(st.reason, PowerReason.neverSeen);
    });
    test('a sleep request from this phone after the last answer means sleeping', () {
      final st = classifyPower(
        reachable: false,
        now: now,
        lastSeen: seen,
        phoneHint: PowerHint('sleep', seen.add(const Duration(minutes: 1))),
      );
      expect(st.state, PowerState.sleeping);
      expect(st.reason, PowerReason.sleepRequested);
    });
    test('hibernate also reads as sleeping, shutdown as offline', () {
      PowerStatus with_(String a) => classifyPower(
        reachable: false,
        now: now,
        lastSeen: seen,
        phoneHint: PowerHint(a, seen),
      );
      expect(with_('hibernate').state, PowerState.sleeping);
      expect(with_('shutdown').state, PowerState.offline);
      expect(with_('shutdown').reason, PowerReason.shutdownRequested);
    });
    test('the agent-reported last power request is used when the phone made none', () {
      final st = classifyPower(
        reachable: false,
        now: now,
        lastSeen: seen,
        lastHealth: h(p: const LastPowerRequest(action: 'sleep', ageSeconds: 10)),
      );
      expect(st.state, PowerState.sleeping);
    });
    test('an old request from before the last answer is ignored', () {
      final st = classifyPower(
        reachable: false,
        now: now,
        lastSeen: seen,
        phoneHint: PowerHint('sleep', seen.subtract(const Duration(hours: 3))),
      );
      expect(st.state, PowerState.offline);
      expect(st.reason, PowerReason.noAnswer);
    });
    test('a request older than 12 hours is no longer trusted', () {
      final st = classifyPower(
        reachable: false,
        now: now,
        lastSeen: now.subtract(const Duration(hours: 20)),
        phoneHint: PowerHint('sleep', now.subtract(const Duration(hours: 20))),
      );
      expect(st.reason, PowerReason.noAnswer);
    });
    test('low unplugged battery explains a silent computer', () {
      final st = classifyPower(
        reachable: false,
        now: now,
        lastSeen: seen,
        lastHealth: h(pct: 4, plugged: false),
      );
      expect(st.reason, PowerReason.batteryLow);
      expect(
        classifyPower(
          reachable: false,
          now: now,
          lastSeen: seen,
          lastHealth: h(pct: 4, plugged: true),
        ).reason,
        PowerReason.noAnswer,
      );
    });
    test('restart is only trusted for ten minutes', () {
      expect(
        classifyPower(
          reachable: false,
          now: now,
          lastSeen: seen,
          phoneHint: PowerHint('restart', now.subtract(const Duration(minutes: 2))),
        ).reason,
        PowerReason.restartRequested,
      );
      expect(
        classifyPower(
          reachable: false,
          now: now,
          lastSeen: seen.subtract(const Duration(minutes: 30)),
          phoneHint: PowerHint('restart', now.subtract(const Duration(minutes: 30))),
        ).reason,
        PowerReason.noAnswer,
      );
    });
  });

  // ----------------------------------------------------------- computer data
  group('Computer storage', () {
    test('round trip keeps every field', () {
      final c = comp(
        'a1',
        'Laptop',
        endpoints: [tsUrl, lanUrl],
        wakeVia: 'Desktop',
        gateway: const WakeGateway(address: 'http://100.64.0.7:8780', token: 'gw'),
        lan: true,
      ).copyWith(rustdeskId: '123456789');
      final back = decodeComputers(encodeComputers([c])).single;
      expect(back.endpoints, [tsUrl, lanUrl]);
      expect(back.wakeVia, 'Desktop');
      expect(back.wakeGateway!.token, 'gw');
      expect(back.allowLanHttp, isTrue);
      expect(back.rustdeskId, '123456789');
    });
    test('garbage is dropped, never trusted', () {
      expect(decodeComputers('not json'), isEmpty);
      expect(decodeComputers('{"a":1}'), isEmpty);
      expect(
        decodeComputers('[1, {"id":"x"}, {"id":"x","name":"n","token":"","endpoints":["http://100.64.0.1:1"]},'
            '{"id":"y","name":"n","token":"t","endpoints":[]}]'),
        isEmpty,
      );
    });
    test('copyWith can clear wakeVia', () {
      expect(comp('a', 'A', wakeVia: 'B').copyWith(wakeVia: null).wakeVia, isNull);
    });
  });

  group('addresses', () {
    test('LAN http needs the explicit acknowledgement', () {
      expect(normalizeServerAddress('192.168.1.20'), isNull);
      expect(normalizeServerAddress('192.168.1.20', allowLan: true), lanUrl);
      expect(normalizeServerAddress('10.0.0.5:9000', allowLan: true), 'http://10.0.0.5:9000');
      expect(normalizeServerAddress('172.20.1.1', allowLan: true), isNotNull);
    });
    test('public http stays refused even with the acknowledgement', () {
      expect(normalizeServerAddress('8.8.8.8', allowLan: true), isNull);
      expect(normalizeServerAddress('172.32.0.1', allowLan: true), isNull);
      expect(normalizeServerAddress('example.com', allowLan: true), isNull);
      expect(normalizeServerAddress('https://example.com', allowLan: true), isNotNull);
    });
    test('link kinds', () {
      expect(linkKindOfUrl(tsUrl), 'tailscale');
      expect(linkKindOfUrl(lanUrl), 'lan');
      expect(linkKindOfUrl('http://127.0.0.1:8765'), 'loopback');
      expect(linkKindOfUrl('http://laptop.tail1234.ts.net:8765'), 'tailscale');
      expect(linkKindOfUrl('https://example.com'), 'other');
    });
  });

  // ---------------------------------------------------------- endpoint failover
  group('FailoverApi', () {
    FailoverApi make(Map<String, FakeApi> apis, {String? last, List<String>? worked, DateTime Function()? now}) =>
        FailoverApi(
          endpoints: [tsUrl, lanUrl],
          token: 't',
          factory: (u, t) => apis[u]!,
          lastWorking: last,
          attemptTimeout: const Duration(milliseconds: 200),
          onWorked: worked?.add,
          now: now,
        );

    test('falls back to the next address when the first is unreachable', () async {
      final ts = FakeApi()..healthError = const ApiException(ApiErrorKind.network);
      final lan = FakeApi();
      final worked = <String>[];
      final api = make({tsUrl: ts, lanUrl: lan}, worked: worked);
      final h = await api.health();
      expect(h.computerName, 'Laptop');
      expect(ts.healthCalls, 1);
      expect(lan.healthCalls, 1);
      expect(api.activeEndpoint, lanUrl);
      expect(api.activeKind, 'lan');
      expect(worked, [lanUrl]);
    });

    test('remembers the last working address and tries it first', () async {
      final ts = FakeApi();
      final lan = FakeApi();
      final api = make({tsUrl: ts, lanUrl: lan}, last: lanUrl);
      await api.health();
      expect(lan.healthCalls, 1);
      expect(ts.healthCalls, 0);
    });

    test('an answer that is an error does not move to another address', () async {
      final ts = FakeApi()..healthError = const ApiException(ApiErrorKind.unauthorized);
      final lan = FakeApi();
      final api = make({tsUrl: ts, lanUrl: lan});
      await expectLater(
        api.health(),
        throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.unauthorized)),
      );
      expect(lan.healthCalls, 0);
    });

    test('when no address answers the error is the network error', () async {
      final ts = FakeApi()..healthError = const ApiException(ApiErrorKind.network);
      final lan = FakeApi()..healthError = const ApiException(ApiErrorKind.timeout);
      final api = make({tsUrl: ts, lanUrl: lan});
      await expectLater(
        api.health(),
        throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.timeout)),
      );
    });

    test('a hanging address times out quickly and the next one is used', () async {
      final ts = _Hanging();
      final lan = FakeApi();
      final api = make({tsUrl: ts, lanUrl: lan});
      expect((await api.health()).computerName, 'Laptop');
      expect(api.activeEndpoint, lanUrl);
    });

    test('a change (shutdown, confirm) goes to ONE address and is never retried elsewhere', () async {
      final ts = FakeApi()..healthError = const ApiException(ApiErrorKind.network);
      final lan = FakeApi();
      final api = make({tsUrl: ts, lanUrl: lan});
      // the freshness probe finds that the first address is down and selects the LAN one
      final r = await api.requestAction('shutdown');
      expect(r.ticket, isNotNull);
      expect(ts.requested, isEmpty);
      expect(lan.requested, ['shutdown']);
    });

    test('a failing write is not repeated on the other address', () async {
      var t = DateTime(2026, 1, 1);
      final ts = FakeApi()..requestError = const ApiException(ApiErrorKind.network);
      final lan = FakeApi();
      final api = make({tsUrl: ts, lanUrl: lan}, now: () => t);
      await api.health(); // ts healthy? no: health works on both; ts answers first
      expect(api.activeEndpoint, tsUrl);
      await expectLater(api.requestAction('shutdown'), throwsA(isA<ApiException>()));
      expect(lan.requested, isEmpty); // not retried elsewhere
    });
  });

  // ----------------------------------------------------- app: computers & link
  group('app', () {
    testWidgets('an older single-computer install is migrated and its old keys are removed', (tester) async {
      final h = Harness();
      await h.pump(tester);
      final stored = decodeComputers(h.secrets.values['computers']);
      expect(stored.single.endpoints, ['http://100.64.0.9:8765']);
      expect(stored.single.token, 'stored-token');
      expect(h.secrets.values.containsKey('device_token'), isFalse);
      expect(h.secrets.values.containsKey('server_address'), isFalse);
    });

    testWidgets('home shows the computer name, an online badge and the battery', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      expect(tester.widget<Text>(key('appbar_title')).data, 'Laptop');
      expect(find.descendant(of: key('state_badge'), matching: find.text('অনলাইন')), findsOneWidget);
      expect(find.textContaining('77%'), findsWidgets);
    });

    testWidgets('an unreachable computer is offline and says what the phone cannot know', (tester) async {
      final api = FakeApi()..healthError = const ApiException(ApiErrorKind.network);
      final h = Harness(api: api, computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      expect(find.descendant(of: key('state_badge'), matching: find.text('অজানা')), findsOneWidget);
      expect(find.text(S('bn').t('reason_never')), findsOneWidget);
    });

    testWidgets('after a phone-made sleep request the badge says "probably asleep"', (tester) async {
      final api = FakeApi();
      final h = Harness(api: api, computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      await tester.tap(key('power_sleep'));
      await flush(tester);
      await tester.tap(key('power_dialog_confirm'));
      await flush(tester);
      expect(api.confirmed, ['sleep:ticket-sleep']);
      // now the computer stops answering
      api.healthError = const ApiException(ApiErrorKind.timeout);
      await tester.tap(key('state_refresh'));
      await flush(tester);
      expect(find.descendant(of: key('state_badge'), matching: find.text('ঘুমিয়ে আছে (সম্ভবত)')), findsOneWidget);
      expect(key('state_reason'), findsOneWidget);
    });

    testWidgets('failover: the LAN address is used when Tailscale does not answer, and shown', (tester) async {
      final ts = FakeApi()..healthError = const ApiException(ApiErrorKind.network);
      final lan = FakeApi();
      final h = Harness(
        apis: {tsUrl: ts, lanUrl: lan},
        computers: [comp('a1', 'Laptop', endpoints: [tsUrl, lanUrl], lan: true)],
      );
      await h.pump(tester);
      await flush(tester);
      expect(lan.healthCalls, greaterThan(0));
      expect(find.text(S('bn').t('link_lan')), findsOneWidget);
      expect(h.secrets.values['last_ep_a1'], lanUrl); // remembered
    });

    testWidgets('failover: Tailscale is shown when it answers', (tester) async {
      final h = Harness(
        apis: {tsUrl: FakeApi(), lanUrl: FakeApi()},
        computers: [comp('a1', 'Laptop', endpoints: [tsUrl, lanUrl], lan: true)],
      );
      await h.pump(tester);
      await flush(tester);
      expect(find.text(S('bn').t('link_tailscale')), findsOneWidget);
    });

    testWidgets('a stored last-working address is tried first after a restart', (tester) async {
      final ts = FakeApi();
      final lan = FakeApi();
      final h = Harness(
        apis: {tsUrl: ts, lanUrl: lan},
        computers: [comp('a1', 'Laptop', endpoints: [tsUrl, lanUrl], lan: true)],
      );
      h.secrets.values['last_ep_a1'] = lanUrl;
      await h.pump(tester);
      await flush(tester);
      expect(lan.healthCalls, greaterThan(0));
      expect(ts.healthCalls, 0);
    });

    testWidgets('two computers: the switcher lists both, tapping one changes the home', (tester) async {
      final a = FakeApi();
      final b = FakeApi()
        ..healthAnswer = const Health(computerId: 'b', computerName: 'Desktop', version: '1');
      final h = Harness(
        apis: {tsUrl: a, 'http://100.64.0.10:8765': b},
        computers: [
          comp('a1', 'Laptop'),
          comp('b2', 'Desktop', endpoints: ['http://100.64.0.10:8765']),
        ],
      );
      await h.pump(tester);
      await flush(tester);
      await tester.tap(key('computer_switcher'));
      await flush(tester);
      expect(find.text('Laptop'), findsWidgets);
      expect(find.text('Desktop'), findsWidgets);
      await tester.tap(key('computer_tile_b2'));
      await flush(tester);
      expect(tester.widget<Text>(key('appbar_title')).data, 'Desktop');
      expect(h.prefs.values['current_computer'], 'b2');
    });

    testWidgets('removing the last computer returns to pairing and clears the token', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      await tester.tap(key('computer_switcher'));
      await flush(tester);
      await tester.tap(key('computer_edit_a1'));
      await flush(tester);
      await tester.tap(key('edit_remove'));
      await flush(tester);
      await tester.tap(key('computer_remove_yes'));
      await flush(tester);
      expect(key('pair_button'), findsOneWidget);
      expect(h.secrets.values.containsKey('computers'), isFalse);
    });

    testWidgets('pairing a second computer with a LAN address needs the acknowledgement', (tester) async {
      final h = Harness(paired: false);
      await h.pump(tester);
      await tester.enterText(key('server_field'), '100.64.1.2');
      await tester.enterText(key('code_field'), '123456');
      await tester.tap(key('pair_more'));
      await tester.pump();
      await tester.enterText(key('pair_lan_field'), '192.168.1.20');
      await tester.tap(key('pair_button'));
      await flush(tester);
      expect(find.text(S('bn').t('server_lan_needs_ok')), findsOneWidget);
      expect(h.api.calls.where((c) => c.startsWith('pair')), isEmpty); // nothing was sent
      await tester.tap(key('pair_lan_ok'));
      await tester.pump();
      await tester.tap(key('pair_button'));
      await flush(tester);
      final c = decodeComputers(h.secrets.values['computers']).single;
      expect(c.endpoints, ['http://100.64.1.2:8765', lanUrl]);
      expect(c.allowLanHttp, isTrue);
    });

    testWidgets('editing a computer re-validates addresses and keeps wake settings', (tester) async {
      final h = Harness(computers: [
        comp('a1', 'Laptop'),
        comp('b2', 'Desktop', endpoints: ['http://100.64.0.10:8765']),
      ]);
      await h.pump(tester);
      await flush(tester);
      await tester.tap(key('computer_switcher'));
      await flush(tester);
      await tester.tap(key('computer_edit_a1'));
      await flush(tester);
      await tester.enterText(key('edit_endpoints'), '8.8.8.8');
      await tester.tap(key('edit_save'));
      await flush(tester);
      expect(key('edit_error'), findsOneWidget);
      await tester.enterText(key('edit_endpoints'), '$tsUrl\n$lanUrl');
      await tester.tap(key('edit_save'));
      await flush(tester);
      expect(key('edit_error'), findsOneWidget, reason: 'LAN needs the checkbox');
      await tester.tap(key('edit_lan_ok'));
      await tester.pump();
      await tester.tap(key('edit_save'));
      await flush(tester);
      final c = decodeComputers(h.secrets.values['computers']).first;
      expect(c.endpoints, [tsUrl, lanUrl]);
    });
  });

  // --------------------------------------------------------------- power card
  group('power card', () {
    Future<Harness> home(WidgetTester tester, {FakeBiometric? bio, FakeApi? api}) async {
      final h = Harness(api: api, biometric: bio, computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      return h;
    }

    testWidgets('every power button is there', (tester) async {
      await home(tester);
      for (final k in ['wake', 'sleep', 'hibernate', 'shutdown', 'restart', 'lock']) {
        expect(key('power_$k'), findsOneWidget, reason: k);
      }
    });

    for (final action in ['sleep', 'hibernate', 'shutdown', 'restart']) {
      testWidgets('$action shows what will happen and nothing is sent until confirmed', (tester) async {
        final h = await home(tester);
        await tester.tap(key('power_$action'));
        await flush(tester);
        expect(key('power_dialog_$action'), findsOneWidget);
        expect(find.text(S('bn').t('will_$action')), findsOneWidget);
        expect(h.api.requested, isEmpty);
        await tester.tap(key('power_dialog_cancel'));
        await flush(tester);
        expect(h.api.requested, isEmpty);
        expect(h.biometric.reasons, isEmpty);
      });

      testWidgets('$action needs the biometric, then runs the two-step confirmation', (tester) async {
        final h = await home(tester);
        await tester.tap(key('power_$action'));
        await flush(tester);
        await tester.tap(key('power_dialog_confirm'));
        await flush(tester);
        expect(h.biometric.reasons.length, 1);
        expect(h.api.requested, [action]);
        expect(h.api.confirmed, ['$action:ticket-$action']);
      });

      testWidgets('$action is NOT sent when the biometric is refused', (tester) async {
        final bio = FakeBiometric()..allow = false;
        final h = await home(tester, bio: bio);
        await tester.tap(key('power_$action'));
        await flush(tester);
        await tester.tap(key('power_dialog_confirm'));
        await flush(tester);
        expect(bio.reasons.length, 1);
        expect(h.api.requested, isEmpty);
        expect(h.api.confirmed, isEmpty);
        expect(find.text(S('bn').t('auth_failed')), findsOneWidget);
      });
    }

    testWidgets('lock runs at once without a dialog', (tester) async {
      final h = await home(tester);
      await tester.tap(key('power_lock'));
      await flush(tester);
      expect(h.api.calls, contains('action:lock'));
      expect(h.api.requested, isEmpty);
    });

    testWidgets('a failed request shows a safe error and does not remember a power request', (tester) async {
      final api = FakeApi()..requestError = const ApiException(ApiErrorKind.timeout);
      final h = await home(tester, api: api);
      await tester.tap(key('power_sleep'));
      await flush(tester);
      await tester.tap(key('power_dialog_confirm'));
      await flush(tester);
      expect(api.confirmed, isEmpty);
      expect(find.text(S('bn').t('err_timeout')), findsOneWidget);
      expect(h.prefs.values.entries.any((e) => e.key.startsWith('seen_') && e.value.contains('hint')), isFalse);
    });
  });

  // ------------------------------------------------------------------ wake UX
  group('wake', () {
    Future<void> open(WidgetTester tester, Harness h) async {
      await h.pump(tester);
      await flush(tester);
      // the computer must be offline for the sheet to open
      h.api.healthError = const ApiException(ApiErrorKind.network);
      await tester.tap(key('state_refresh'));
      await flush(tester);
      await tester.tap(key('power_wake'));
      await flush(tester);
    }

    const gw = WakeGateway(address: 'http://100.64.0.7:8780', token: 'gw-token');

    testWidgets('all three methods are listed, in order, with honest text', (tester) async {
      final desk = FakeApi();
      final h = Harness(
        apis: {'http://100.64.0.10:8765': desk},
        computers: [
          comp('a1', 'Laptop', wakeVia: 'Desktop', gateway: gw),
          comp('b2', 'Desktop', endpoints: ['http://100.64.0.10:8765']),
        ],
      );
      await open(tester, h);
      final via = tester.getTopLeft(key('wake_method_via')).dy;
      final gateway = tester.getTopLeft(key('wake_method_gateway')).dy;
      final sms = tester.getTopLeft(key('wake_method_sms')).dy;
      expect(via < gateway && gateway < sms, isTrue);
      expect(find.textContaining('Desktop'), findsWidgets);
      expect(find.text(S('bn').t('wake_gateway_needs')), findsOneWidget);
      expect(find.text(S('bn').t('wake_sms_needs')), findsOneWidget);
      expect(find.text(S('bn').t('wake_intro')), findsOneWidget);
    });

    testWidgets('with nothing set up only SMS is offered, and the sheet says so', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      await open(tester, h);
      expect(key('wake_method_via'), findsNothing);
      expect(key('wake_method_gateway'), findsNothing);
      expect(key('wake_method_sms'), findsOneWidget);
      expect(key('wake_none'), findsOneWidget);
    });

    testWidgets('a wake-via name that is not in the app is not offered', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop', wakeVia: 'Ghost')]);
      await open(tester, h);
      expect(key('wake_method_via'), findsNothing);
    });

    testWidgets('wake via the helper computer asks THAT computer to wake this one by name', (tester) async {
      final desk = FakeApi();
      final h = Harness(
        apis: {'http://100.64.0.10:8765': desk},
        computers: [
          comp('a1', 'Laptop', wakeVia: 'Desktop'),
          comp('b2', 'Desktop', endpoints: ['http://100.64.0.10:8765']),
        ],
      );
      await open(tester, h);
      await tester.tap(key('wake_method_via'));
      await flush(tester);
      expect(desk.calls, contains('action:wake_computer'));
      expect(desk.actionParams.last, {'name': 'laptop'});
      expect(find.text(S('bn').t('wake_sent')), findsOneWidget);
    });

    testWidgets('online computers are not "woken"', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      await tester.tap(key('power_wake'));
      await flush(tester);
      expect(find.text(S('bn').t('wake_online_already')), findsOneWidget);
      expect(key('wake_sheet'), findsNothing);
    });

    testWidgets('gateway: sensor says OFF -> press without force, after the biometric', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop', gateway: gw)]);
      await open(tester, h);
      await tester.tap(key('wake_method_gateway'));
      await flush(tester);
      expect(h.biometric.reasons.length, 1);
      expect(h.gateway.calls, ['status', 'press:force=false']);
    });

    testWidgets('gateway: sensor says ON -> the button is NOT pressed', (tester) async {
      final h = Harness(
        computers: [comp('a1', 'Laptop', gateway: gw)],
        gateway: FakeGateway()
          ..statusAnswer = const GatewayResult(ok: true, message: 'ok', laptopState: 'on'),
      );
      await open(tester, h);
      await tester.tap(key('wake_method_gateway'));
      await flush(tester);
      expect(h.gateway.calls, ['status']);
      expect(find.text(S('bn').t('wake_laptop_on')), findsOneWidget);
    });

    testWidgets('gateway: unknown state asks for an explicit force and presses only on yes', (tester) async {
      final fg = FakeGateway()
        ..statusAnswer = const GatewayResult(ok: true, message: 'ok', laptopState: 'unknown');
      final h = Harness(computers: [comp('a1', 'Laptop', gateway: gw)], gateway: fg);
      await open(tester, h);
      await tester.tap(key('wake_method_gateway'));
      await flush(tester);
      expect(key('wake_force_dialog'), findsOneWidget);
      expect(fg.calls, ['status']);
      await tester.tap(key('wake_force_yes'));
      await flush(tester);
      expect(fg.calls, ['status', 'press:force=true']);
    });

    testWidgets('gateway: biometric refused -> nothing contacted', (tester) async {
      final bio = FakeBiometric()..allow = false;
      final h = Harness(computers: [comp('a1', 'Laptop', gateway: gw)], biometric: bio);
      await open(tester, h);
      await tester.tap(key('wake_method_gateway'));
      await flush(tester);
      expect(h.gateway.calls, isEmpty);
    });

    testWidgets('gateway: an unreachable gateway is reported, not hidden', (tester) async {
      final fg = FakeGateway()
        ..statusAnswer = const GatewayResult(ok: false, message: 'The gateway phone is not reachable.')
        ..pressAnswer = const GatewayResult(ok: false, message: 'The gateway phone is not reachable.');
      final h = Harness(computers: [comp('a1', 'Laptop', gateway: gw)], gateway: fg);
      await open(tester, h);
      await tester.tap(key('wake_method_gateway'));
      await flush(tester);
      await tester.tap(key('wake_force_yes'));
      await flush(tester);
      expect(find.textContaining('not reachable'), findsOneWidget);
    });

    testWidgets('SMS opens the SMS app with ON only; the code is never typed by the app', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      h.prefs.values['sms_number'] = '+8801711111111';
      await open(tester, h);
      await tester.tap(key('wake_method_sms'));
      await flush(tester);
      expect(h.launched.single.scheme, 'sms');
      expect(h.launched.single.toString(), contains('body=ON%20'));
      expect(RegExp(r'\d{6}').hasMatch(Uri.decodeFull(h.launched.single.query)), isFalse);
    });

    testWidgets('SMS without a gateway number asks for it first', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      await open(tester, h);
      await tester.tap(key('wake_method_sms'));
      await flush(tester);
      expect(h.launched, isEmpty);
      expect(find.text(S('bn').t('wake_no_sms')), findsOneWidget);
    });
  });

  // --------------------------------------------------------------- data saver
  group('data saver', () {
    Future<void> openScreen(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.monitor_outlined));
      await flush(tester);
    }

    testWidgets('normal: full quality screenshots', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      await openScreen(tester);
      await tester.tap(key('screen_refresh'));
      await flush(tester);
      expect(h.api.screenshotLow, [false]);
      expect(h.api.actionParams.last, isEmpty);
      expect(h.api.calls.last, startsWith('shot:'));
      expect(h.api.calls.last.endsWith(':1000'), isTrue);
    });

    testWidgets('switch ON: low-quality request, small width, no auto-refresh', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      await tester.tap(find.descendant(of: key('data_saver_mode'), matching: find.text('চালু')));
      await flush(tester);
      expect(h.prefs.values['data_saver'], 'on');
      expect(key('data_saver_active'), findsOneWidget);
      await openScreen(tester);
      await tester.tap(key('screen_refresh'));
      await flush(tester);
      expect(h.api.screenshotLow, [true]);
      expect(h.api.actionParams.last, {'quality': 'low'});
      expect(h.api.calls.last.endsWith(':640'), isTrue);
      // the auto-refresh switch cannot be turned on while the saver is active
      await tester.tap(key('screen_auto_switch'));
      await flush(tester);
      final sw = tester.widget<SwitchListTile>(key('screen_auto_switch'));
      expect(sw.value, isFalse);
    });

    testWidgets('auto: turns itself on when the phone is on the SIM and shows the SIM link', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      expect(key('data_saver_active'), findsNothing);
      h.link.emit(const LinkSnapshot(onMobile: true));
      await flush(tester);
      expect(key('data_saver_active'), findsOneWidget);
      expect(find.text(S('bn').t('link_sim')), findsOneWidget);
      await openScreen(tester);
      await tester.tap(key('screen_refresh'));
      await flush(tester);
      expect(h.api.screenshotLow.last, isTrue);
    });

    testWidgets('manual OFF wins over the SIM', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      h.link.now = const LinkSnapshot(onMobile: true);
      await h.pump(tester);
      await flush(tester);
      expect(h.state.dataSaver, isTrue);
      await tester.tap(find.descendant(of: key('data_saver_mode'), matching: find.text('বন্ধ')));
      await flush(tester);
      expect(h.state.dataSaver, isFalse);
      expect(key('data_saver_active'), findsNothing);
    });

    testWidgets('the saver stops the background health polling', (tester) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      final m = h.state.monitorFor(h.state.current!);
      expect(m.autoRefresh, isTrue);
      await h.state.setDataSaverMode('on');
      expect(m.autoRefresh, isFalse);
      await h.state.setDataSaverMode('off');
      expect(m.autoRefresh, isTrue);
    });
  });

  // --------------------------------------------------------------- confirmations
  group('every confirmation needs the biometric', () {
    testWidgets('confirming a pending AI request asks first and does nothing when refused', (tester) async {
      final bio = FakeBiometric()..allow = false;
      final api = FakeApi()
        ..pendingItems = [
          const PendingItemFactory().make('tok1', 'shutdown'),
        ];
      final h = Harness(api: api, biometric: bio, computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      await tester.tap(find.byIcon(Icons.verified_user_outlined));
      await flush(tester);
      await tester.tap(key('pending_confirm'));
      await flush(tester);
      expect(bio.reasons.length, 1);
      expect(api.calls.where((c) => c.startsWith('confirm:')), isEmpty);
      expect(find.text(S('bn').t('auth_failed')), findsWidgets);
      // then it works once the owner passes the prompt
      bio.allow = true;
      await tester.tap(key('pending_confirm'));
      await flush(tester);
      expect(api.calls, contains('confirm:tok1'));
    });

    testWidgets('a sleep request from the AI has its own readable card', (tester) async {
      final api = FakeApi()
        ..pendingItems = [const PendingItemFactory().make('tok2', 'sleep')];
      final h = Harness(api: api, computers: [comp('a1', 'Laptop')]);
      await h.pump(tester);
      await flush(tester);
      await tester.tap(find.byIcon(Icons.verified_user_outlined));
      await flush(tester);
      expect(find.text('স্লিপ নিশ্চিত করুন'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------- voice
  group('voice without internet', () {
    Future<Harness> start(WidgetTester tester, {LinkSnapshot? snap}) async {
      final h = Harness(computers: [comp('a1', 'Laptop')]);
      if (snap != null) h.link.now = snap;
      await h.pump(tester);
      await flush(tester);
      return h;
    }

    testWidgets('online: the normal recogniser is used', (tester) async {
      final h = await start(tester);
      await tester.tap(key('mic_button'));
      await flush(tester);
      expect(h.voice.onDeviceUsed, isFalse);
    });

    testWidgets('no network at all: on-device recognition is used automatically', (tester) async {
      final h = await start(tester, snap: const LinkSnapshot(offline: true));
      await tester.tap(key('mic_button'));
      await flush(tester);
      expect(h.voice.onDeviceUsed, isTrue);
    });

    testWidgets('the owner can force on-device recognition', (tester) async {
      final h = await start(tester);
      await tester.ensureVisible(key('voice_offline_switch'));
      await tester.tap(key('voice_offline_switch'));
      await flush(tester);
      expect(h.prefs.values['voice_offline'], 'on');
      await tester.tap(key('mic_button'));
      await flush(tester);
      expect(h.voice.onDeviceUsed, isTrue);
    });

    testWidgets('recognised words only fill the box; nothing is sent', (tester) async {
      final h = await start(tester, snap: const LinkSnapshot(offline: true));
      await tester.tap(key('mic_button'));
      await flush(tester);
      h.voice.sink!('স্ক্রিনশট নাও', true);
      await flush(tester);
      expect(find.text('স্ক্রিনশট নাও'), findsOneWidget);
      expect(h.api.calls.where((c) => c.startsWith('start:')), isEmpty);
    });

    testWidgets('the hint explains how to get the Bangla offline pack', (tester) async {
      await start(tester);
      await tester.ensureVisible(key('voice_offline_help'));
      await tester.tap(key('voice_offline_help'));
      await flush(tester);
      expect(find.textContaining('Offline speech recognition'), findsOneWidget);
      expect(find.textContaining('বাংলা (বাংলাদেশ)'), findsOneWidget);
    });
  });

  test('both languages have the same keys (session 2 strings included)', () {
    expect(S.bnKeys, S.enKeys);
    for (final k in ['p_wake', 'wake_via', 'ds_title', 'auth_failed', 'voice_offline_body']) {
      expect(S.bnKeys.contains(k), isTrue, reason: k);
    }
  });
}

class _Hanging extends FakeApi {
  @override
  Future<Health> health() => Completer<Health>().future; // never answers
}

/// A tiny helper so the test above reads clearly.
class PendingItemFactory {
  const PendingItemFactory();

  PendingItem make(String token, String action) => PendingItem(
    confirmToken: token,
    action: action,
    params: const {},
    summary: 'Do $action now',
    command: const [],
    expiresIn: 50,
  );
}
