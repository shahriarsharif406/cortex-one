import 'package:cortex_one/api/models.dart';
import 'package:cortex_one/l10n/strings.dart';
import 'package:cortex_one/state/computer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Finder key(String k) => find.byKey(Key(k));

Computer comp({String? rustdesk}) => Computer(
  id: 'a1',
  name: 'Laptop',
  endpoints: const ['http://100.64.0.9:8765'],
  token: 'tok',
  rustdeskId: rustdesk,
);

Future<Harness> home(WidgetTester tester, {FakeApi? api, FakeBiometric? bio, String? rustdesk}) async {
  final h = Harness(api: api, biometric: bio, computers: [comp(rustdesk: rustdesk)]);
  await h.pump(tester);
  await flush(tester);
  await openTools(tester);
  return h;
}

Future<void> openTools(WidgetTester tester) async {
  await tester.scrollUntilVisible(key('tools_expansion'), 300,
      scrollable: find.byType(Scrollable).first);
  await tester.pump();
  await tester.tap(key('tools_expansion'));
  await flush(tester);
}

Future<void> tap(WidgetTester tester, String k) async {
  await tester.scrollUntilVisible(key(k), 300, scrollable: find.byType(Scrollable).first);
  await tester.pump();
  await tester.tap(key(k));
  await flush(tester);
}

void main() {
  group('coding sessions', () {
    FakeApi withRows() => FakeApi()
      ..codingRows = [
        {'project': 'api', 'state': 'not started'},
        {'project': 'docs', 'state': 'running', 'minutes': 5},
        {'project': 'old', 'state': 'exited', 'exit_code': 3},
      ];

    testWidgets('the list shows each project with its state', (tester) async {
      await home(tester, api: withRows());
      await tap(tester, 'coding_refresh');
      expect(find.text('চালু হয়নি'), findsOneWidget);
      expect(find.text('চলছে'), findsOneWidget);
      expect(find.text('শেষ হয়েছে (কোড 3)'), findsOneWidget);
      expect(key('coding_start_api'), findsOneWidget);
      expect(key('coding_stop_docs'), findsOneWidget);
    });

    testWidgets('no projects: a plain explanation', (tester) async {
      await home(tester);
      await tap(tester, 'coding_refresh');
      expect(key('coding_none'), findsOneWidget);
    });

    testWidgets('start: what-will-happen dialog, then biometric, then the two-step confirmation', (tester) async {
      final api = withRows();
      final h = await home(tester, api: api);
      await tap(tester, 'coding_refresh');
      await tap(tester, 'coding_start_api');
      expect(key('tools_dialog_coding_session_start'), findsOneWidget);
      expect(find.textContaining('"api"'), findsWidgets);
      expect(api.requested, isEmpty);
      await tester.tap(key('tools_dialog_confirm'));
      await flush(tester);
      expect(h.biometric.reasons.length, 1);
      expect(api.requested, ['coding_session_start']);
      expect(api.confirmed, ['coding_session_start:ticket-coding_session_start']);
      expect(api.confirmedParams.single, {'name': 'api'});
    });

    testWidgets('cancel sends nothing; a refused biometric sends nothing', (tester) async {
      final api = withRows();
      final bio = FakeBiometric()..allow = false;
      final h = await home(tester, api: api, bio: bio);
      await tap(tester, 'coding_refresh');
      await tap(tester, 'coding_start_api');
      await tester.tap(key('tools_dialog_cancel'));
      await flush(tester);
      expect(api.requested, isEmpty);
      expect(bio.reasons, isEmpty);
      await tap(tester, 'coding_start_api');
      await tester.tap(key('tools_dialog_confirm'));
      await flush(tester);
      expect(bio.reasons.length, 1);
      expect(api.requested, isEmpty);
      expect(find.text(S('bn').t('auth_failed')), findsOneWidget);
      expect(h.api.confirmed, isEmpty);
    });

    testWidgets('stop works the same way for a running session', (tester) async {
      final api = withRows();
      await home(tester, api: api);
      await tap(tester, 'coding_refresh');
      await tap(tester, 'coding_stop_docs');
      expect(find.textContaining('"docs"'), findsWidgets);
      await tester.tap(key('tools_dialog_confirm'));
      await flush(tester);
      expect(api.confirmed, ['coding_session_stop:ticket-coding_session_stop']);
      expect(api.confirmedParams.single, {'name': 'docs'});
    });
  });

  group('remote desktop', () {
    testWidgets('Open RustDesk launches its own link with the stored ID only', (tester) async {
      final h = await home(tester, rustdesk: '123456789');
      await tap(tester, 'rd_open');
      expect(h.launched.single.toString(), 'rustdesk://connect/123456789');
    });

    testWidgets('without an ID it asks for one and launches nothing', (tester) async {
      final h = await home(tester);
      await tap(tester, 'rd_open');
      expect(h.launched, isEmpty);
      expect(find.text(S('bn').t('rd_need_id')), findsOneWidget);
    });

    testWidgets('a phone without RustDesk gets a plain message', (tester) async {
      final h = Harness(computers: [comp(rustdesk: '123456789')])..launchResult = false;
      await h.pump(tester);
      await flush(tester);
      await openTools(tester);
      await tap(tester, 'rd_open');
      expect(find.text(S('bn').t('rd_open_failed')), findsOneWidget);
    });

    testWidgets('status asks the agent (read-only, no confirmation)', (tester) async {
      final h = await home(tester);
      await tap(tester, 'rd_status');
      expect(h.api.calls, contains('action:remote_desktop_status'));
      expect(h.api.requested, isEmpty);
      expect(find.textContaining('rustdesk is running'), findsOneWidget);
    });

    testWidgets('start needs the dialog, the biometric and the confirmation', (tester) async {
      final h = await home(tester);
      await tap(tester, 'rd_start');
      expect(find.text(S('bn').t('will_remote_start')), findsOneWidget);
      expect(h.api.requested, isEmpty);
      await tester.tap(key('tools_dialog_confirm'));
      await flush(tester);
      expect(h.biometric.reasons.length, 1);
      expect(h.api.confirmed, ['remote_desktop_start:ticket-remote_desktop_start']);
    });

    testWidgets('the app never asks for or stores a RustDesk password', (tester) async {
      final h = await home(tester, rustdesk: '123456789');
      expect(find.textContaining('পাসওয়ার্ড'), findsWidgets); // the note says it is never read
      expect(h.secrets.values.values.join(' ').toLowerCase().contains('password'), isFalse);
    });
  });

  group('pending cards for the new actions', () {
    PendingItem item(String token, String action, {List<String> command = const []}) => PendingItem(
      confirmToken: token,
      action: action,
      params: const {'name': 'api'},
      summary: 'Do $action',
      command: command,
      expiresIn: 50,
    );

    testWidgets('a coding session start shows the exact command, a stop and RustDesk have titles', (tester) async {
      final api = FakeApi()
        ..pendingItems = [
          item('t1', 'coding_session_start', command: ['wt.exe', 'claude', '(in folder)', 'C:\\proj']),
          item('t2', 'coding_session_stop'),
          item('t3', 'remote_desktop_start'),
        ];
      await home(tester, api: api);
      await tester.tap(find.byIcon(Icons.verified_user_outlined));
      await flush(tester);
      expect(find.text('কোডিং সেশন চালু'), findsOneWidget);
      expect(find.text('কোডিং সেশন বন্ধ'), findsOneWidget);
      expect(find.text('RustDesk চালু'), findsWidgets);
      expect(find.text('wt.exe claude (in folder) C:\\proj'), findsOneWidget);
    });
  });
}
