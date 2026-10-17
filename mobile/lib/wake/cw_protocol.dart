/// Cortex Wake BLE frames: HMAC-SHA256 authentication and the strictly increasing counter.
///
/// Same behaviour as docs/cortex-wake/reference.py and firmware/cortex-wake/include/cw_auth.h;
/// all three pass docs/cortex-wake/test_vectors.json. Layout: docs/cortex-wake/PROTOCOL.md.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const int cwVersion = 1;
const int cwTagLen = 16;
const int cwMaxJump = 100000;
const int cwMinPressMs = 100;
const int cwMaxPressMs = 1500;

enum CwCmd {
  press(1, 2),
  state(2, 0),
  calibrate(3, 2),
  ping(4, 0);

  const CwCmd(this.code, this.argsLen);
  final int code;
  final int argsLen;

  static CwCmd? fromCode(int c) {
    for (final v in values) {
      if (v.code == c) return v;
    }
    return null;
  }
}

/// Status byte of a response.
const int cwStOk = 0, cwStBadArgs = 1, cwStBusy = 2, cwStCalLocked = 3, cwStRate = 4;

/// What the ESP32's state sensor says (response `laptop` byte).
const int cwLaptopOff = 0, cwLaptopOn = 1, cwLaptopUnknown = 2;

enum CwParse { ok, badLength, badVersion, badCmd, badTag, replay, jump }

Uint8List _hmac(Uint8List key, List<int> msg) =>
    Uint8List.fromList(Hmac(sha256, key).convert(msg).bytes);

bool _ctEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

/// tag = HMAC-SHA256(key, device_id | counter(4, BE) | cmd | args)[0:16]
Uint8List cwCommandTag(
  Uint8List key,
  Uint8List deviceId,
  int counter,
  int cmd,
  Uint8List args,
) => Uint8List.sublistView(
  _hmac(key, [...deviceId, ..._u32(counter), cmd, ...args]),
  0,
  cwTagLen,
);

Uint8List cwBuildCommand({
  required Uint8List key,
  required Uint8List deviceId,
  required int counter,
  required CwCmd cmd,
  Uint8List? args,
}) {
  final a = args ?? Uint8List(0);
  if (a.length != cmd.argsLen) {
    throw ArgumentError('wrong argument length for ${cmd.name}');
  }
  if (counter < 1 || counter > 0xFFFFFFFF) {
    throw ArgumentError('counter out of range');
  }
  return Uint8List.fromList([
    cwVersion,
    cmd.code,
    ..._u32(counter),
    ...a,
    ...cwCommandTag(key, deviceId, counter, cmd.code, a),
  ]);
}

/// PRESS argument: milliseconds, big endian. Refuses values the firmware would refuse.
Uint8List cwPressArgs(int ms) {
  if (ms < cwMinPressMs || ms > cwMaxPressMs) {
    throw ArgumentError('press time must be $cwMinPressMs..$cwMaxPressMs ms');
  }
  return Uint8List(2)..buffer.asByteData().setUint16(0, ms);
}

class CwParsedCommand {
  const CwParsedCommand(this.result, {this.cmd, this.counter = 0, this.args});
  final CwParse result;
  final CwCmd? cmd;
  final int counter;
  final Uint8List? args;
}

/// What the firmware does with a frame (used by tests and by a software simulator of the ESP32).
CwParsedCommand cwParseCommand(
  Uint8List frame,
  Uint8List key,
  Uint8List deviceId,
  int storedCounter,
) {
  if (frame.length < 6 + cwTagLen) return const CwParsedCommand(CwParse.badLength);
  if (frame[0] != cwVersion) return const CwParsedCommand(CwParse.badVersion);
  final cmd = CwCmd.fromCode(frame[1]);
  if (cmd == null) return const CwParsedCommand(CwParse.badCmd);
  if (frame.length != 6 + cmd.argsLen + cwTagLen) {
    return CwParsedCommand(CwParse.badLength, cmd: cmd);
  }
  final counter = ByteData.sublistView(frame, 2, 6).getUint32(0);
  final args = Uint8List.sublistView(frame, 6, 6 + cmd.argsLen);
  final tag = Uint8List.sublistView(frame, 6 + cmd.argsLen);
  if (!_ctEqual(tag, cwCommandTag(key, deviceId, counter, cmd.code, args))) {
    return CwParsedCommand(CwParse.badTag, cmd: cmd, counter: counter);
  }
  if (counter <= storedCounter) {
    return CwParsedCommand(CwParse.replay, cmd: cmd, counter: counter);
  }
  if (counter - storedCounter > cwMaxJump) {
    return CwParsedCommand(CwParse.jump, cmd: cmd, counter: counter);
  }
  return CwParsedCommand(
    CwParse.ok,
    cmd: cmd,
    counter: counter,
    args: Uint8List.fromList(args),
  );
}

