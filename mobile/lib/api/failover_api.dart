import 'dart:async';
import 'dart:typed_data';

import 'api_client.dart';
import 'health.dart';
import 'models.dart';

/// One computer, several addresses (Tailscale first, then the home LAN).
///
/// Read-only calls try the addresses in order with a short timeout per address and
/// remember the one that answered. Calls that CHANGE something (run an action, confirm,
/// start an AI task) are sent to exactly ONE address, never retried on another one: a
/// timeout does not prove the first address did not receive the request, and a retry could
/// run a high-risk action twice. Before such a call, if no address answered recently, a
/// quick health probe picks the working address first.
class FailoverApi implements CortexApi {
  FailoverApi({
    required this.endpoints,
    required String? token,
    required ApiFactory factory,
    String? lastWorking,
    this.attemptTimeout = const Duration(seconds: 5),
    this.mutatingTimeout = const Duration(seconds: 25),
    this.freshFor = const Duration(seconds: 20),
    this.onWorked,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       assert(endpoints.isNotEmpty) {
    _apis = [for (final e in endpoints) factory(e, token)];
    final i = lastWorking == null ? -1 : endpoints.indexOf(lastWorking);
    _preferred = i < 0 ? 0 : i;
  }

  final List<String> endpoints;
  final Duration attemptTimeout;
  final Duration mutatingTimeout;
  final Duration freshFor;

  /// Called with the address that just answered (the app stores it as "last working").
  final void Function(String endpoint)? onWorked;
  final DateTime Function() _now;

  late final List<CortexApi> _apis;
  int _preferred = 0;
  DateTime? _lastOk;

  /// The address that answered last, or null if none has yet.
  String? get activeEndpoint => _lastOk == null ? null : endpoints[_preferred];

  /// tailscale | lan | loopback | other, for the address that answered last.
  String get activeKind => linkKindOfUrl(endpoints[_preferred]);

  Iterable<int> _order() sync* {
    yield _preferred;
    for (var i = 0; i < endpoints.length; i++) {
      if (i != _preferred) yield i;
    }
  }

  void _worked(int i) {
    final changed = i != _preferred || _lastOk == null;
    _preferred = i;
    _lastOk = _now();
    if (changed) onWorked?.call(endpoints[i]);
  }

  /// Read-only: try every address in order.
  Future<T> _read<T>(Future<T> Function(CortexApi api) call) async {
    ApiException? lastNetwork;
    for (final i in _order()) {
      try {
        final result = await call(_apis[i]).timeout(
          attemptTimeout,
          onTimeout: () => throw const ApiException(ApiErrorKind.timeout),
        );
        _worked(i);
        return result;
      } on ApiException catch (e) {
        if (e.kind == ApiErrorKind.network || e.kind == ApiErrorKind.timeout) {
          lastNetwork = e;
          continue;
        }
        _worked(i); // it answered, the answer was an error: stay on this address
        rethrow;
      }
    }
    throw lastNetwork ?? const ApiException(ApiErrorKind.network);
  }

  bool get _fresh =>
      _lastOk != null && _now().difference(_lastOk!) < freshFor;

  /// Changes something: ONE address only, no retry elsewhere.
  Future<T> _write<T>(Future<T> Function(CortexApi api) call) async {
    if (!_fresh && endpoints.length > 1) {
      try {
        await _read((a) => a.health());
      } on ApiException {
        // no address answered: the single attempt below fails honestly
      }
    }
    final api = _apis[_preferred];
    final result = await call(api).timeout(
      mutatingTimeout,
      onTimeout: () => throw const ApiException(ApiErrorKind.timeout),
    );
    _lastOk = _now();
    return result;
  }

  // ---- reads ---------------------------------------------------------------
  @override
  Future<Health> health() => _read((a) => a.health());
  @override
  Future<TaskStatus> getTask(String id) => _read((a) => a.getTask(id));
  @override
  Future<List<PendingItem>> pending() => _read((a) => a.pending());
  @override
  Future<List<AuditEntry>> audit({int limit = 50}) =>
      _read((a) => a.audit(limit: limit));
  @override
  Future<Capabilities> capabilities() => _read((a) => a.capabilities());
  @override
  Future<List<AlertEntry>> alerts({int limit = 20}) =>
      _read((a) => a.alerts(limit: limit));
  @override
  Future<WatchSnapshot> watch() => _read((a) => a.watch());
  @override
  Future<List<ScreenshotInfo>> screenshots() => _read((a) => a.screenshots());
  @override
  Future<Uint8List> screenshotBytes(
    String name, {
    int? width,
    bool lowData = false,
  }) => _read((a) => a.screenshotBytes(name, width: width, lowData: lowData));

  // ---- the emergency stop is safe to repeat, so it may use any address -----
  @override
  Future<ActionOutcome> emergencyStop() => _read((a) => a.emergencyStop());

  // ---- writes: one address only --------------------------------------------
  @override
  Future<String> pair(String code, String deviceName) =>
      _apis.first.pair(code, deviceName);
  @override
  Future<ActionOutcome> runAction(
    String name, [
    Map<String, String> params = const {},
  ]) => _write((a) => a.runAction(name, params));
  @override
  Future<ActionRequestResult> requestAction(
    String name, [
    Map<String, String> params = const {},
  ]) => _write((a) => a.requestAction(name, params));
  @override
  Future<ActionOutcome> confirmAction(
    String name,
    String confirmToken, [
    Map<String, String> params = const {},
  ]) => _write((a) => a.confirmAction(name, confirmToken, params));
  @override
  Future<String> startTask(String instruction, {List<TaskImage> images = const []}) =>
      _write((a) => a.startTask(instruction, images: images));
  @override
  Future<ActionOutcome> confirm(String confirmToken) =>
      _write((a) => a.confirm(confirmToken));
  @override
  Future<void> cancel(String confirmToken) =>
      _write((a) => a.cancel(confirmToken));
}
