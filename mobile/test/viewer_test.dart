import 'package:cortex_one/api/api_client.dart';
import 'package:cortex_one/state/computer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Finder key(String k) => find.byKey(Key(k));

Computer comp(String role) => Computer(
  id: 'a1',
  name: 'Laptop',
  endpoints: const ['http://100.64.0.9:8765'],
  token: 'tok',
  role: role,
);

void main() {
  group('role storage', () {
    test('default owner; viewer survives a round trip; unknown means viewer', () {
      expect(comp('owner').isViewer, isFalse);
      final back = decodeComputers(encodeComputers([comp('viewer')])).single;
      expect(back.isViewer, isTrue);
      expect(
        decodeComputers('[{"id":"x","name":"n","token":"t","endpoints":["http://100.64.0.1:1"]}]').single.role,
        'owner', // an old record without a role
      );
      expect(
        decodeComputers('[{"id":"x","name":"n","token":"t","role":"admin","endpoints":["http://100.64.0.1:1"]}]').single.role,
        'viewer',
      );
    });
  });

  group('pairing learns the role', () {
    Future<Harness> pairAs(WidgetTester tester, FakeApi api) async {
      final h = Harness(api: api, paired: false);
      await h.pump(tester);
      await tester.enterText(key('server_field'), '100.64.1.2');
      await tester.enterText(key('code_field'), '123456');
      await tester.tap(key('pair_button'));
      await flush(tester);
      return h;
    }

    testWidgets('a viewer code gives a viewer computer', (tester) async {
      final h = await pairAs(tester, FakeApi()..roleAnswer = 'viewer');
      expect(decodeComputers(h.secrets.values['computers']).single.role, 'viewer');
    });

    testWidgets('an owner code gives an owner computer', (tester) async {
      final h = await pairAs(tester, FakeApi());
      expect(decodeComputers(h.secrets.values['computers']).single.role, 'owner');
    });

    testWidgets('if the role cannot be read the phone assumes owner (the agent still enforces it)', (tester) async {
      final h = await pairAs(tester, FakeApi()..roleError = const ApiException(ApiErrorKind.network));
      expect(decodeComputers(h.secrets.values['computers']).single.role, 'owner');
    });
  });

  group('viewer screens', () {
    testWidgets('a viewer sees status, a note and two tabs only', (tester) async {
      final h = Harness(computers: [comp('viewer')]);
      await h.pump(tester);
      await flush(tester);
      expect(key('computer_status_card'), findsOneWidget);
      expect(key('viewer_note'), findsOneWidget);
      expect(key('power_card'), findsNothing);
      expect(key('command_field'), findsNothing);
      expect(key('send_button'), findsNothing);
      expect(key('tools_expansion'), findsNothing);
      expect(key('quick_lock'), findsNothing);
      expect(find.byType(NavigationDestination), findsNWidgets(2));
      expect(find.byIcon(Icons.verified_user_outlined), findsNothing);
      expect(find.byIcon(Icons.sms_outlined), findsNothing);
      expect(find.byIcon(Icons.history), findsNothing);
      // the emergency stop is part of the owner's controls: the viewer has none, and the agent would refuse
      expect(h.api.calls.where((c) => c == 'pending'), isEmpty);
    });

    testWidgets('a viewer can still take and look at a screenshot', (tester) async {
      final h = Harness(computers: [comp('viewer')]);
      await h.pump(tester);
      await flush(tester);
      await tester.tap(find.byIcon(Icons.monitor_outlined));
      await flush(tester);
      await tester.tap(key('screen_refresh'));
      await flush(tester);
      expect(h.api.calls, contains('action:take_screenshot'));
      expect(key('screen_image'), findsOneWidget);
    });

    testWidgets('an owner sees everything', (tester) async {
      final h = Harness(computers: [comp('owner')]);
      await h.pump(tester);
      await flush(tester);
      expect(key('power_card'), findsOneWidget);
      expect(key('command_field'), findsOneWidget);
      expect(key('viewer_note'), findsNothing);
      expect(find.byType(NavigationDestination), findsNWidgets(5));
      expect(h.api.calls.where((c) => c == 'pending'), isNotEmpty);
    });

    testWidgets('the gateway entry is not offered to a viewer', (tester) async {
      final h = Harness(computers: [comp('viewer')]);
      await h.pump(tester);
      await flush(tester);
      await tester.tap(key('settings_menu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Cortex Wake'), findsNothing);
    });
  });
}
