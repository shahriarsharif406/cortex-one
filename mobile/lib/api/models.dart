/// Plain data classes for the Cortex One agent API. No secrets live here.
library;

Map<String, String> _stringMap(dynamic v) {
  if (v is! Map) return const {};
  return {for (final e in v.entries) e.key.toString(): e.value.toString()};
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
