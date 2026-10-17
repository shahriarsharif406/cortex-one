/// One-time codes (RFC 6238, SHA-1, 6 digits, 30 s) for the Cortex Wake SMS gateway.
///
/// This is the "wake secret": a DIFFERENT secret from the laptop agent's SMS secret. A code is
/// accepted at most once: the last accepted time step is stored and only a later step passes.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; // secret-scan:allow base32 alphabet, not a secret

String base32Encode(Uint8List data) {
  final out = StringBuffer();
  var buffer = 0, bits = 0;
  for (final b in data) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(_alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

Uint8List? base32Decode(String text) {
  final clean = text.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');
  if (clean.isEmpty) return null;
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final c in clean.split('')) {
    final v = _alphabet.indexOf(c);
    if (v < 0) return null;
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 0xFF);
      bits -= 8;
      buffer &= (1 << bits) - 1;
    }
  }
  return Uint8List.fromList(out);
}

/// A fresh 160-bit secret, shown to the owner ONCE (to type into an authenticator app).
String newWakeSecret([Random? rng]) {
  final r = rng ?? Random.secure();
  return base32Encode(Uint8List.fromList(List.generate(20, (_) => r.nextInt(256))));
}

String totpCode(Uint8List secret, int step) {
  final counter = Uint8List(8)..buffer.asByteData().setUint64(0, step);
  final mac = Hmac(sha1, secret).convert(counter).bytes;
  final o = mac[mac.length - 1] & 0x0F;
  final bin = ((mac[o] & 0x7F) << 24) |
      (mac[o + 1] << 16) |
      (mac[o + 2] << 8) |
      mac[o + 3];
  return (bin % 1000000).toString().padLeft(6, '0');
}

/// Remembers the last accepted step. Implemented on the secure store in the app.
abstract class TotpStepStore {
  Future<int> lastStep();
  Future<void> saveStep(int step);
}

class MemoryTotpStepStore implements TotpStepStore {
  int step = 0;

  @override
  Future<int> lastStep() async => step;

  @override
  Future<void> saveStep(int s) async => step = s;
}

class WakeTotp {
  WakeTotp({required this.secret, required this.store, this.window = 1});

  final Uint8List secret;
  final TotpStepStore store;

  /// Steps either side of "now" that are accepted (1 = about +-30 s of clock drift).
  final int window;

  /// True exactly once per valid code. The step is saved BEFORE returning true.
  Future<bool> verifyAndConsume(String code, DateTime now) async {
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) return false;
    final current = now.millisecondsSinceEpoch ~/ 30000;
    final last = await store.lastStep();
    int? matched;
    for (var s = current - window; s <= current + window; s++) {
      // constant work per candidate: compare every one, remember the latest match
      if (_same(totpCode(secret, s), code) && s > last) matched = s;
    }
    if (matched == null) return false;
    await store.saveStep(matched);
    return true;
  }

  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return d == 0;
  }
}
