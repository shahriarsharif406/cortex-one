import 'package:cortex_one/api/models.dart';
import 'package:cortex_one/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Finder key(String k) => find.byKey(Key(k));

Future<void> sendAndWait(WidgetTester tester, Harness h) async {
  await h.pump(tester);
  await flush(tester);
  await tester.enterText(key('command_field'), 'how is it?');
  await tester.ensureVisible(key('send_button'));
  await tester.pump();
  await tester.tap(key('send_button'));
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('model and fallback are read from the agent answer', () {
    final t = TaskStatus.fromJson({'id': 'j', 'status': 'ok', 'reply': 'x', 'model': 'tiny:1b', 'fallback': true});
    expect(t.model, 'tiny:1b');
    expect(t.fallback, isTrue);
    final plain = TaskStatus.fromJson({'id': 'j', 'status': 'ok'});
    expect(plain.model, '');
    expect(plain.fallback, isFalse);
  });

  testWidgets('a cloud answer names the model', (tester) async {
    final h = Harness();
    h.api.taskPolls = [
      const TaskStatus(id: 'j', status: 'ok', reply: 'Fine.', steps: [], pending: [], stoppedReason: '', model: 'claude-sonnet-5-5'),
    ];
    await sendAndWait(tester, h);
    expect(find.text('উত্তর দিয়েছে: claude-sonnet-5-5'), findsOneWidget);
  });

  testWidgets('an offline fallback answer says so, in plain words', (tester) async {
    final h = Harness();
    h.api.taskPolls = [
      const TaskStatus(id: 'j', status: 'ok', reply: '[Local model tiny:1b] Fine.', steps: [], pending: [], stoppedReason: '', model: 'tiny:1b', fallback: true),
    ];
    await sendAndWait(tester, h);
    expect(find.text(S('bn').tf('answered_local', {'m': 'tiny:1b'})), findsOneWidget);
    expect(find.textContaining('শুধু পড়ার কাজ'), findsOneWidget);
  });

  testWidgets('no model name means no line (older agent)', (tester) async {
    final h = Harness();
    h.api.taskPolls = [
      const TaskStatus(id: 'j', status: 'ok', reply: 'Fine.', steps: [], pending: [], stoppedReason: ''),
    ];
    await sendAndWait(tester, h);
    expect(key('task_model'), findsNothing);
  });
}
