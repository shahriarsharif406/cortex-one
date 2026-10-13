import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/models.dart';

/// The list of high-risk requests waiting for the owner, refreshed in the
/// background. Confirm and cancel go through the agent's single-use tokens.
class PendingController extends ChangeNotifier {
  PendingController(
    this.api, {
    this.onError,
    this.pollEvery = const Duration(seconds: 5),
  });

  final CortexApi api;
  final Future<void> Function(Object error)? onError;
  final Duration pollEvery;

  List<PendingItem> items = const [];
  bool loading = false;
  Object? error;
  Timer? _timer;
  bool _disposed = false;

  void startPolling() {
    _timer?.cancel();
    refresh();
    _timer = Timer.periodic(pollEvery, (_) => refresh());
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    try {
      final next = await api.pending();
      items = next;
      error = null;
    } catch (e) {
      error = e;
      onError?.call(e);
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Returns the agent's result. Throws ApiException on failure. The request
  /// is removed from the list only when it is really gone (done, or the agent
  /// says the token is invalid/expired); on a network error it stays so the
  /// owner can try again before it expires.
  Future<ActionOutcome> confirm(PendingItem item) async {
    try {
      final out = await api.confirm(item.confirmToken);
      _drop(item);
      refresh();
      return out;
    } catch (e) {
      _handleFailure(item, e);
      rethrow;
    }
  }

  Future<void> cancel(PendingItem item) async {
    try {
      await api.cancel(item.confirmToken);
      _drop(item);
      refresh();
    } catch (e) {
      _handleFailure(item, e);
      rethrow;
    }
  }

  void _handleFailure(PendingItem item, Object e) {
    onError?.call(e);
    if (e is ApiException &&
        (e.kind == ApiErrorKind.forbidden || e.kind == ApiErrorKind.notFound)) {
      _drop(item);
      refresh();
    }
  }

  void _drop(PendingItem item) {
    items = [
      for (final i in items)
        if (i.confirmToken != item.confirmToken) i,
    ];
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
