import 'dart:async';
import 'dart:typed_data';
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
  List<AlertEntry> alertRows = [];
  Object? alertsError;
  WatchSnapshot watchSnapshot = const WatchSnapshot();
  Object? watchError;
  Object? screenshotError;
  Object? screenshotActionError;
  Uint8List screenshotPng = _tinyPng;
  int shotCounter = 0;

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
    if (name == 'system_info') {
      return ActionOutcome(ok: true, message: 'ok', data: info);
    }
    if (name == 'take_screenshot') {
      if (screenshotActionError != null) throw screenshotActionError!;
      shotCounter++;
      return ActionOutcome(
        ok: true,
        message: 'Screenshot saved.',
        data: {'file': 'screenshot-20260101-10000$shotCounter.png'},
      );
    }
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

  @override
  Future<List<AlertEntry>> alerts({int limit = 20}) async {
    calls.add('alerts');
    if (alertsError != null) throw alertsError!;
    return List.of(alertRows);
  }

  @override
  Future<WatchSnapshot> watch() async {
    calls.add('watch');
    if (watchError != null) throw watchError!;
    return watchSnapshot;
  }

  @override
  Future<List<ScreenshotInfo>> screenshots() async => const [];

  @override
  Future<Uint8List> screenshotBytes(String name, {int? width}) async {
    calls.add('shot:$name:${width ?? 0}');
    if (screenshotError != null) throw screenshotError!;
    return screenshotPng;
  }
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

/// A valid 1x1 PNG, so Image.memory can really decode it in widget tests.
final Uint8List _tinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x50, 0x58, 0x30, 0x01, 0x00, 0x02, 0x34, 0x01, 0x51, 0x9A, 0x95, 0xC7, 0xF3, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);
