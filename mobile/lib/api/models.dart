/// Plain data classes for the Cortex One agent API. No secrets live here.
library;

import 'dart:typed_data';

Map<String, String> _stringMap(dynamic v) {
  if (v is! Map) return const {};
  return {for (final e in v.entries) e.key.toString(): e.value.toString()};
}

/// A picture sent with an AI task: always an already shrunk, metadata-free JPEG.
class TaskImage {
  const TaskImage({
    required this.mediaType,
    required this.bytes,
    this.width = 0,
    this.height = 0,
  });

  final String mediaType;
  final Uint8List bytes;
  final int width;
  final int height;
}

class ActionOutcome {
  const ActionOutcome({
    required this.ok,
    required this.message,
    this.data = const {},
  });

  final bool ok;
  final String message;
  final Map<String, dynamic> data;

  factory ActionOutcome.fromJson(Map<String, dynamic> j) => ActionOutcome(
    ok: j['status'] == 'ok',
    message: (j['message'] ?? '').toString(),
    data: j['data'] is Map
        ? Map<String, dynamic>.from(j['data'] as Map)
        : const {},
  );
}

/// A high-risk request (shutdown, restart, run_script) waiting for the owner.
class PendingItem {
  const PendingItem({
    required this.confirmToken,
    required this.action,
    required this.params,
    required this.summary,
    required this.command,
    required this.expiresIn,
  });

  final String confirmToken;
  final String action;
  final Map<String, String> params;

  /// Plain-language description from the agent (English).
  final String summary;

  /// For run_script: the exact command line the agent will run. Otherwise empty.
  final List<String> command;

  /// Seconds left when the list was fetched.
  final int expiresIn;

  factory PendingItem.fromJson(Map<String, dynamic> j) => PendingItem(
    confirmToken: (j['confirm_token'] ?? '').toString(),
    action: (j['action'] ?? '').toString(),
    params: _stringMap(j['params']),
    summary: (j['summary'] ?? '').toString(),
    command: j['command'] is List
        ? [for (final c in j['command'] as List) c.toString()]
        : const [],
    expiresIn: (j['expires_in'] as num?)?.toInt() ?? 0,
  );
}

class TaskStep {
  const TaskStep({
    required this.tool,
    required this.input,
    required this.ok,
    required this.message,
  });

  final String tool;
  final Map<String, String> input;
  final bool ok;
  final String message;

  factory TaskStep.fromJson(Map<String, dynamic> j) => TaskStep(
    tool: (j['tool'] ?? '').toString(),
    input: _stringMap(j['input']),
    ok: j['ok'] == true,
    message: (j['message'] ?? '').toString(),
  );
}

/// Status of an AI task: running | ok | stopped | error.
class TaskStatus {
  const TaskStatus({
    required this.id,
    required this.status,
    required this.reply,
    required this.steps,
    required this.pending,
    required this.stoppedReason,
  });

  final String id;
  final String status;
  final String reply;
  final List<TaskStep> steps;
  final List<PendingItem> pending;
  final String stoppedReason;

  bool get running => status == 'running';

  factory TaskStatus.fromJson(Map<String, dynamic> j) => TaskStatus(
    id: (j['id'] ?? '').toString(),
    status: (j['status'] ?? 'error').toString(),
    reply: (j['reply'] ?? '').toString(),
    steps: [
      for (final s in (j['steps'] as List? ?? const []))
        if (s is Map) TaskStep.fromJson(Map<String, dynamic>.from(s)),
    ],
    pending: [
      for (final p in (j['pending_confirmations'] as List? ?? const []))
        if (p is Map) PendingItem.fromJson(Map<String, dynamic>.from(p)),
    ],
    stoppedReason: (j['stopped_reason'] ?? '').toString(),
  );
}

class AuditEntry {
  const AuditEntry({
    required this.time,
    required this.actor,
    required this.via,
    required this.action,
    required this.status,
    required this.detail,
  });

  final DateTime time;
  final String actor;
  final String via;
  final String action;
  final String status;
  final String detail;

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
    time: DateTime.fromMillisecondsSinceEpoch(
      (((j['ts'] as num?) ?? 0) * 1000).round(),
    ),
    actor: (j['actor'] ?? '').toString(),
    via: (j['via'] ?? '').toString(),
    action: (j['action'] ?? '').toString(),
    status: (j['status'] ?? '').toString(),
    detail: (j['detail'] ?? '').toString(),
  );
}

