import 'dart:async';
import 'dart:typed_data';

import 'cw_protocol.dart';

/// One write + one notification over BLE (or a software stand-in in tests).
abstract class CwTransport {
  /// Sends [frame] to the device and returns the answer bytes, or null when nothing came back
  /// in time (out of range, ESP32 off, or the device ignored the frame).
  Future<Uint8List?> exchange(Uint8List frame, Duration timeout);
}

/// What the gateway learns from one exchange.
class CwOutcome {
  const CwOutcome.answer(this.response) : failure = null;
  const CwOutcome.failure(this.failure) : response = null;

  final CwResponse? response;

  /// no_answer | bad_answer
  final String? failure;

  bool get reached => response != null;
}

/// Counter handling, frame building and answer verification for one ESP32.
class CwSession {
  CwSession({
    required this.key,
    required this.deviceId,
    required this.transport,
    required CwCounterStore counterStore,
    this.timeout = const Duration(seconds: 6),
  }) : _counter = CwCounter(counterStore);

  final Uint8List key;
  final Uint8List deviceId;
  final CwTransport transport;
  final Duration timeout;
  final CwCounter _counter;

  /// Sends one command. With [retry], silence is answered by jumping the counter ahead once
  /// and sending the SAME read-only command again (a missing answer can mean the app's counter is
  /// behind the device's, for example after a reinstall). Never use [retry] for a command that
  /// moves the servo: the device may have pressed and only the answer was lost.
  Future<CwOutcome> send(CwCmd cmd, {Uint8List? args, bool retry = true}) async {
    for (var attempt = 0; attempt < (retry ? 2 : 1); attempt++) {
      final counter = await _counter.next();
      final frame = cwBuildCommand(
        key: key,
        deviceId: deviceId,
        counter: counter,
        cmd: cmd,
        args: args,
      );
      final raw = await transport.exchange(frame, timeout);
      if (raw != null) {
        final r = cwParseResponse(raw, key, deviceId);
        if (r == null) return const CwOutcome.failure('bad_answer');
        await _counter.observe(r.counter);
        return CwOutcome.answer(r);
      }
      if (retry && attempt == 0) await _counter.jumpAhead();
    }
    return const CwOutcome.failure('no_answer');
  }

  Future<CwOutcome> state() => send(CwCmd.state);

  /// PRESS is sent once. If nothing comes back we do NOT know whether the servo moved: the
  /// caller must say so, never press again on its own. A read-only STATE query then re-syncs
  /// the counter so the next command is accepted.
  Future<CwOutcome> press(int ms) async {
    final out = await send(CwCmd.press, args: cwPressArgs(ms), retry: false);
    if (!out.reached && out.failure == 'no_answer') await state();
    return out;
  }
}
