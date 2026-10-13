import 'dart:async';

import 'package:cortex_one/api/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('the big red emergency stop is on screen on the home tab', (
    tester,
  ) async {
    final h = Harness();
    await h.pump(tester);
    expect(find.byKey(const Key('emergency_stop_button')), findsOneWidget);
    expect(find.text('জরুরি বন্ধ'), findsOneWidget);
  });

  testWidgets('it stays visible on every tab', (tester) async {
    final h = Harness();
    await h.pump(tester);
    for (final tab in [1, 2, 3, 0]) {
      await tester.tap(find.byType(NavigationDestination).at(tab));
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('emergency_stop_button')),
        findsOneWidget,
        reason: 'tab $tab',
      );
    }
  });

  testWidgets('one tap stops everything, with no confirmation dialog', (
    tester,
  ) async {
    final h = Harness();
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('emergency_stop_button')));
    await tester.pump();
    await tester.pump();
    expect(h.api.calls.where((c) => c == 'emergency').length, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.textContaining('থামানো হয়েছে'), findsOneWidget);
  });

  testWidgets(
    'it works while a confirmation is open and does not confirm anything',
    (tester) async {
      final h = Harness();
      await h.pump(tester);
      await tester.tap(find.byKey(const Key('emergency_stop_button')));
      await tester.pump();
      await tester.pump();
      expect(h.api.calls.any((c) => c.startsWith('confirm')), isFalse);
    },
  );

  testWidgets('cannot be double-fired while the first request is in flight', (
    tester,
  ) async {
    final h = Harness();
    h.api.emergencyGate = Completer<void>();
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('emergency_stop_button')));
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('emergency_stop_button')),
    );
    expect(button.onPressed, isNull);
    h.api.emergencyGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(h.api.calls.where((c) => c == 'emergency').length, 1);
    // ready again afterwards
    final again = tester.widget<FilledButton>(
      find.byKey(const Key('emergency_stop_button')),
    );
    expect(again.onPressed, isNotNull);
  });

  testWidgets(
    'if the laptop is unreachable the failure is loud and in Bangla',
    (tester) async {
      final h = Harness();
      h.api.emergencyError = const ApiException(ApiErrorKind.network);
      await h.pump(tester);
      await tester.tap(find.byKey(const Key('emergency_stop_button')));
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('ল্যাপটপের সাথে যোগাযোগ হয়নি'),
        findsOneWidget,
      );
      // the user can try again
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('emergency_stop_button')),
      );
      expect(button.onPressed, isNotNull);
    },
  );

  testWidgets('English label', (tester) async {
    final h = Harness();
    await h.state.setLang('en');
    await h.pump(tester);
    expect(find.text('EMERGENCY STOP'), findsOneWidget);
  });
}