class CwResponse {
  const CwResponse({
    required this.status,
    required this.counter,
    required this.laptop,
    required this.servo,
  });

  final int status;
  final int counter;

  /// cwLaptopOff | cwLaptopOn | cwLaptopUnknown
  final int laptop;

  /// 0 at rest, 1 pressing, 2 calibrating
  final int servo;

  bool get ok => status == cwStOk;
}

Uint8List _responseTag(
  Uint8List key,
  Uint8List deviceId,
  int status,
  int counter,
  int laptop,
  int servo,
) => Uint8List.sublistView(
  _hmac(key, [
    ...deviceId,
    0x52, // 'R'
    cwVersion,
    status,
    ..._u32(counter),
    laptop,
    servo,
  ]),
  0,
  cwTagLen,
);

Uint8List cwBuildResponse({
  required Uint8List key,
  required Uint8List deviceId,
  required int status,
  required int counter,
  required int laptop,
  required int servo,
}) => Uint8List.fromList([
  cwVersion,
  status,
  ..._u32(counter),
  laptop,
  servo,
  ..._responseTag(key, deviceId, status, counter, laptop, servo),
]);

/// null when the frame is not a genuine answer from OUR device.
CwResponse? cwParseResponse(Uint8List frame, Uint8List key, Uint8List deviceId) {
  if (frame.length != 8 + cwTagLen || frame[0] != cwVersion) return null;
  final status = frame[1];
  final counter = ByteData.sublistView(frame, 2, 6).getUint32(0);
  final laptop = frame[6], servo = frame[7];
  final tag = Uint8List.sublistView(frame, 8);
  if (!_ctEqual(tag, _responseTag(key, deviceId, status, counter, laptop, servo))) {
    return null;
  }
  return CwResponse(status: status, counter: counter, laptop: laptop, servo: servo);
}

/// The app's side of the counter: strictly increasing, persisted BEFORE a frame is sent
/// (a crash after sending must never let the same number be used again).
abstract class CwCounterStore {
  Future<int> read();
  Future<void> write(int value);
}

class MemoryCwCounterStore implements CwCounterStore {
  MemoryCwCounterStore([this.value = 0]);
  int value;

  @override
  Future<int> read() async => value;

  @override
  Future<void> write(int v) async => value = v;
}

class CwCounter {
  CwCounter(this._store);
  final CwCounterStore _store;

  /// The next number to use. It is saved first, then returned.
  Future<int> next() async {
    final n = (await _store.read()) + 1;
    if (n > 0xFFFFFFFF) {
      throw StateError('counter exhausted: re-provision the device');
    }
    await _store.write(n);
    return n;
  }

  /// After a device answered, never fall behind what it has seen.
  Future<void> observe(int deviceCounter) async {
    if (deviceCounter > await _store.read()) await _store.write(deviceCounter);
  }

  /// A command timed out: it may have been dropped because the app's counter is behind (for
  /// example after a reinstall). Jump ahead (within the firmware's allowed window).
  Future<void> jumpAhead([int by = 1000]) async {
    final n = (await _store.read()) + by.clamp(1, cwMaxJump ~/ 2);
    if (n > 0xFFFFFFFF) throw StateError('counter exhausted: re-provision the device');
    await _store.write(n);
  }
}
