import 'package:cortex_one/api/api_client.dart';
import 'package:cortex_one/api/models.dart';
import 'package:cortex_one/l10n/strings.dart';
import 'package:cortex_one/state/computer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Finder key(String k) => find.byKey(Key(k));

const comp = Computer(
  id: 'a1',
  name: 'Laptop',
  endpoints: ['http://100.64.0.9:8765'],
  token: 'tok',
);

GuiSnapshot running({int left = 180, int used = 2, String? shot = 'gui-0a1b2c3d-1.jpg'}) => GuiSnapshot(
  active: true,
  enabled: true,
  remainingSeconds: left,
  actionsUsed: used,
  maxActions: 60,
  lastShot: shot,
  actions: const [
    GuiActionRow(n: 1, action: 'gui_screenshot', ok: true, detail: '640x480', shot: 'gui-0a1b2c3d-1.jpg'),
    GuiActionRow(n: 2, action: 'gui_key', ok: false, detail: 'A blocked app is in front.'),
  ],
);

Future<void> scrollTo(WidgetTester tester, String k) async {
  await tester.scrollUntilVisible(key(k), 300, scrollable: find.byType(Scrollable).first);
  await tester.pump();
}

Future<Harness> home(WidgetTester tester, {FakeApi? api, FakeBiometric? bio}) async {
  final h = Harness(api: api, biometric: bio, computers: [comp]);
  await h.pump(tester);
  await flush(tester);
  await scrollTo(tester, 'tools_expansion');
  await tester.tap(key('tools_expansion'));
  await flush(tester);
  return h;
}

