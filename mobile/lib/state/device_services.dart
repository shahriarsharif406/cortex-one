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

/// Is the phone on mobile data (the SIM)? Used for the automatic data-saver.
abstract class LinkMonitor {
  Future<bool> isOnMobile();
  Stream<bool> get onMobileChanges;
}

class ConnectivityLinkMonitor implements LinkMonitor {
  ConnectivityLinkMonitor([Connectivity? c]) : _c = c ?? Connectivity();

  final Connectivity _c;

  static bool _mobileOnly(List<ConnectivityResult> r) =>
      r.contains(ConnectivityResult.mobile) &&
      !r.contains(ConnectivityResult.wifi) &&
      !r.contains(ConnectivityResult.ethernet);

  @override
  Future<bool> isOnMobile() async {
    try {
      return _mobileOnly(await _c.checkConnectivity());
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<bool> get onMobileChanges =>
      _c.onConnectivityChanged.map(_mobileOnly).distinct();
}

/// Never reports mobile data (default for tests and platforms without the plugin).
class NoLinkMonitor implements LinkMonitor {
  @override
  Future<bool> isOnMobile() async => false;

  @override
  Stream<bool> get onMobileChanges => const Stream.empty();
}
