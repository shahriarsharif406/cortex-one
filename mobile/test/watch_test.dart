import 'package:cortex_one/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

WatchSnapshot snapshot() => WatchSnapshot(
  rules: const [
    WatchRule(
      name: 'claude-done',
      kind: 'process_exit',
      target: 'claude',
      state: 'exited',
    ),
    WatchRule(
      name: 'stuck',
      kind: 'log_stalled',
      target: 'coder',
      state: 'active',
      minutes: 15,
    ),
  ],
  alerts: [
    AlertEntry(
      id: 7,
      time: DateTime.now(),
      kind: 'watch_exit',
      message: 'claude-done: program exited',
    ),
  ],
);

void main() {
  testWidgets('the watch screen lists rules, states and recent alerts', (
    tester,
  ) async {
    final h = Harness();
    h.api.watchSnapshot = snapshot();
    await h.pump(tester);
    await flush(tester);
    await tester.tap(find.byKey(const Key('watch_open')));
    await flush(tester);
    expect(find.text('কোডিং এজেন্ট ওয়াচ'), findsOneWidget);
    expect(find.byKey(const Key('watch_rule_claude-done')), findsOneWidget);
    expect(find.text('বন্ধ হয়েছে'), findsOneWidget);
    expect(find.text('সক্রিয়'), findsOneWidget);
    expect(find.textContaining('লগ থেমে গেলে (15 মিনিট)'), findsOneWidget);
    expect(find.byKey(const Key('watch_alert_7')), findsOneWidget);
    expect(find.text('claude-done: program exited'), findsOneWidget);
    expect(find.byKey(const Key('emergency_stop_button')), findsWidgets);
    expect(h.api.calls, contains('watch'));
  });

  testWidgets('the watch screen has empty, problem and error states', (
    tester,
  ) async {
    final h = Harness();
    h.api.watchSnapshot = const WatchSnapshot(problems: ['rule #1: bad']);
    await h.pump(tester);
    await flush(tester);
    await tester.tap(find.byKey(const Key('watch_open')));
    await flush(tester);
    expect(find.byKey(const Key('watch_empty')), findsOneWidget);
    expect(find.byKey(const Key('watch_problems')), findsOneWidget);
    expect(find.byKey(const Key('watch_no_alerts')), findsOneWidget);

    final h2 = Harness();
    h2.api.watchError = Exception('boom');
    await h2.pump(tester);
    await flush(tester);
    await tester.tap(find.byKey(const Key('watch_open')));
    await flush(tester);
    expect(find.byKey(const Key('watch_error')), findsOneWidget);
  });

  test('WatchSnapshot.fromJson is tolerant of missing fields', () {
    final s = WatchSnapshot.fromJson({
      'rules': [
        {
          'name': 'a',
          'kind': 'log_pattern',
          'target': 'x',
          'last_alert': 1700000000.5,
        },
        'junk',
      ],
    });
    expect(s.rules.single.state, 'waiting');
    expect(s.rules.single.lastAlert, isNotNull);
    expect(s.alerts, isEmpty);
    expect(WatchSnapshot.fromJson({}).rules, isEmpty);
  });
}
