import 'package:cortex_one/api/api_client.dart';
import 'package:cortex_one/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const scriptItem = PendingItem(
  confirmToken: 'tokS',
  action: 'run_script',
  params: {'name': 'backup'},
  summary: "Run the approved script 'backup'",
  command: ['powershell', '-File', r'C:\cortex\scripts\backup.ps1'],
  expiresIn: 45,
);
const shutdownItem = PendingItem(
  confirmToken: 'tokD',
  action: 'shutdown',
  params: {},
  summary: 'Shut down the laptop in 30 seconds',
  command: [],
  expiresIn: 40,
);

Future<Harness> openPending(
  WidgetTester tester,
  List<PendingItem> items, {
  Harness? harness,
}) async {
  final h = harness ?? Harness();
  h.api.pendingItems = List.of(items);
  await h.pump(tester);
  await tester.pump(); // first background refresh
  await tester.tap(find.byType(NavigationDestination).at(1));
  await tester.pump();
  await tester.pump();
  return h;
}

void main() {
  testWidgets('shows exactly what a script will run, with a countdown', (
    tester,
  ) async {
    await openPending(tester, [scriptItem]);
    expect(find.text('স্ক্রিপ্ট চালানো'), findsOneWidget);
    expect(find.text('স্ক্রিপ্ট: backup'), findsOneWidget);
    expect(find.text('ঠিক যা চালানো হবে:'), findsOneWidget);
    expect(
      find.text(r'powershell -File C:\cortex\scripts\backup.ps1'),
      findsOneWidget,
    );
    expect(find.text('মেয়াদ বাকি: 45 সেকেন্ড'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('মেয়াদ বাকি: 42 সেকেন্ড'), findsOneWidget);
  });

  testWidgets(
    'shutdown card names the action and the confirm button says what it does',
    (tester) async {
      await openPending(tester, [shutdownItem]);
      expect(find.text('ল্যাপটপ বন্ধ করা'), findsOneWidget);
      expect(find.text('Shut down the laptop in 30 seconds'), findsOneWidget);
      expect(find.text('হ্যাঁ, বন্ধ করুন'), findsOneWidget);
      expect(find.text('বাতিল'), findsWidgets);
    },
  );

  testWidgets('merely viewing a request never confirms it', (tester) async {
    final h = await openPending(tester, [shutdownItem, scriptItem]);
    await tester.pump(
      const Duration(seconds: 12),
    ); // background refreshes happen
    expect(h.api.calls.where((c) => c.startsWith('confirm')), isEmpty);
    expect(h.api.pendingItems.length, 2);
  });

  testWidgets('confirm sends the single-use token and removes the card', (
    tester,
  ) async {
    final h = await openPending(tester, [shutdownItem]);
    await tester.tap(find.byKey(const Key('pending_confirm')));
    await tester.pump();
    await tester.pump();
    expect(h.api.calls.where((c) => c.startsWith('confirm')).toList(), [
      'confirm:tokD',
    ]);
    expect(find.byKey(const Key('pending_card_tokD')), findsNothing);
    expect(find.text('নিশ্চিত করা হয়েছে'), findsOneWidget); // snackbar
    expect(find.byKey(const Key('pending_empty')), findsOneWidget);
  });

  testWidgets('cancel discards the request without running it', (tester) async {
    final h = await openPending(tester, [scriptItem]);
    await tester.tap(find.byKey(const Key('pending_cancel')));
    await tester.pump();
    await tester.pump();
    expect(h.api.calls.where((c) => c.startsWith('cancel')).toList(), [
      'cancel:tokS',
    ]);
    expect(h.api.calls.any((c) => c.startsWith('confirm')), isFalse);
    expect(find.byKey(const Key('pending_card_tokS')), findsNothing);
  });

  testWidgets('an expired request cannot be confirmed', (tester) async {
    final h = await openPending(tester, [
      const PendingItem(
        confirmToken: 'tokE',
        action: 'restart',
        params: {},
        summary: 'Restart the laptop in 30 seconds',
        command: [],
        expiresIn: 2,
      ),
    ]);
    h.api.pendingItems = []; // the agent has dropped it too
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('মেয়াদ শেষ'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('pending_confirm')),
    );
    expect(button.onPressed, isNull);
    expect(h.api.calls.any((c) => c.startsWith('confirm')), isFalse);
  });

  testWidgets(
    'a rejected token (403) shows a Bangla error and the stale card goes away',
    (tester) async {
      final h = Harness();
      h.api.confirmError = const ApiException(
        ApiErrorKind.forbidden,
        statusCode: 403,
      );
      await openPending(tester, [shutdownItem], harness: h);
      await tester.tap(find.byKey(const Key('pending_confirm')));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('কোড বা নিশ্চিতকরণ ভুল, মেয়াদ শেষ, বা আগেই ব্যবহার হয়েছে।'),
        findsWidgets,
      );
      expect(find.byKey(const Key('pending_card_tokD')), findsNothing);
    },
  );

  testWidgets(
    'a network error keeps the card so the owner can retry before it expires',
    (tester) async {
      final h = Harness();
      h.api.confirmError = const ApiException(ApiErrorKind.network);
      await openPending(tester, [shutdownItem], harness: h);
      await tester.tap(find.byKey(const Key('pending_confirm')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('ল্যাপটপের সাথে যোগাযোগ হয়নি'), findsWidgets);
      expect(find.byKey(const Key('pending_card_tokD')), findsOneWidget);
      // retry works
      h.api.confirmError = null;
      await tester.tap(find.byKey(const Key('pending_confirm')));
      await tester.pump();
      await tester.pump();
      expect(h.api.calls.where((c) => c.startsWith('confirm')).length, 2);
    },
  );

  testWidgets('empty state', (tester) async {
    await openPending(tester, []);
    expect(find.byKey(const Key('pending_empty')), findsOneWidget);
    expect(find.text('এখন কোনো অনুরোধ অপেক্ষায় নেই।'), findsOneWidget);
  });

  testWidgets('the same screen works in English', (tester) async {
    final h = Harness();
    await h.state.setLang('en');
    await openPending(tester, [scriptItem], harness: h);
    expect(find.text('Run a script'), findsOneWidget);
    expect(find.text('Exactly what will run:'), findsOneWidget);
    expect(find.text('Expires in 45 s'), findsOneWidget);
    expect(find.text('Yes, run the script'), findsOneWidget);
  });
}
