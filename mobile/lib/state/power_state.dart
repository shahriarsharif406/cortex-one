import '../api/health.dart';

/// What the phone can honestly say about a computer.
enum PowerState {
  /// The agent answered a moment ago.
  online,

  /// It went away right after a sleep/hibernate request. "Probably": the phone cannot see
  /// the difference between sleeping and a dead network.
  sleeping,

  /// Not answering and the last known reason is shut down, restart, a flat battery, or unknown.
  offline,

  /// The phone has never heard from this computer.
  unknown,
}

/// Why the phone thinks so; the UI turns this into a sentence.
enum PowerReason {
  none,
  sleepRequested,
  hibernateRequested,
  shutdownRequested,
  restartRequested,
  batteryLow,
  noAnswer,
  neverSeen,
}

class PowerStatus {
  const PowerStatus(this.state, this.reason, {this.lastSeen, this.requestedAt});

  final PowerState state;
  final PowerReason reason;
  final DateTime? lastSeen;

  /// When the sleep/shutdown request that explains the state was made, if known.
  final DateTime? requestedAt;
}

/// A power request this phone sent (or that the agent reported in its last /health).
class PowerHint {
  const PowerHint(this.action, this.at);
  final String action;
  final DateTime at;
}

/// Decides the badge. [reachable] is the result of the latest /health attempt.
///
/// Evidence order when the computer does not answer:
///   1. a power request made from this phone, or reported by the agent in its last health
///      answer, made at or after the last time it was seen answering;
///   2. a low, unplugged battery in the last health answer;
///   3. otherwise just "no answer" (asleep, off, no network: the phone cannot tell).
PowerStatus classifyPower({
  required bool reachable,
  required DateTime now,
  DateTime? lastSeen,
  Health? lastHealth,
  PowerHint? phoneHint,
  Duration hintValidFor = const Duration(hours: 12),
}) {
  if (reachable) {
    return PowerStatus(PowerState.online, PowerReason.none, lastSeen: now);
  }
  if (lastSeen == null && phoneHint == null) {
    return const PowerStatus(PowerState.unknown, PowerReason.neverSeen);
  }
  PowerHint? hint = phoneHint;
  final agent = lastHealth?.lastPower;
  if (agent != null && lastSeen != null) {
    final at = lastSeen.subtract(Duration(seconds: agent.ageSeconds));
    if (hint == null || at.isAfter(hint.at)) hint = PowerHint(agent.action, at);
  }
  if (hint != null &&
      now.difference(hint.at) < hintValidFor &&
      (lastSeen == null ||
          !hint.at.isBefore(lastSeen.subtract(const Duration(minutes: 2))))) {
    switch (hint.action) {
      case 'sleep':
        return PowerStatus(
          PowerState.sleeping,
          PowerReason.sleepRequested,
          lastSeen: lastSeen,
          requestedAt: hint.at,
        );
      case 'hibernate':
        return PowerStatus(
          PowerState.sleeping,
          PowerReason.hibernateRequested,
          lastSeen: lastSeen,
          requestedAt: hint.at,
        );
      case 'shutdown':
        return PowerStatus(
          PowerState.offline,
          PowerReason.shutdownRequested,
          lastSeen: lastSeen,
          requestedAt: hint.at,
        );
      case 'restart':
        // A restart is only "offline" for a few minutes; after that something is wrong.
        return PowerStatus(
          PowerState.offline,
          now.difference(hint.at) < const Duration(minutes: 10)
              ? PowerReason.restartRequested
              : PowerReason.noAnswer,
          lastSeen: lastSeen,
          requestedAt: hint.at,
        );
    }
  }
  final pct = lastHealth?.batteryPercent;
  if (pct != null && lastHealth?.plugged == false && pct <= 10) {
    return PowerStatus(
      PowerState.offline,
      PowerReason.batteryLow,
      lastSeen: lastSeen,
    );
  }
  return PowerStatus(
    PowerState.offline,
    PowerReason.noAnswer,
    lastSeen: lastSeen,
  );
}