class Capabilities {
  const Capabilities({
    this.allowedRoots = const [],
    this.allowedApps = const [],
  });

  final List<String> allowedRoots;
  final List<String> allowedApps;

  factory Capabilities.fromJson(Map<String, dynamic> j) => Capabilities(
    allowedRoots: [
      for (final r in (j['allowed_roots'] as List? ?? const [])) r.toString(),
    ],
    allowedApps: [
      for (final r in (j['allowed_apps'] as List? ?? const [])) r.toString(),
    ],
  );
}

/// One power / battery alert from the laptop's watcher (GET /alerts).
class AlertEntry {
  const AlertEntry({
    required this.id,
    required this.time,
    required this.kind,
    required this.message,
    this.batteryPercent,
    this.plugged,
  });

  final int id;
  final DateTime time;

  /// ac_lost | ac_restored | battery_warn | battery_critical | critical_action
  final String kind;
  final String message;
  final int? batteryPercent;
  final bool? plugged;

  /// Power is out or the battery is low right now (as of this alert).
  bool get isProblem =>
      kind == 'ac_lost' ||
      kind == 'battery_warn' ||
      kind == 'battery_critical' ||
      kind == 'critical_action';

  factory AlertEntry.fromJson(Map<String, dynamic> j) => AlertEntry(
    id: (j['id'] as num?)?.toInt() ?? 0,
    time: DateTime.fromMillisecondsSinceEpoch(
      (((j['ts'] as num?) ?? 0) * 1000).round(),
    ),
    kind: (j['kind'] ?? '').toString(),
    message: (j['message'] ?? '').toString(),
    batteryPercent: (j['battery_percent'] as num?)?.toInt(),
    plugged: j['plugged'] is bool ? j['plugged'] as bool : null,
  );
}

/// One coding-agent watch rule and its current state (GET /watch).
class WatchRule {
  const WatchRule({
    required this.name,
    required this.kind,
    required this.target,
    required this.state,
    this.minutes = 0,
    this.lastAlert,
  });

  final String name;

  /// process_exit | log_stalled | log_pattern
  final String kind;
  final String target;

  /// running | waiting | exited | active | stalled | clear | matched | missing | error
  final String state;
  final int minutes;
  final DateTime? lastAlert;

  /// The rule is firing or its target is gone.
  bool get isProblem =>
      state == 'exited' ||
      state == 'stalled' ||
      state == 'matched' ||
      state == 'error';

  factory WatchRule.fromJson(Map<String, dynamic> j) => WatchRule(
    name: (j['name'] ?? '').toString(),
    kind: (j['kind'] ?? '').toString(),
    target: (j['target'] ?? '').toString(),
    state: (j['state'] ?? 'waiting').toString(),
    minutes: (j['minutes'] as num?)?.toInt() ?? 0,
    lastAlert: j['last_alert'] is num
        ? DateTime.fromMillisecondsSinceEpoch(
            ((j['last_alert'] as num) * 1000).round(),
          )
        : null,
  );
}

/// Rules, config problems and recent rule alerts from GET /watch.
class WatchSnapshot {
  const WatchSnapshot({
    this.rules = const [],
    this.problems = const [],
    this.alerts = const [],
  });

  final List<WatchRule> rules;
  final List<String> problems;
  final List<AlertEntry> alerts;

  factory WatchSnapshot.fromJson(Map<String, dynamic> j) => WatchSnapshot(
    rules: [
      for (final e in (j['rules'] as List? ?? const []))
        if (e is Map) WatchRule.fromJson(Map<String, dynamic>.from(e)),
    ],
    problems: [
      for (final e in (j['problems'] as List? ?? const [])) e.toString(),
    ],
    alerts: [
      for (final e in (j['alerts'] as List? ?? const []))
        if (e is Map) AlertEntry.fromJson(Map<String, dynamic>.from(e)),
    ],
  );
}

/// A screenshot file the agent took (GET /screenshots).
class ScreenshotInfo {
  const ScreenshotInfo({
    required this.name,
    required this.size,
    required this.modified,
  });

  final String name;
  final int size;
  final DateTime modified;

  factory ScreenshotInfo.fromJson(Map<String, dynamic> j) => ScreenshotInfo(
    name: (j['name'] ?? '').toString(),
    size: (j['size'] as num?)?.toInt() ?? 0,
    modified: DateTime.fromMillisecondsSinceEpoch(
      (((j['modified'] as num?) ?? 0) * 1000).round(),
    ),
  );
}
