/// Parsing of the Cortex Wake SMS commands:  ON <code>   PRESS <code>   STATUS
/// (optionally followed by FORCE). Bangla and Arabic-Indic digits are accepted for the code.
library;

enum WakeCommandKind { on, press, status }

class WakeCommand {
  const WakeCommand(this.kind, {this.code, this.force = false});

  final WakeCommandKind kind;

  /// The 6-digit one-time code (ASCII digits), null for STATUS.
  final String? code;

  /// The sender explicitly accepts pressing when the laptop state is unknown (or, for PRESS,
  /// when the sensor says it is ON).
  final bool force;
}

const _banglaZero = 0x09E6; // ০
const _arabicIndicZero = 0x0660; // ٠
const _extArabicIndicZero = 0x06F0; // ۰
const _fullWidthZero = 0xFF10; // ０

/// Maps every decimal digit script we accept to ASCII 0-9. Other characters pass through.
String normalizeDigits(String text) {
  final out = StringBuffer();
  for (final r in text.runes) {
    var d = -1;
    for (final zero in [_banglaZero, _arabicIndicZero, _extArabicIndicZero, _fullWidthZero]) {
      if (r >= zero && r <= zero + 9) d = r - zero;
    }
    out.writeCharCode(d >= 0 ? 0x30 + d : r);
  }
  return out.toString();
}

/// Control characters, bidi marks and zero-width characters have no place in a command.
/// (Tab and line feed are ordinary white space.) Written with numbers on purpose.
bool _hasHiddenCharacters(String text) {
  for (final r in text.runes) {
    if (r <= 0x08 ||
        (r >= 0x0b && r <= 0x1f) ||
        r == 0x7f ||
        (r >= 0x200b && r <= 0x200f) ||
        (r >= 0x202a && r <= 0x202e) ||
        (r >= 0x2060 && r <= 0x2064) ||
        r == 0xfeff) {
      return true;
    }
  }
  return false;
}

/// null = not a command we understand (the caller decides whether to answer).
WakeCommand? parseWakeSms(String body) {
  if (body.length > 64) return null;
  // control characters and zero-width marks have no business in a command
  if (_hasHiddenCharacters(body)) return null;
  final tokens = normalizeDigits(body)
      .trim()
      .split(RegExp(r'[\s 　]+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return null;
  final head = tokens.first.toUpperCase();
  final rest = tokens.sublist(1);
  if (head == 'STATUS') {
    return rest.isEmpty ? const WakeCommand(WakeCommandKind.status) : null;
  }
  final kind = switch (head) {
    'ON' => WakeCommandKind.on,
    'PRESS' => WakeCommandKind.press,
    _ => null,
  };
  if (kind == null || rest.isEmpty || rest.length > 2) return null;
  final code = rest.first;
  if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) return null;
  var force = false;
  if (rest.length == 2) {
    if (rest[1].toUpperCase() != 'FORCE') return null;
    force = true;
  }
  return WakeCommand(kind, code: code, force: force);
}

/// Canonical form of a phone number for the allowlist: "+8801711111111".
/// Handles 017..., 8801..., +8801..., 00880..., with spaces and dashes. Returns null for junk.
String? normalizePhone(String raw) {
  var t = normalizeDigits(raw).replaceAll(RegExp(r'[\s\-().]'), '');
  if (t.isEmpty) return null;
  if (t.startsWith('00')) t = '+${t.substring(2)}';
  if (!RegExp(r'^\+?[0-9]{6,15}$').hasMatch(t)) return null;
  if (!t.startsWith('+')) {
    if (t.startsWith('880')) {
      t = '+$t';
    } else if (t.startsWith('01') && t.length == 11) {
      t = '+880${t.substring(1)}';
    } else {
      t = '+$t';
    }
  }
  return t;
}
