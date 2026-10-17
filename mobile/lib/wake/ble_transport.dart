import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'cw_session.dart';

/// The real Bluetooth link to the ESP32 (flutter_blue_plus). UNVERIFIED: written against the
/// package's documented API but never run against a real board.
///
/// Each exchange scans for a device that advertises the Cortex Wake service, connects, writes
/// one command frame and waits for one notification. The connection is dropped afterwards so
/// the ESP32 can advertise again and the phone saves battery.
class FlutterBlueTransport implements CwTransport {
  FlutterBlueTransport({this.nameStartsWith = 'CortexWake-'});

  /// Only devices whose advertised name starts with this are used.
  final String nameStartsWith;

  static final Guid service = Guid('6e5c0001-8a0b-4c52-9f3e-c0de7a1c0f01');
  static final Guid command = Guid('6e5c0002-8a0b-4c52-9f3e-c0de7a1c0f01');
  static final Guid answer = Guid('6e5c0003-8a0b-4c52-9f3e-c0de7a1c0f01');

  @override
  Future<Uint8List?> exchange(Uint8List frame, Duration timeout) async {
    BluetoothDevice? device;
    StreamSubscription<List<int>>? sub;
    try {
      device = await _find(const Duration(seconds: 8));
      if (device == null) return null;
      await device.connect(timeout: const Duration(seconds: 8));
      final services = await device.discoverServices();
      BluetoothCharacteristic? cmd, ans;
      for (final s in services) {
        if (s.uuid != service) continue;
        for (final c in s.characteristics) {
          if (c.uuid == command) cmd = c;
          if (c.uuid == answer) ans = c;
        }
      }
      if (cmd == null || ans == null) return null;
      final completer = Completer<Uint8List?>();
      await ans.setNotifyValue(true);
      sub = ans.onValueReceived.listen((v) {
        if (!completer.isCompleted) completer.complete(Uint8List.fromList(v));
      });
      await cmd.write(frame, withoutResponse: false);
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      await sub?.cancel();
      try {
        await device?.disconnect();
      } catch (_) {}
    }
  }

  Future<BluetoothDevice?> _find(Duration limit) async {
    final found = Completer<BluetoothDevice?>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (r.advertisementData.advName.startsWith(nameStartsWith) && !found.isCompleted) {
          found.complete(r.device);
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(withServices: [service], timeout: limit);
      return await found.future.timeout(limit, onTimeout: () => null);
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }
}
