import 'dart:typed_data';

import 'cw_protocol.dart';
import 'cw_session.dart';
import 'sms_command.dart';
import 'wake_totp.dart';

/// One line of the gateway log. Never holds an SMS body, a code, a key or a full number.
class GatewayEvent {
  GatewayEvent(this.time, this.kind, [this.note = '']);

  final DateTime time;
  final String kind;
  final String note;
}

class GatewayReply {
  const GatewayReply({
    required this.ok,
    required this.message,
    this.laptop = 'unknown',
  });

  /// True when the power button was really pressed (or, for status, the answer is trustworthy).
  final bool ok;
  final String message;

  /// on | off | unknown
  final String laptop;
}

/// The decision logic of the Cortex Wake gateway phone. Pure Dart: SMS, BLE and the clock are
/// injected, so every rule below is covered by tests without a radio.
class GatewayController {
  GatewayController({
    required Set<String> allowedNumbers,
    required this.totp,
    required this.session,
    DateTime Function()? now,
    this.pressMs = 400,
    this.pressCooldown = const Duration(seconds: 30),
    this.maxFailures = 3,
    this.lockout = const Duration(minutes: 15),
    this.replyEvery = const Duration(seconds: 30),
  }) : allowed = {
         for (final n in allowedNumbers)
           if (normalizePhone(n) case final p?) p,
       },
       _now = now ?? DateTime.now;

  final Set<String> allowed;
  final WakeTotp totp;
  final CwSession session;
  final int pressMs;
  final Duration pressCooldown;
  final int maxFailures;
  final Duration lockout;
  final Duration replyEvery;
  final DateTime Function() _now;

  final List<GatewayEvent> events = [];
  int _failures = 0;
  DateTime? _lockedUntil;
  DateTime? _lastPress;
  final Map<String, DateTime> _lastReply = {};
  bool _busy = false;

  bool get locked => _lockedUntil != null && _now().isBefore(_lockedUntil!);

  void _log(String kind, [String note = '']) {
    events.add(GatewayEvent(_now(), kind, note));
    if (events.length > 50) events.removeAt(0);
  }

  static String _mask(String n) =>
      n.length <= 4 ? '***' : '${'*' * (n.length - 3)}${n.substring(n.length - 3)}';

  // ------------------------------------------------------------------ SMS
  /// Returns the SMS text to send back, or null to stay silent.
  Future<String?> handleSms(String sender, String body) async {
    final from = normalizePhone(sender);
    if (from == null || !allowed.contains(from)) {
      _log('unknown_sender'); // no content, no number: silence is the answer
      return null;
    }
    if (locked) {
      _log('locked_ignored', _mask(from));
      return null;
    }
    final cmd = parseWakeSms(body);
    if (cmd == null) {
      _log('bad_format', _mask(from));
      return _limitedReply(from, 'Cortex Wake: ON <code> | PRESS <code> | STATUS');
    }
    if (cmd.kind == WakeCommandKind.status) {
      _log('status', _mask(from));
      return _limitedReply(from, (await status()).message);
    }
    if (_busy) return _limitedReply(from, 'Cortex Wake is busy. Try again in a moment.');
    _busy = true;
    try {
      if (!await totp.verifyAndConsume(cmd.code!, _now())) {
        _failures++;
        _log('bad_code', _mask(from));
        if (_failures >= maxFailures) {
          _lockedUntil = _now().add(lockout);
          _failures = 0;
          _log('lockout', '${lockout.inMinutes} min');
          return 'Wrong code. Locked for ${lockout.inMinutes} minutes.';
        }
        return 'Wrong code.';
      }
      _failures = 0;
      _log(cmd.kind.name, '${_mask(from)}${cmd.force ? ' force' : ''}');
      final r = await _powerButton(
        wake: cmd.kind == WakeCommandKind.on,
        force: cmd.force,
      );
      return r.message;
    } finally {
      _busy = false;
    }
  }

  String? _limitedReply(String to, String text) {
    final last = _lastReply[to];
    if (last != null && _now().difference(last) < replyEvery) return null;
    _lastReply[to] = _now();
    return text;
  }

  // ----------------------------------------------------------------- HTTP
  /// For the authenticated HTTP listener: the same safety rules as the PRESS SMS command.
  Future<GatewayReply> press({bool force = false}) async {
    if (_busy) return const GatewayReply(ok: false, message: 'Busy. Try again in a moment.');
    _busy = true;
    try {
      _log('http_press', force ? 'force' : '');
      return await _powerButton(wake: false, force: force);
    } finally {
      _busy = false;
    }
  }

  Future<GatewayReply> status() async {
    final out = await session.state();
    final r = out.response;
    if (r == null) {
      return const GatewayReply(
        ok: false,
        message: 'Cortex Wake: cannot reach the ESP32 over Bluetooth.',
      );
    }
    final laptop = _laptopName(r.laptop);
    final text = switch (laptop) {
      'on' => 'laptop looks ON',
      'off' => 'laptop looks OFF',
      _ => 'laptop state unknown (no sensor, or the USB port stays powered)',
    };
    return GatewayReply(ok: true, message: 'Cortex Wake: $text.', laptop: laptop);
  }

