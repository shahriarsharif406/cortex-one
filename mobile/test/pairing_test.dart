import 'package:cortex_one/api/api_client.dart';
import 'package:flutter/material.dart';
import 'package:cortex_one/state/computer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> fillAndSubmit(
  WidgetTester tester, {
  String server = '100.64.1.2',
  String code = '123456',
}) async {
  await tester.enterText(find.byKey(const Key('server_field')), server);
  await tester.enterText(find.byKey(const Key('code_field')), code);
  await tester.tap(find.byKey(const Key('pair_button')));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('unpaired app shows the pairing screen in Bangla', (
    tester,
  ) async {
    final h = Harness(paired: false);
    await h.pump(tester);
    expect(find.text('ল্যাপটপের সাথে যুক্ত করুন'), findsWidgets);
    expect(find.byKey(const Key('emergency_stop_button')), findsNothing);
  });

  testWidgets('pairing stores the token only in the secure store', (
    tester,
  ) async {
    final h = Harness(paired: false);
    await h.pump(tester);
    await fillAndSubmit(tester);
    await tester.pump();

    expect(h.api.calls, contains('pair:123456'));
    final stored = decodeComputers(h.secrets.values['computers']);
    expect(stored.single.token, 'tok-secret-123');
    expect(stored.single.endpoints, ['http://100.64.1.2:8765']);
    expect(h.secrets.values.containsKey('device_token'), isFalse); // old keys are gone
    // never in plain preferences
    expect(h.prefs.values.values.join(' ').contains('tok-secret-123'), isFalse);
    expect(h.prefs.values.keys.any((k) => k.contains('token')), isFalse);
    // and we are now on the home screen
    expect(find.byKey(const Key('emergency_stop_button')), findsOneWidget);
    expect(find.byKey(const Key('pair_button')), findsNothing);
    // the API object used after pairing carries the new token
    expect(h.factoryCalls.last, ('http://100.64.1.2:8765', 'tok-secret-123'));
  });

  testWidgets('bad code format is rejected before any network call', (
    tester,
  ) async {
    final h = Harness(paired: false);
    await h.pump(tester);
    await fillAndSubmit(tester, code: '123');
    expect(find.text('কোড অবশ্যই ৬টি অঙ্ক হতে হবে।'), findsOneWidget);
    expect(h.api.calls, isEmpty);
    expect(h.secrets.values, isEmpty);
  });

  testWidgets('code field only accepts digits and at most six', (tester) async {
    final h = Harness(paired: false);
    await h.pump(tester);
    await tester.enterText(find.byKey(const Key('code_field')), '12ab34567');
    final field = tester.widget<TextFormField>(
      find.byKey(const Key('code_field')),
    );
    expect(field.controller!.text, '123456');
  });

  testWidgets('invalid server address shows a clear message', (tester) async {
    final h = Harness(paired: false);
    await h.pump(tester);
    await fillAndSubmit(tester, server: 'not a host');
    expect(find.text('ঠিকানা সঠিক নয়। উদাহরণ: 100.64.1.2:8765'), findsWidgets);
    expect(h.api.calls, isEmpty);
  });

  testWidgets('wrong or expired code shows a Bangla error and stores nothing', (
    tester,
  ) async {
    final h = Harness(paired: false);
    h.api.pairError = const ApiException(
      ApiErrorKind.forbidden,
      statusCode: 403,
    );
    await h.pump(tester);
    await fillAndSubmit(tester);
    expect(find.byKey(const Key('pair_error')), findsOneWidget);
    expect(find.textContaining('পেয়ারিং কোড ভুল বা মেয়াদ শেষ'), findsOneWidget);
    expect(h.secrets.values, isEmpty);
    expect(find.byKey(const Key('pair_button')), findsOneWidget);
  });

  testWidgets('unreachable laptop shows the Bangla network error', (
    tester,
  ) async {
    final h = Harness(paired: false);
    h.api.pairError = const ApiException(ApiErrorKind.network);
    await h.pump(tester);
    await fillAndSubmit(tester);
    expect(find.textContaining('ল্যাপটপ পর্যন্ত পৌঁছানো যায়নি'), findsOneWidget);
    expect(find.textContaining('Tailscale'), findsWidgets);
  });

  testWidgets('pairing lockout (429) is explained', (tester) async {
    final h = Harness(paired: false);
    h.api.pairError = const ApiException(
      ApiErrorKind.rateLimited,
      statusCode: 429,
    );
    await h.pump(tester);
    await fillAndSubmit(tester);
    expect(find.textContaining('পেয়ারিং ৫ মিনিটের জন্য আটকানো'), findsOneWidget);
  });

  testWidgets('language toggle switches the pairing screen to English', (
    tester,
  ) async {
    final h = Harness(paired: false);
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('language_toggle')));
    await tester.pump();
    expect(find.text('Connect to your laptop'), findsWidgets);
    expect(h.prefs.values['lang'], 'en');
  });

  testWidgets('a stored token skips pairing', (tester) async {
    final h = Harness();
    await h.pump(tester);
    expect(find.byKey(const Key('pair_button')), findsNothing);
    expect(find.byKey(const Key('emergency_stop_button')), findsOneWidget);
    expect(h.factoryCalls.first, ('http://100.64.0.9:8765', 'stored-token'));
  });

  testWidgets(
    'a revoked token (401) sends the user back to pairing with a notice',
    (tester) async {
      final h = Harness();
      h.api.info = {};
      await h.pump(tester);
      await h.state.onError(
        const ApiException(ApiErrorKind.unauthorized, statusCode: 401),
      );
      await tester.pump();
      expect(find.byKey(const Key('pair_button')), findsOneWidget);
      expect(find.byKey(const Key('pair_notice')), findsOneWidget);
      expect(h.secrets.values, isEmpty);
    },
  );
}
