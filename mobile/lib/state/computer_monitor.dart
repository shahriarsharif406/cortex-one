import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/health.dart';
import '../storage/stores.dart';
import 'computer.dart';
import 'power_state.dart';

/// Watches one computer: asks GET /health now and then, keeps the last time it answered and
/// what it said, and turns that into the online / sleeping / offline badge.
///
/// What is remembered goes into plain preferences under `seen_<id>` and contains only the
/// time, battery numbers and the last power request: no address, no token.
class ComputerMonitor extends ChangeNotifier {
  ComputerMonitor({
    required this.computer,
    required this.api,
    required this.prefs,
    this.everySeconds = 20,
    this.autoRefresh = true,
    this.onError,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Computer computer;
  final CortexApi api;
  final PrefsStore prefs;
  final int everySeconds;
  final Future<void> Function(Object error)? onError;
  final DateTime Function() _now;

  /// False in data-saver mode: no background polling, only manual refresh.
  bool autoRefresh;

  PowerStatus status = const PowerStatus(
    PowerState.unknown,
    PowerReason.neverSeen,
  );
  Health? lastHealth;
  DateTime? lastSeen;
  PowerHint? phoneHint;
  bool checking = false;
  Timer? _timer;
  bool _disposed = false;

  String get _key => 'seen_${computer.id}';

  Future<void> start() async {
    await _restore();
    await refresh();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!autoRefresh || _disposed || everySeconds <= 0) return;
    _timer = Timer.periodic(Duration(seconds: everySeconds), (_) => refresh());
  }

  void setAutoRefresh(bool on) {
    autoRefresh = on;
    _schedule();
  }

  /// Call after this phone sent a power request that was accepted (sleep, shutdown ...).
  void notePhoneRequested(String action) {
    phoneHint = PowerHint(action, _now());
    _persist();
  }

  Future<void> refresh() async {
    if (checking || _disposed) return;
    checking = true;
    notifyListeners();
    var reachable = false;
    try {
      lastHealth = await api.health();
      lastSeen = _now();
      phoneHint = null; // it is answering again: an old "going to sleep" is history
      reachable = true;
      await _persist();
    } on ApiException catch (e) {
      if (e.kind != ApiErrorKind.network && e.kind != ApiErrorKind.timeout) {
        await onError?.call(e);
      }
    } catch (_) {
      // an unexpected failure is treated like "no answer"; never crash the home screen
    } finally {
      checking = false;
      status = classifyPower(
        reachable: reachable,
        now: _now(),
        lastSeen: lastSeen,
        lastHealth: lastHealth,
        phoneHint: phoneHint,
      );
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _persist() async {
    final h = lastHealth;
    try {
      await prefs.set(
        _key,
        jsonEncode({
          if (lastSeen != null) 'seen': lastSeen!.millisecondsSinceEpoch,
          if (h != null) ...{
            'battery': h.batteryPercent,
            'plugged': h.plugged,
            'power': h.lastPower == null
                ? null
                : {
                    'action': h.lastPower!.action,
                    'age': h.lastPower!.ageSeconds,
                  },
          },
          if (phoneHint != null)
            'hint': {
              'action': phoneHint!.action,
              'at': phoneHint!.at.millisecondsSinceEpoch,
            },
        }),
      );
    } catch (_) {}
  }

  Future<void> _restore() async {
    try {
      final raw = await prefs.get(_key);
      if (raw == null) return;
      final j = jsonDecode(raw);
      if (j is! Map) return;
      if (j['seen'] is int) {
        lastSeen = DateTime.fromMillisecondsSinceEpoch(j['seen'] as int);
      }
      final p = j['power'];
      lastHealth = Health(
        computerId: computer.id,
        computerName: computer.name,
        version: '',
        batteryPercent: (j['battery'] as num?)?.toInt(),
        plugged: j['plugged'] is bool ? j['plugged'] as bool : null,
        lastPower: p is Map
            ? LastPowerRequest(
                action: '${p['action']}',
                ageSeconds: (p['age'] as num?)?.toInt() ?? 0,
              )
            : null,
      );
      final h = j['hint'];
      if (h is Map && h['at'] is int) {
        phoneHint = PowerHint(
          '${h['action']}',
          DateTime.fromMillisecondsSinceEpoch(h['at'] as int),
        );
      }
    } catch (_) {
      // corrupt preference: start fresh
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