  static String _laptopName(int b) => switch (b) {
    cwLaptopOn => 'on',
    cwLaptopOff => 'off',
    _ => 'unknown',
  };

  // ------------------------------------------------------------ the press
  /// [wake] = the ON command (the owner wants the laptop awake: an ON laptop is left alone).
  /// PRESS (wake false) is a plain button press. Both refuse when the state is unknown unless
  /// [force]; PRESS on a laptop that looks ON also needs [force].
  Future<GatewayReply> _powerButton({required bool wake, required bool force}) async {
    final last = _lastPress;
    if (last != null && _now().difference(last) < pressCooldown) {
      return const GatewayReply(
        ok: false,
        message: 'Cortex Wake: pressed a moment ago. Wait 30 seconds.',
      );
    }
    final st = await session.state();
    final r = st.response;
    if (r == null) {
      return const GatewayReply(
        ok: false,
        message: 'Cortex Wake: cannot reach the ESP32 over Bluetooth. Nothing was pressed.',
      );
    }
    final laptop = _laptopName(r.laptop);
    if (laptop == 'on') {
      if (wake) {
        return const GatewayReply(
          ok: false,
          laptop: 'on',
          message: 'Cortex Wake: laptop looks ON already. Not pressed.',
        );
      }
      if (!force) {
        return const GatewayReply(
          ok: false,
          laptop: 'on',
          message: 'Cortex Wake: laptop looks ON. Pressing may sleep or shut it down. '
              'Not pressed. To do it anyway: PRESS <code> FORCE.',
        );
      }
    } else if (laptop == 'unknown' && !force) {
      return GatewayReply(
        ok: false,
        message: 'Cortex Wake: laptop state is UNKNOWN. Not pressed. To press anyway: '
            '${wake ? 'ON' : 'PRESS'} <code> FORCE (on a running laptop this may sleep or '
            'shut it down).',
      );
    }
    _lastPress = _now();
    final out = await session.press(pressMs);
    final a = out.response;
    final forced = force && laptop != 'off' ? ' (forced; state was $laptop)' : '';
    if (a == null) {
      _log('press_no_answer');
      return GatewayReply(
        ok: false,
        laptop: laptop,
        message: 'Cortex Wake: no answer after the press. It may or may not have pressed. '
            'Send STATUS to check.',
      );
    }
    switch (a.status) {
      case cwStOk:
        _log('pressed', forced);
        return GatewayReply(
          ok: true,
          laptop: laptop,
          message: 'Cortex Wake: power button pressed$forced. This does not prove the laptop '
              'woke up (battery, BIOS). Send STATUS in a minute.',
        );
      case cwStBusy:
        return GatewayReply(ok: false, laptop: laptop, message: 'Cortex Wake: ESP32 is busy.');
      case cwStRate:
        return GatewayReply(
          ok: false,
          laptop: laptop,
          message: 'Cortex Wake: ESP32 refuses presses this close together.',
        );
      default:
        return GatewayReply(
          ok: false,
          laptop: laptop,
          message: 'Cortex Wake: ESP32 refused the press (status ${a.status}).',
        );
    }
  }
}

/// A software ESP32 for tests and demos: the same rules as the firmware, using the shared
/// protocol code. Keeps the stored counter, refuses bad frames silently, never exceeds limits.
class SimulatedEsp32 implements CwTransport {
  SimulatedEsp32({
    required this.key,
    required this.deviceId,
    this.laptop = cwLaptopOff,
    int counter = 0,
    this.dropAnswers = false,
  }) : storedCounter = counter;

  final Uint8List key;
  final Uint8List deviceId;
  int laptop;
  int storedCounter;
  bool dropAnswers;
  int presses = 0;
  int ignored = 0;
  final List<int> pressDurations = [];

  @override
  Future<Uint8List?> exchange(Uint8List frame, Duration timeout) async {
    final p = cwParseCommand(frame, key, deviceId, storedCounter);
    if (p.result != CwParse.ok) {
      ignored++;
      return null; // bad frames are ignored without any answer
    }
    storedCounter = p.counter; // saved before acting
    var status = cwStOk;
    if (p.cmd == CwCmd.press) {
      final ms = ByteData.sublistView(p.args!).getUint16(0);
      if (ms < cwMinPressMs || ms > cwMaxPressMs) {
        status = cwStBadArgs;
      } else {
        presses++;
        pressDurations.add(ms);
      }
    } else if (p.cmd == CwCmd.calibrate) {
      status = cwStCalLocked; // needs the physical button: never over the air alone
    }
    if (dropAnswers) return null;
    return cwBuildResponse(
      key: key,
      deviceId: deviceId,
      status: status,
      counter: p.counter,
      laptop: laptop,
      servo: 0,
    );
  }
}