void main() {
  group('starting a GUI session', () {
    testWidgets('shows the unverified warning and what will happen, then needs the biometric', (tester) async {
      final h = await home(tester);
      expect(find.text(S('bn').t('gui_note')), findsOneWidget);
      expect(find.textContaining('অপরীক্ষিত'), findsWidgets);
      await scrollTo(tester, 'gui_start');
      await tester.tap(key('gui_start'));
      await flush(tester);
      expect(find.text(S('bn').tf('will_gui_start', {'n': 3})), findsOneWidget);
      expect(h.api.requested, isEmpty);
      await tester.tap(key('tools_dialog_confirm'));
      await flush(tester);
      expect(h.biometric.reasons.length, 1);
      expect(h.api.requested, ['gui_session_start']);
      expect(h.api.confirmed, ['gui_session_start:ticket-gui_session_start']);
      expect(h.api.confirmedParams.single, {'minutes': '3'});
    });

    testWidgets('the minutes choice is sent as the parameter', (tester) async {
      final h = await home(tester);
      await scrollTo(tester, 'gui_minutes');
      await tester.tap(key('gui_minutes'));
      await flush(tester);
      await tester.tap(find.text('10').last);
      await flush(tester);
      await scrollTo(tester, 'gui_start');
      await tester.tap(key('gui_start'));
      await flush(tester);
      await tester.tap(key('tools_dialog_confirm'));
      await flush(tester);
      expect(h.api.confirmedParams.single, {'minutes': '10'});
    });

    testWidgets('cancel or a refused biometric starts nothing', (tester) async {
      final bio = FakeBiometric()..allow = false;
      final h = await home(tester, bio: bio);
      await scrollTo(tester, 'gui_start');
      await tester.tap(key('gui_start'));
      await flush(tester);
      await tester.tap(key('tools_dialog_cancel'));
      await flush(tester);
      expect(bio.reasons, isEmpty);
      await tester.tap(key('gui_start'));
      await flush(tester);
      await tester.tap(key('tools_dialog_confirm'));
      await flush(tester);
      expect(bio.reasons.length, 1);
      expect(h.api.requested, isEmpty);
      expect(key('gui_stop_button'), findsNothing);
    });

    testWidgets('after an accepted start the session screen opens', (tester) async {
      final api = FakeApi()..guiSnapshot = running();
      await home(tester, api: api);
      await scrollTo(tester, 'gui_start');
      await tester.tap(key('gui_start'));
      await flush(tester);
      await tester.tap(key('tools_dialog_confirm'));
      await flush(tester);
      expect(key('gui_stop_button'), findsOneWidget);
    });
  });

  group('the session screen', () {
    Future<Harness> open(WidgetTester tester, FakeApi api) async {
      final h = await home(tester, api: api);
      await scrollTo(tester, 'gui_open');
      await tester.tap(key('gui_open'));
      await flush(tester);
      return h;
    }

    testWidgets('shows state, countdown, actions used, picture and the action list', (tester) async {
      final api = FakeApi()..guiSnapshot = running(left: 125);
      await open(tester, api);
      expect(find.text('সেশন চলছে'), findsOneWidget);
      expect(find.text('বাকি সময়: 2:05'), findsOneWidget);
      expect(find.text('কাজ: 2/60'), findsOneWidget);
      expect(key('gui_picture'), findsOneWidget);
      expect(api.calls, contains('gui_shot:gui-0a1b2c3d-1.jpg'));
      expect(find.textContaining('gui_screenshot'), findsOneWidget);
      expect(find.textContaining('A blocked app is in front.'), findsOneWidget);
    });

    testWidgets('the countdown ticks every second', (tester) async {
      final api = FakeApi()..guiSnapshot = running(left: 100);
      await open(tester, api);
      await tester.pump(const Duration(seconds: 1)); // before the next poll re-syncs with the agent
      expect(find.text('বাকি সময়: 1:39'), findsOneWidget);
    });

    testWidgets('STOP is big, always enabled and needs no confirmation', (tester) async {
      final api = FakeApi()..guiSnapshot = running();
      final h = await open(tester, api);
      final size = tester.getSize(key('gui_stop_button'));
      expect(size.height, greaterThanOrEqualTo(64));
      await tester.tap(key('gui_stop_button'));
      await flush(tester);
      expect(api.calls, contains('action:gui_session_stop'));
      expect(api.requested, isEmpty);
      expect(h.biometric.reasons, isEmpty);
      expect(find.text('সেশন শেষ'), findsOneWidget);
      expect(find.textContaining('stopped by the owner'), findsOneWidget);
    });

    testWidgets('if stopping fails the emergency stop is tried', (tester) async {
      final api = _StopFails()..guiSnapshot = running();
      await open(tester, api);
      await tester.tap(key('gui_stop_button'));
      await flush(tester);
      expect(api.calls, contains('emergency'));
    });

    testWidgets('an ended session is shown with its reason and polling stops', (tester) async {
      final api = FakeApi()
        ..guiSnapshot = const GuiSnapshot(active: false, enabled: true, actionsUsed: 60, maxActions: 60, endedReason: 'action limit reached');
      await open(tester, api);
      expect(find.text('সেশন শেষ'), findsOneWidget);
      expect(find.textContaining('action limit reached'), findsOneWidget);
      final polls = api.calls.where((c) => c == 'gui_session').length;
      await tester.pump(const Duration(seconds: 10));
      expect(api.calls.where((c) => c == 'gui_session').length, polls);
    });

    testWidgets('an unreachable agent shows a plain error', (tester) async {
      final api = FakeApi()..guiError = const ApiException(ApiErrorKind.network);
      await open(tester, api);
      expect(key('gui_error'), findsOneWidget);
      expect(key('gui_stop_button'), findsOneWidget); // STOP stays available
    });

    testWidgets('the warning that this is unverified is on the screen too', (tester) async {
      final api = FakeApi()..guiSnapshot = running();
      await open(tester, api);
      await tester.scrollUntilVisible(find.text(S('bn').t('gui_note')).last, 300,
          scrollable: find.byType(Scrollable).last);
      expect(find.text(S('bn').t('gui_note')), findsWidgets);
    });
  });

  testWidgets('a GUI session request from the AI has a readable pending card', (tester) async {
    final api = FakeApi()
      ..pendingItems = [
        const PendingItem(
          confirmToken: 'g1',
          action: 'gui_session_start',
          params: {'minutes': '5'},
          summary: 'Let the AI operate the mouse and keyboard for 5 minute(s).',
          command: [],
          expiresIn: 50,
        ),
      ];
    final h = Harness(api: api, computers: [comp]);
    await h.pump(tester);
    await flush(tester);
    await tester.tap(find.byIcon(Icons.verified_user_outlined));
    await flush(tester);
    expect(find.text('GUI সেশন চালু'), findsOneWidget);
    expect(find.textContaining('operate the mouse and keyboard'), findsOneWidget);
    // confirming it needs the biometric like everything else
    await tester.tap(key('pending_confirm'));
    await flush(tester);
    expect(h.biometric.reasons.length, 1);
  });
}

class _StopFails extends FakeApi {
  @override
  Future<ActionOutcome> runAction(String name, [Map<String, String> params = const {}]) async {
    if (name == 'gui_session_stop') throw const ApiException(ApiErrorKind.timeout);
    return super.runAction(name, params);
  }
}
