import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:local_auth/local_auth.dart';

/// Asks the phone's own biometric / screen-lock prompt. Every confirmation of a risky action
/// goes through this first, so someone who only holds an unlocked phone cannot approve one.
abstract class BiometricGate {
  /// True only if the owner passed the prompt. False when cancelled, failed, or when the
  /// phone has no screen lock at all (nothing to prove who is holding it).
  Future<bool> authenticate(String reason);
}

class LocalAuthGate implements BiometricGate {
  LocalAuthGate([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> authenticate(String reason) async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false, // fingerprint/face OR the phone's PIN / pattern
      );
    } catch (_) {
      return false; // any error means "not proven": the action is not confirmed
    }
  }
}

/// What the phone's own connection looks like right now.
class LinkSnapshot {
  const LinkSnapshot({this.onMobile = false, this.offline = false});

  /// On mobile data (the SIM) and not on Wi-Fi/Ethernet: the automatic data-saver trigger.
  final bool onMobile;

  /// No network at all (not even a weak one): voice typing must then run on the phone.
  final bool offline;

  @override
  bool operator ==(Object other) =>
      other is LinkSnapshot &&
      other.onMobile == onMobile &&
      other.offline == offline;

  @override
  int get hashCode => Object.hash(onMobile, offline);
}

abstract class LinkMonitor {
  Future<LinkSnapshot> read();
  Stream<LinkSnapshot> get changes;
}

class ConnectivityLinkMonitor implements LinkMonitor {
  ConnectivityLinkMonitor([Connectivity? c]) : _c = c ?? Connectivity();

  final Connectivity _c;

  static LinkSnapshot _snap(List<ConnectivityResult> r) => LinkSnapshot(
    onMobile:
        r.contains(ConnectivityResult.mobile) &&
        !r.contains(ConnectivityResult.wifi) &&
        !r.contains(ConnectivityResult.ethernet),
    offline: r.isEmpty || r.every((e) => e == ConnectivityResult.none),
  );

  @override
  Future<LinkSnapshot> read() async {
    try {
      return _snap(await _c.checkConnectivity());
    } catch (_) {
      return const LinkSnapshot();
    }
  }

  @override
  Stream<LinkSnapshot> get changes =>
      _c.onConnectivityChanged.map(_snap).distinct();
}

/// Never reports mobile data or "offline" (default for tests and platforms without the plugin).
class NoLinkMonitor implements LinkMonitor {
  @override
  Future<LinkSnapshot> read() async => const LinkSnapshot();

  @override
  Stream<LinkSnapshot> get changes => const Stream.empty();
}
