import 'package:cortex_one/api/api_client.dart';
import 'package:cortex_one/api/models.dart';
import 'package:cortex_one/screens/sms_help_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

TaskStatus status(
  String s, {
  String reply = '',
  List<TaskStep> steps = const [],
  List<PendingItem> pending = const [],
}) => TaskStatus(
  id: 'job1',
  status: s,
  reply: reply,
  steps: steps,
  pending: pending,
  stoppedReason: '',
);

Future<void> settle(WidgetTester tester, [int times = 3]) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(seconds: 2));
  }
}

void main() {
  group('status card', () {
    testWidgets('shows laptop status from system_info', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await tester.pump();
      expect(find.text('ল্যাপটপের অবস্থা'), findsOneWidget);
      expect(find.text('12.5%'), findsOneWidget);
      expect(find.text('61.0%'), findsOneWidget);
      expect(find.text('77% (চার্জে আছে)'), findsOneWidget);
      expect(find.text('2 ঘণ্টা 15 মিনিট'), findsOneWidget);
      expect(h.api.calls, contains('action:system_info'));
    });

    testWidgets('an unreachable laptop shows a clear Bangla error', (
      tester,
    ) async {
      final h = Harness();
      h.api.info = {};
      final bad = _ThrowingApi();
      final h2 = Harness(api: bad);
      await h2.pump(tester);
      await tester.pump();
      expect(find.byKey(const Key('status_error')), findsOneWidget);
      expect(
        find.textContaining('ল্যাপটপের সাথে যোগাযোগ হয়নি'),
        findsOneWidget,
      );
    });
  });

  group('command box', () {
    testWidgets(
      'sends the text, shows steps while running and the reply at the end',
      (tester) async {
        final h = Harness();
        h.api.taskPolls = [
          status(
            'running',
            steps: const [
              TaskStep(
                tool: 'list_files',
                input: {},
                ok: true,
                message: '2 item(s).',
              ),
            ],
          ),
          status(
            'ok',
            reply: '২টি আইটেম আছে।',
            steps: const [
              TaskStep(
                tool: 'list_files',
                input: {},
                ok: true,
                message: '2 item(s).',
              ),
            ],
          ),
        ];
        await h.pump(tester);
        await tester.enterText(
          find.byKey(const Key('command_field')),
          'Downloads দেখাও',
        );
        await tester.ensureVisible(find.byKey(const Key('send_button')));
        await tester.tap(find.byKey(const Key('send_button')));
        await tester.pump();
        expect(h.api.calls, contains('start:Downloads দেখাও'));
        await tester.pump(const Duration(milliseconds: 1600));
        expect(find.textContaining('list_files: 2 item(s).'), findsOneWidget);
        expect(
          find.byKey(const Key('task_reply')),
          findsNothing,
        ); // still running
        await tester.pump(const Duration(milliseconds: 1600));
        expect(find.byKey(const Key('task_reply')), findsOneWidget);
        expect(find.text('২টি আইটেম আছে।'), findsOneWidget);
      },
    );

    testWidgets('does not send an empty command', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await tester.ensureVisible(find.byKey(const Key('send_button')));
      await tester.tap(find.byKey(const Key('send_button')));
      await tester.pump();
      expect(h.api.calls.where((c) => c.startsWith('start')), isEmpty);
    });

    testWidgets(
      'a request for confirmation is shown as waiting, never as done',
      (tester) async {
        final h = Harness();
        h.api.taskPolls = [
          status(
            'ok',
            reply: 'অপেক্ষায়।',
            pending: const [
              PendingItem(
                confirmToken: 'tk',
                action: 'shutdown',
                params: {},
                summary: '',
                command: [],
                expiresIn: 60,
              ),
            ],
          ),
        ];
        h.api.pendingItems = const [
          PendingItem(
            confirmToken: 'tk',
            action: 'shutdown',
            params: {},
            summary: 'Shut down in 30 s',
            command: [],
            expiresIn: 60,
          ),
        ];
        await h.pump(tester);
        await tester.enterText(
          find.byKey(const Key('command_field')),
          'ল্যাপটপ বন্ধ করো',
        );
        await tester.ensureVisible(find.byKey(const Key('send_button')));
        await tester.tap(find.byKey(const Key('send_button')));
        await settle(tester);
        expect(find.byKey(const Key('task_pending_banner')), findsOneWidget);
        expect(h.api.calls.any((c) => c.startsWith('confirm')), isFalse);
        // the shortcut leads to the confirmation list
        await tester.ensureVisible(find.byKey(const Key('task_open_pending')));
        await tester.tap(find.byKey(const Key('task_open_pending')));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const Key('pending_card_tk')), findsOneWidget);
      },
    );

    testWidgets('AI not set up (503) is explained', (tester) async {
      final h = Harness(
        api: _ThrowingApi(
          startError: const ApiException(
            ApiErrorKind.unavailable,
            detail: 'ANTHROPIC_API_KEY is empty',
          ),
        ),
      );
      await h.pump(tester);
      await tester.enterText(find.byKey(const Key('command_field')), 'hi');
      await tester.ensureVisible(find.byKey(const Key('send_button')));
      await tester.tap(find.byKey(const Key('send_button')));
      await settle(tester, 1);
      expect(find.byKey(const Key('task_error')), findsOneWidget);
      expect(find.textContaining('ANTHROPIC_API_KEY'), findsOneWidget);
    });
  });

  group('voice', () {
    testWidgets(
      'recognised text fills the box for editing and is NOT sent automatically',
      (tester) async {
        final h = Harness();
        await h.pump(tester);
        await tester.ensureVisible(find.byKey(const Key('mic_button')));
        await tester.tap(find.byKey(const Key('mic_button')));
        await tester.pump();
        await tester.pump();
        expect(h.voice.localeUsed, 'bn_BD');
        expect(find.byKey(const Key('listening_label')), findsOneWidget);
        h.voice.sink!('ডাউনলোড ফোল্ডার দেখাও', false);
        await tester.pump();
        h.voice.sink!('ডাউনলোড ফোল্ডার দেখাও', true);
        await tester.pump();
        final field = tester.widget<TextField>(
          find.byKey(const Key('command_field')),
        );
        expect(field.controller!.text, 'ডাউনলোড ফোল্ডার দেখাও');
        expect(find.byKey(const Key('listening_label')), findsNothing);
        expect(h.api.calls.where((c) => c.startsWith('start')), isEmpty);
        // the owner can still edit before sending
        await tester.enterText(
          find.byKey(const Key('command_field')),
          'ডাউনলোড ফোল্ডারের PDF দেখাও',
        );
        expect(find.text('ডাউনলোড ফোল্ডারের PDF দেখাও'), findsOneWidget);
      },
    );

    testWidgets('English voice locale can be chosen', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await tester.ensureVisible(find.text('English'));
      await tester.tap(find.text('English'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('mic_button')));
      await flush(tester);
      expect(h.voice.localeUsed, 'en_US');
    });

    testWidgets('unavailable speech service shows a Bangla message', (
      tester,
    ) async {
      final voice = FakeVoice()..available = false;
      final h = Harness(voice: voice);
      await h.pump(tester);
      await tester.ensureVisible(find.byKey(const Key('mic_button')));
      await tester.tap(find.byKey(const Key('mic_button')));
      await flush(tester);
      expect(find.byKey(const Key('voice_error')), findsOneWidget);
    });
  });

  group('quick actions', () {
    testWidgets('lock calls the lock action', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await tester.ensureVisible(find.byKey(const Key('quick_lock')));
      await tester.tap(find.byKey(const Key('quick_lock')));
      await flush(tester);
      expect(h.api.calls, contains('action:lock'));
    });

    testWidgets('Downloads lists the allowed Downloads folder only', (
      tester,
    ) async {
      final h = Harness();
      await h.pump(tester);
      await tester.ensureVisible(find.byKey(const Key('quick_downloads')));
      await tester.tap(find.byKey(const Key('quick_downloads')));
      await flush(tester);
      expect(h.api.actionParams.last, {'path': r'C:\Users\me\Downloads'});
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('Old'), findsOneWidget);
    });

    testWidgets('Downloads missing from the allowlist is explained', (
      tester,
    ) async {
      final h = Harness();
      h.api.caps = const Capabilities(allowedRoots: [r'C:\Users\me\Documents']);
      await h.pump(tester);
      await tester.ensureVisible(find.byKey(const Key('quick_downloads')));
      await tester.tap(find.byKey(const Key('quick_downloads')));
      await flush(tester);
      expect(
        find.text('Downloads ফোল্ডার অনুমোদিত তালিকায় নেই।'),
        findsOneWidget,
      );
      expect(h.api.calls.contains('action:list_files'), isFalse);
    });

    testWidgets('open app offers only approved apps', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await tester.ensureVisible(find.byKey(const Key('quick_apps')));
      await tester.tap(find.byKey(const Key('quick_apps')));
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('app_notepad')), findsOneWidget);
      expect(find.byKey(const Key('app_calculator')), findsOneWidget);
      await tester.tap(find.byKey(const Key('app_notepad')));
      await flush(tester);
      expect(h.api.calls, contains('action:open_app'));
      expect(h.api.actionParams.last, {'name': 'notepad'});
    });
  });

  group('audit log', () {
    testWidgets('lists entries read-only', (tester) async {
      final h = Harness();
      h.api.auditRows = [
        AuditEntry(
          time: DateTime(2026, 10, 13, 9, 5),
          actor: 'ai:phone',
          via: 'ai',
          action: 'shutdown',
          status: 'pending',
          detail: 'AI requested; awaiting owner confirmation',
        ),
        AuditEntry(
          time: DateTime(2026, 10, 13, 9, 4),
          actor: 'device:phone',
          via: 'http',
          action: 'lock',
          status: 'ok',
          detail: 'Locked.',
        ),
      ];
      await h.pump(tester);
      await tester.tap(find.byType(NavigationDestination).at(2));
      await flush(tester);
      expect(find.text('shutdown  ·  pending'), findsOneWidget);
      expect(find.text('lock  ·  ok'), findsOneWidget);
      expect(find.byType(TextField), findsNothing); // nothing editable
    });

    testWidgets('empty log', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await tester.tap(find.byType(NavigationDestination).at(2));
      await flush(tester);
      expect(find.byKey(const Key('audit_empty')), findsOneWidget);
    });
  });

  group('SMS help', () {
    testWidgets('lists the commands and never asks for a PIN', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pump();
      for (final c in smsCommands) {
        expect(find.text('$c  <PIN>'), findsOneWidget);
      }
      expect(find.byKey(const Key('sms_pin_note')), findsOneWidget);
      // only the number field is editable; there is no PIN field
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byKey(const Key('sms_number_field')), findsOneWidget);
    });

    testWidgets(
      'opens the SMS app with the number and command prefilled, without a PIN',
      (tester) async {
        final h = Harness();
        await h.pump(tester);
        await tester.tap(find.byType(NavigationDestination).at(3));
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('sms_number_field')),
          '+880 1700-000000',
        );
        await tester.ensureVisible(find.byKey(const Key('sms_open_button')));
        await tester.tap(find.byKey(const Key('sms_open_button')));
        await tester.pump();
        await tester.pump();
        expect(
          h.launched.single.toString(),
          'sms:+8801700000000?body=STATUS%20',
        );
        // only the (non-secret) gateway number is remembered
        expect(h.prefs.values['sms_number'], '+8801700000000');
        expect(
          h.prefs.values.keys.any((k) => k.toLowerCase().contains('pin')),
          isFalse,
        );
        expect(
          h.secrets.values.keys.any((k) => k.toLowerCase().contains('pin')),
          isFalse,
        );
      },
    );

    testWidgets('rejects a bad number', (tester) async {
      final h = Harness();
      await h.pump(tester);
      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('sms_number_field')), 'abc');
      await tester.ensureVisible(find.byKey(const Key('sms_open_button')));
      await tester.tap(find.byKey(const Key('sms_open_button')));
      await tester.pump();
      expect(find.text('নম্বর সঠিক নয়।'), findsOneWidget);
      expect(h.launched, isEmpty);
    });

    test('smsUri never contains a PIN placeholder value', () {
      expect(
        smsUri('+8801700000000', 'SHUTDOWN').toString(),
        'sms:+8801700000000?body=SHUTDOWN%20',
      );
      expect(isValidPhoneNumber('+8801700000000'), isTrue);
      expect(isValidPhoneNumber('12'), isFalse);
      expect(isValidPhoneNumber('+88 017-0000 0000'), isTrue);
    });
  });

  group('settings', () {
    testWidgets('dark theme and language persist in plain prefs (no secrets)', (
      tester,
    ) async {
      final h = Harness();
      await h.pump(tester);
      await h.state.setThemeMode(ThemeMode.dark);
      await h.state.setLang('en');
      await tester.pump();
      expect(h.prefs.values, {'theme': 'dark', 'lang': 'en'});
      expect(find.text('EMERGENCY STOP'), findsOneWidget);
    });

    testWidgets('unpair removes the token and returns to pairing', (
      tester,
    ) async {
      final h = Harness();
      await h.pump(tester);
      await h.state.unpair();
      await tester.pump();
      expect(h.secrets.values, isEmpty);
      expect(find.byKey(const Key('pair_button')), findsOneWidget);
    });
  });
}

class _ThrowingApi extends FakeApi {
  _ThrowingApi({this.startError});

  final Object? startError;

  @override
  Future<ActionOutcome> runAction(
    String name, [
    Map<String, String> params = const {},
  ]) async {
    throw const ApiException(ApiErrorKind.network);
  }

  @override
  Future<String> startTask(String instruction) async {
    throw startError ?? const ApiException(ApiErrorKind.network);
  }
}
