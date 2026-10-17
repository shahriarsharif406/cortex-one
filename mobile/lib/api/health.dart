/// What the agent says about itself (GET /health, no token needed) and the pieces of the
/// two-step confirmation used by the Power card. No secrets live here.
library;

import 'models.dart';

class LastPowerRequest {
  const LastPowerRequest({required this.action, required this.ageSeconds});

  /// sleep | hibernate | shutdown | restart
  final String action;
  final int ageSeconds;
}

class Health {
  const Health({
    required this.computerId,
    required this.computerName,
    required this.version,
    this.uptimeSeconds = 0,
    this.batteryPercent,
    this.plugged,
    this.linkAddress,
    this.linkKind,
    this.networkState,
    this.lastPower,
  });

  final String computerId;
  final String computerName;
  final String version;
  final int uptimeSeconds;
  final int? batteryPercent;
  final bool? plugged;

  /// Which of the computer's own addresses this request arrived on, and what kind it is
  /// (loopback | tailscale | lan). Null when the agent could not tell.
  final String? linkAddress;
  final String? linkKind;

  /// ok | degraded | offline | unknown: the computer's own view of its internet.
  final String? networkState;
  final LastPowerRequest? lastPower;

  factory Health.fromJson(Map<String, dynamic> j) {
    final battery = j['battery'] is Map
        ? Map<String, dynamic>.from(j['battery'] as Map)
        : null;
    final link = j['link'] is Map
        ? Map<String, dynamic>.from(j['link'] as Map)
        : null;
    final net = j['network'] is Map
        ? Map<String, dynamic>.from(j['network'] as Map)
        : null;
    final power = j['last_power_request'] is Map
        ? Map<String, dynamic>.from(j['last_power_request'] as Map)
        : null;
    return Health(
      computerId: (j['computer_id'] ?? '').toString(),
      computerName: (j['computer_name'] ?? '').toString(),
      version: (j['version'] ?? '').toString(),
      uptimeSeconds: (j['uptime_seconds'] as num?)?.toInt() ?? 0,
      batteryPercent: (battery?['percent'] as num?)?.toInt(),
      plugged: battery?['plugged'] is bool ? battery!['plugged'] as bool : null,
      linkAddress: link?['address']?.toString(),
      linkKind: link?['kind']?.toString(),
      networkState: net?['state']?.toString(),
      lastPower: power == null
          ? null
          : LastPowerRequest(
              action: (power['action'] ?? '').toString(),
              ageSeconds: (power['age_seconds'] as num?)?.toInt() ?? 0,
            ),
    );
  }
}

/// First answer of a high-risk action: "confirm it with this single-use token".
class ConfirmTicket {
  const ConfirmTicket({
    required this.token,
    required this.expiresIn,
    this.message = '',
  });

  final String token;
  final int expiresIn;
  final String message;
}

/// Either the action ran at once ([outcome]) or the agent wants a confirmation ([ticket]).
class ActionRequestResult {
  const ActionRequestResult.done(ActionOutcome this.outcome) : ticket = null;
  const ActionRequestResult.needsConfirm(ConfirmTicket this.ticket)
    : outcome = null;

  final ActionOutcome? outcome;
  final ConfirmTicket? ticket;
}
