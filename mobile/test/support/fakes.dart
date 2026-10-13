import 'dart:async';
import 'dart:ui' show Size;

import 'package:cortex_one/api/api_client.dart';
import 'package:cortex_one/api/models.dart';
import 'package:cortex_one/app.dart';
import 'package:cortex_one/state/app_state.dart';
import 'package:cortex_one/storage/stores.dart';
import 'package:cortex_one/voice/voice_input.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeApi implements CortexApi {
  final List<String> calls = [];
  final List<Map<String, String>> actionParams = [];

  String pairToken = 'tok-secret-123';
  Object? pairError;
  Object? emergencyError;
  Completer<void>? emergencyGate;
  Object? confirmError;
  List<PendingItem> pendingItems = [];
  Map<String, dynamic> info = {
    'cpu_percent': 12.5,
    'ram_used_percent': 61.0,
    'disk_free_gb': 80.2,
    'battery_percent': 77,
    'plugged_in': true,
    'uptime_minutes': 135,
  };
  Capabilities caps = const Capabilities(
    allowedRoots: [r'C:\Users\me\Downloads', r'C:\Users\me\Documents'],
    allowedApps: ['notepad', 'calculator'],
  );
  List<TaskStatus> taskPolls = [];
  Object? taskError;
  List<AuditEntry> auditRows = [];

  @override
  Future<String> pair(String code, String deviceName) async {
    calls.add('pair:$code');
    if (pairError != null) throw pairError!;
    return pairToken;
  }

  @override
  Future<ActionOutcome> runAction(
    String name, [
    Map<String, String> params = const {},
  ]) async {
    calls.add('action:$name');
    actionParams.add(params);
    if (name == 'system_info')
      return ActionOutcome(ok: true, message: 'ok', data: info);
    if (name == 'list_files') {
      return const ActionOutcome(
        ok: true,
        message: '2 item(s).',
        data: {
          'entries': [
            {'name': 'report.pdf', 'dir': false, 'size': 2048},
            {'name': 'Old', 'dir': true, 'size': null},
          ],
        },
      );
    }
    return ActionOutcome(ok: true, message: '$name done');
  }

  @override
  Future<ActionOutcome> emergencyStop() async {
    calls.add('emergency');
    await emergencyGate?.future;
    if (emergencyError != null) throw emergencyError!;
    return const ActionOutcome(ok: true, message: 'Stopped 0 running task(s).');
  }

  @override
  Future<String> startTask(String instruction) async {
    calls.add('start:$instruction');
    return 'job1';
  }

  @override
  Future<TaskStatus> getTask(String id) async {
    calls.add('poll:$id');
    if (taskError != null) throw taskError!;
    return taskPolls.length > 1 ? taskPolls.removeAt(0) : taskPolls.first;
  }

  @override
  Future<List<PendingItem>> pending() async {
    calls.add('pending');
    return List.of(pendingItems);
  }

  @override
  Future<ActionOutcome> confirm(String confirmToken) async {
    calls.add('confirm:$confirmToken');
    final err = confirmError;
    if (err != null) {
      // the real agent has already burned a rejected token
      if (err is ApiException && err.kind == ApiErrorKind.forbidden) {
        pendingItems.removeWhere((i) => i.confirmToken == confirmToken);
      }
      throw err;
    }
    pendingItems.removeWhere((i) => i.confirmToken == confirmToken);
    return const ActionOutcome(ok: true, message: 'Shutting down in 30s.');
  }

  @override
  Future<void> cancel(String confirmToken) async {
    calls.add('cancel:$confirmToken');
    pendingItems.removeWhere((i) => i.confirmToken == confirmToken);
  }

  @override
  Future<List<AuditEntry>> audit({int limit = 50}) async {
    calls.add('audit');
    return auditRows;
  }

  @override
  Future<Capabilities> capabilities() async => caps;
}

class FakeVoice implements VoiceInput {
  bool available = true;
  bool listening = false;
  String? localeUsed;
  void Function(String words, bool finished)? sink;

  @override
  Future<bool> init() async => available;

  @override
  Future<void> listen(
    String localeId,
    void Function(String, bool) onWords,
  ) async {
    listening = true;
    localeUsed = localeId;
    sink = onWords;
  }

  @override
  Future<void> stop() async => listening = false;

  @override
  bool get isListening => listening;
}

class Harness {
  Harness({FakeApi? api, FakeVoice? voice, bool paired = true})
    : api = api ?? FakeApi(),
      voice = voice ?? FakeVoice(),
      secrets = MemorySecretStore(),
      prefs = MemoryPrefsStore(),
      launched = [] {
    if (paired) {
      secrets.values['device_token'] = 'stored-token';
      secrets.values['server_address'] = 'http://100.64.0.9:8765';
    }
    state = AppState(
      secrets: secrets,
      prefs: prefs,
      apiFactory: (baseUrl, token) {
        factoryCalls.add((baseUrl, token));
        return this.api;
      },
      voice: this.voice,
      launchUri: (uri) async {
        launched.add(uri);
        return launchResult;
      },
    );
  }

  final FakeApi api;
  final FakeVoice voice;
  final MemorySecretStore secrets;
  final MemoryPrefsStore prefs;
  final List<Uri> launched;
  final List<(String, String?)> factoryCalls = [];
  bool launchResult = true;
  late final AppState state;

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await state.load();
    await tester.pumpWidget(CortexApp(state: state));
    await tester.pump();
  }
}

/// Lets a chain of awaited fake-API calls finish (a few short event-loop turns).
Future<void> flush(WidgetTester tester, [int turns = 6]) async {
  for (var i = 0; i < turns; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
