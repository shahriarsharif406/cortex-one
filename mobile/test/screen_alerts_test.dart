import 'package:cortex_one/api/api_client.dart';
import 'package:cortex_one/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> openScreenTab(WidgetTester tester) async {
  await tester.tap(find.byType(NavigationDestination).at(4));
  await tester.pump();
  await tester.pump();
}

AlertEntry alert(String kind, {int id = 1, int pct = 55, Duration ago = Duration.zero}) =>
    AlertEntry(
      id: id,
      time: DateTime.now().subtract(ago),
      kind: kind,
      message: 'raw message',
      batteryPercent: pct,
      plugged: kind == 'ac_restored',
    );

void main() {
  group('screen viewer', () {
    testWidgets('refresh takes a screenshot, then shows it view-only', (
      tester,
    ) async {
      final h = Harness();
      await h.pump(tester);
      await openScreenTab(tester);
      expect(find.byKey(const Key('screen_empty')), findsOneWidget);
      expect(find.byKey(const Key('screen_data_note')), findsOneWidget);

      await tester.tap(find.byKey(const Key('screen_refresh')));
      await flush(tester);

      expect(h.api.calls, contains('action:take_screenshot'));
      expect(h.api.calls.last, startsWith('shot:screenshot-20260101-100001.png:1000'));
      expect(find.byKey(const Key('screen_image')), findsOneWidget);
      // pinch zoom is an InteractiveViewer; nothing on screen sends taps back
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byKey(const Key('emergency_stop_button')), findsOneWidget);
    });

    testWidgets('auto-refresh is off by default and has a clear switch', (
      tester,
    ) async {
      final h = Harness();
      await h.pump(tester);
      await openScreenTab(tester);
      final sw = tester.widget<SwitchListTile>(
        find.byKey(const Key('screen_auto_switch')),
      );
      expect(sw.value, isFalse);
      await tester.pump(const Duration(seconds: 70));
      expect(h.api.calls.where((c) => c == 'action:take_screenshot'), isEmpty);
    });

    testWidgets('auto-refresh repeats on the interval and stops when switched off', (
      tester,
    ) async {
      final h = Harness();
      await h.pump(tester);
      await openScreenTab(tester);
      await tester.tap(find.byKey(const Key('screen_auto_switch')));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 10));
        await flush(tester);
      }
      final taken = h.api.calls.where((c) => c == 'action:take_screenshot').length;
      expect(taken, 3);

      await tester.tap(find.byKey(const Key('screen_auto_switch')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 60));
      expect(
        h.api.calls.where((c) => c == 'action:take_screenshot').length,
        taken,
      );
    });

    testWidgets('leaving the tab stops the timer', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await openScreenTab(tester);
      await tester.tap(find.byKey(const Key('screen_auto_switch')));
      await tester.pump();
      await tester.tap(find.byType(NavigationDestination).at(0));
      await tester.pump();
      await tester.pump(const Duration(seconds: 120));
      expect(h.api.calls.where((c) => c == 'action:take_screenshot'), isEmpty);
    });

    testWidgets('an error is shown and auto-refresh switches itself off', (
      tester,
    ) async {
      final h = Harness();
      h.api.screenshotError = const ApiException(ApiErrorKind.network);
      await h.pump(tester);
      await openScreenTab(tester);
      await tester.tap(find.byKey(const Key('screen_auto_switch')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      await flush(tester);
      expect(find.byKey(const Key('screen_error')), findsOneWidget);
      expect(find.textContaining('ল্যাপটপের সাথে যোগাযোগ হয়নি'), findsWidgets);
      final sw = tester.widget<SwitchListTile>(
        find.byKey(const Key('screen_auto_switch')),
      );
      expect(sw.value, isFalse);
    });

    testWidgets('a revoked token sends the user back to pairing', (tester) async {
      final h = Harness();
      h.api.screenshotActionError = const ApiException(ApiErrorKind.unauthorized);
      await h.pump(tester);
      await openScreenTab(tester);
      await tester.tap(find.byKey(const Key('screen_refresh')));
      await flush(tester);
      expect(find.byKey(const Key('pair_notice')), findsOneWidget);
      expect(h.secrets.values.containsKey('device_token'), isFalse);
    });

    testWidgets('English text is available', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await h.state.setLang('en');
      await tester.pump();
      await openScreenTab(tester);
      expect(find.textContaining('mobile data'), findsOneWidget);
      expect(find.text('Laptop screen (view only)'), findsOneWidget);
    });
  });

  group('alerts', () {
    testWidgets('no banner when there are no alerts', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await flush(tester);
      expect(find.byKey(const Key('power_banner')), findsNothing);
    });

    testWidgets('a power cut shows a banner on the home screen', (tester) async {
      final h = Harness();
      h.api.alertRows = [alert('ac_lost', pct: 61)];
      await h.pump(tester);
      await flush(tester);
      expect(find.byKey(const Key('power_banner')), findsOneWidget);
      expect(find.textContaining('কারেন্ট গেছে'), findsOneWidget);
      expect(find.textContaining('61%'), findsOneWidget);
    });

    testWidgets('power restored or an old alert shows no banner', (tester) async {
      final h = Harness();
      h.api.alertRows = [alert('ac_restored')];
      await h.pump(tester);
      await flush(tester);
      expect(find.byKey(const Key('power_banner')), findsNothing);

      final h2 = Harness();
      h2.api.alertRows = [alert('battery_critical', ago: const Duration(hours: 30))];
      await h2.pump(tester);
      await flush(tester);
      expect(find.byKey(const Key('power_banner')), findsNothing);
    });

    testWidgets('an agent without /alerts does not break the home screen', (
      tester,
    ) async {
      final h = Harness();
      h.api.alertsError = const ApiException(ApiErrorKind.notFound);
      await h.pump(tester);
      await flush(tester);
      expect(find.byKey(const Key('power_banner')), findsNothing);
      expect(find.text('ল্যাপটপের অবস্থা'), findsOneWidget);
    });

    testWidgets('the alerts screen lists them and keeps the emergency stop', (
      tester,
    ) async {
      final h = Harness();
      h.api.alertRows = [
        alert('battery_critical', id: 3, pct: 8),
        alert('ac_lost', id: 2, pct: 40),
        alert('ac_restored', id: 1, pct: 90),
      ];
      await h.pump(tester);
      await flush(tester);
      await tester.tap(find.byKey(const Key('alerts_open')));
      await flush(tester);
      expect(find.text('বিদ্যুৎ ও ব্যাটারি সতর্কতা'), findsOneWidget);
      expect(find.byKey(const Key('alert_3')), findsOneWidget);
      expect(find.byKey(const Key('alert_1')), findsOneWidget);
      expect(find.textContaining('ব্যাটারি খুবই কম (8%)'), findsWidgets);
      expect(find.byKey(const Key('emergency_stop_button')), findsWidgets);
    });

    testWidgets('the alerts screen has an empty and an error state', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await flush(tester);
      await tester.tap(find.byKey(const Key('alerts_open')));
      await flush(tester);
      expect(find.byKey(const Key('alerts_empty')), findsOneWidget);

      final h2 = Harness();
      h2.api.alertsError = const ApiException(ApiErrorKind.timeout);
      await h2.pump(tester);
      await flush(tester);
      await tester.tap(find.byKey(const Key('alerts_open')));
      await flush(tester);
      expect(find.byKey(const Key('alerts_error')), findsOneWidget);
    });
  });

  group('connection errors while pairing', () {
    Future<void> submit(WidgetTester tester, Harness h,
        {String server = '100.64.1.2'}) async {
      await h.pump(tester);
      await tester.enterText(find.byKey(const Key('server_field')), server);
      await tester.enterText(find.byKey(const Key('code_field')), '123456');
      await tester.tap(find.byKey(const Key('pair_button')));
      await tester.pump();
      await tester.pump();
    }

    for (final c in <(String, Object, String)>[
      ('laptop offline', const ApiException(ApiErrorKind.network), 'ল্যাপটপ পর্যন্ত পৌঁছানো যায়নি'),
      ('timed out', const ApiException(ApiErrorKind.timeout), 'ল্যাপটপ পর্যন্ত পৌঁছানো যায়নি'),
      ('wrong address (404)', const ApiException(ApiErrorKind.notFound), 'এজেন্ট পাওয়া যায়নি'),
      ('wrong address (not JSON)', const ApiException(ApiErrorKind.badResponse), 'এজেন্ট পাওয়া যায়নি'),
      ('wrong or expired code', const ApiException(ApiErrorKind.forbidden), 'পেয়ারিং কোড ভুল বা মেয়াদ শেষ'),
      ('lockout', const ApiException(ApiErrorKind.rateLimited), 'পেয়ারিং ৫ মিনিটের জন্য আটকানো'),
    ]) {
      testWidgets(c.$1, (tester) async {
        final h = Harness(paired: false);
        h.api.pairError = c.$2;
        await submit(tester, h);
        expect(find.byKey(const Key('pair_error')), findsOneWidget);
        expect(find.textContaining(c.$3), findsOneWidget);
        expect(h.secrets.values, isEmpty);
      });
    }

    testWidgets('a public http address is refused before any request', (tester) async {
      final h = Harness(paired: false);
      await submit(tester, h, server: 'http://example.com');
      expect(find.textContaining('শুধু নিজের নেটওয়ার্কের ঠিকানা'), findsOneWidget);
      expect(h.api.calls, isEmpty);
    });

    testWidgets('a garbled address gets the plain address error', (tester) async {
      final h = Harness(paired: false);
      await submit(tester, h, server: 'ftp://x');
      expect(find.text('ঠিকানা সঠিক নয়। উদাহরণ: 100.64.1.2:8765'), findsOneWidget);
    });
  });

  group('expired token', () {
    testWidgets('401 on any call returns to pairing with an explanation', (
      tester,
    ) async {
      final h = Harness();
      h.api.alertsError = const ApiException(ApiErrorKind.unauthorized);
      await h.pump(tester);
      await flush(tester);
      await tester.tap(find.byKey(const Key('alerts_open')));
      await flush(tester);
      expect(find.byKey(const Key('pair_notice')), findsOneWidget);
      expect(find.textContaining('মেয়াদ শেষ বা বাতিল'), findsOneWidget);
    });
  });

  group('host guard', () {
    test('plain http only on private, tailscale and loopback hosts', () {
      for (final ok in [
        '100.64.0.1', '100.127.255.254', '10.1.2.3', '192.168.0.9',
        '172.16.0.1', '172.31.9.9', '127.0.0.1', 'localhost', 'pc.tail1.ts.net',
      ]) {
        expect(isPrivateOrTailscaleHost(ok), isTrue, reason: ok);
      }
      for (final bad in [
        '8.8.8.8', '100.63.0.1', '100.128.0.1', '172.15.0.1', '172.32.0.1',
        '192.169.0.1', '11.0.0.1', 'example.com', 'ts.net.evil.com',
        '300.1.1.1', '10.0.0',
      ]) {
        expect(isPrivateOrTailscaleHost(bad), isFalse, reason: bad);
      }
    });

    test('normalizeServerAddress refuses http to public hosts but allows https', () {
      expect(normalizeServerAddress('http://example.com'), isNull);
      expect(normalizeServerAddress('8.8.8.8'), isNull);
      expect(normalizeServerAddress('https://example.com'), 'https://example.com:8765');
      expect(normalizeServerAddress('100.64.1.2'), 'http://100.64.1.2:8765');
    });
  });
}
