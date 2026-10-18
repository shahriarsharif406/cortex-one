// Cortex Wake: frame authentication. Portable, header-only, no heap, no libc beyond <stdint.h>.
// Same behaviour as docs/cortex-wake/reference.py and mobile/lib/wake/cw_protocol.dart:
// all three pass docs/cortex-wake/test_vectors.json. See docs/cortex-wake/PROTOCOL.md.
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace cw {

constexpr uint8_t kVersion = 1;
constexpr size_t kTagLen = 16;
constexpr uint32_t kMaxJump = 100000;   // a new counter may be at most this far ahead
constexpr uint16_t kMinPressMs = 100;
constexpr uint16_t kMaxPressMs = 1500;  // firmware cap: a longer PRESS is refused, never clamped

enum Cmd : uint8_t { PRESS = 1, STATE = 2, CALIBRATE = 3, PING = 4 };
enum Status : uint8_t { ST_OK = 0, ST_BAD_ARGS = 1, ST_BUSY = 2, ST_CAL_LOCKED = 3, ST_RATE = 4 };
enum ParseResult : uint8_t { OK = 0, BAD_LENGTH, BAD_VERSION, BAD_CMD, BAD_TAG, REPLAY, JUMP };

// ------------------------------------------------------------------ SHA-256
struct Sha256 {
  uint32_t h[8];
  uint8_t buf[64];
  uint64_t total;
  size_t fill;

  static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

  void init() {
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    for (int i = 0; i < 8; i++) h[i] = iv[i];
    total = 0;
    fill = 0;
  }

  void block(const uint8_t* p) {
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
      w[i] = (uint32_t(p[4 * i]) << 24) | (uint32_t(p[4 * i + 1]) << 16) | (uint32_t(p[4 * i + 2]) << 8) |
             uint32_t(p[4 * i + 3]);
    for (int i = 16; i < 64; i++) {
      uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
      uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      uint32_t ch = (e & f) ^ (~e & g);
      uint32_t t1 = hh + S1 + ch + k[i] + w[i];
      uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
      uint32_t t2 = S0 + mj;
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  }

  void update(const uint8_t* data, size_t len) {
    total += len;
    while (len > 0) {
      size_t take = 64 - fill;
      if (take > len) take = len;
      for (size_t i = 0; i < take; i++) buf[fill + i] = data[i];
      fill += take; data += take; len -= take;
      if (fill == 64) { block(buf); fill = 0; }
    }
  }

  void finish(uint8_t out[32]) {
    uint64_t bits = total * 8;
    uint8_t pad = 0x80;
    update(&pad, 1);
    uint8_t zero = 0;
    while (fill != 56) update(&zero, 1);
    uint8_t len8[8];
    for (int i = 0; i < 8; i++) len8[i] = uint8_t(bits >> (56 - 8 * i));
    update(len8, 8);
    for (int i = 0; i < 8; i++) {
      out[4 * i] = uint8_t(h[i] >> 24); out[4 * i + 1] = uint8_t(h[i] >> 16);
      out[4 * i + 2] = uint8_t(h[i] >> 8); out[4 * i + 3] = uint8_t(h[i]);
    }
  }
};

// -------------------------------------------------------------- HMAC-SHA256
inline void hmac_sha256(const uint8_t* key, size_t key_len, const uint8_t* msg, size_t msg_len,
                        uint8_t out[32]) {
  uint8_t k0[64];
  for (int i = 0; i < 64; i++) k0[i] = 0;
  if (key_len > 64) {
    Sha256 s; s.init(); s.update(key, key_len); s.finish(k0);
  } else {
    for (size_t i = 0; i < key_len; i++) k0[i] = key[i];
  }
  uint8_t ipad[64], opad[64];
  for (int i = 0; i < 64; i++) { ipad[i] = k0[i] ^ 0x36; opad[i] = k0[i] ^ 0x5c; }
  uint8_t inner[32];
  Sha256 s; s.init(); s.update(ipad, 64); s.update(msg, msg_len); s.finish(inner);
  Sha256 o; o.init(); o.update(opad, 64); o.update(inner, 32); o.finish(out);
}

// Constant-time comparison (no early exit).
inline bool ct_equal(const uint8_t* a, const uint8_t* b, size_t n) {
  uint8_t diff = 0;
  for (size_t i = 0; i < n; i++) diff |= uint8_t(a[i] ^ b[i]);
  return diff == 0;
}

inline int args_len(uint8_t cmd) {
  switch (cmd) {
    case PRESS: return 2;
    case STATE: return 0;
    case CALIBRATE: return 2;
    case PING: return 0;
    default: return -1;
  }
}

// tag = HMAC-SHA256(key, device_id[8] | counter[4 BE] | cmd | args)[0:16]
inline void command_tag(const uint8_t* key, size_t key_len, const uint8_t device_id[8], uint32_t counter,
                        uint8_t cmd, const uint8_t* args, size_t args_n, uint8_t tag[kTagLen]) {
  uint8_t msg[8 + 4 + 1 + 8];
  size_t n = 0;
  for (int i = 0; i < 8; i++) msg[n++] = device_id[i];
  msg[n++] = uint8_t(counter >> 24); msg[n++] = uint8_t(counter >> 16);
  msg[n++] = uint8_t(counter >> 8); msg[n++] = uint8_t(counter);
  msg[n++] = cmd;
  for (size_t i = 0; i < args_n && i < 8; i++) msg[n++] = args[i];
  uint8_t full[32];
  hmac_sha256(key, key_len, msg, n, full);
  for (size_t i = 0; i < kTagLen; i++) tag[i] = full[i];
}

struct Parsed {
  ParseResult result;
  uint8_t cmd;
  uint32_t counter;
  uint8_t args[2];
  uint8_t args_n;
};

// Anything but OK means: ignore the frame, change NOTHING (no reply, no counter update).
// The tag is checked BEFORE the counter, so a forger learns nothing about the stored counter.
inline Parsed parse_command(const uint8_t* frame, size_t len, const uint8_t* key, size_t key_len,
                            const uint8_t device_id[8], uint32_t stored_counter) {
  Parsed p = {OK, 0, 0, {0, 0}, 0};
  if (len < 6 + kTagLen) { p.result = BAD_LENGTH; return p; }
  if (frame[0] != kVersion) { p.result = BAD_VERSION; return p; }
  p.cmd = frame[1];
  int n = args_len(p.cmd);
  if (n < 0) { p.result = BAD_CMD; return p; }
  if (len != size_t(6 + n) + kTagLen) { p.result = BAD_LENGTH; return p; }
  p.counter = (uint32_t(frame[2]) << 24) | (uint32_t(frame[3]) << 16) | (uint32_t(frame[4]) << 8) |
              uint32_t(frame[5]);
  p.args_n = uint8_t(n);
  for (int i = 0; i < n; i++) p.args[i] = frame[6 + i];
  uint8_t tag[kTagLen];
  command_tag(key, key_len, device_id, p.counter, p.cmd, p.args, p.args_n, tag);
  if (!ct_equal(tag, frame + 6 + n, kTagLen)) { p.result = BAD_TAG; return p; }
  if (p.counter <= stored_counter) { p.result = REPLAY; return p; }
  if (p.counter - stored_counter > kMaxJump) { p.result = JUMP; return p; }
  return p;
}

// Response frame (device -> app): ver, status, counter[4], laptop, servo, tag[16]  = 24 bytes.
inline void build_response(const uint8_t* key, size_t key_len, const uint8_t device_id[8], uint8_t status,
                           uint32_t counter, uint8_t laptop, uint8_t servo, uint8_t out[8 + kTagLen]) {
  out[0] = kVersion; out[1] = status;
  out[2] = uint8_t(counter >> 24); out[3] = uint8_t(counter >> 16);
  out[4] = uint8_t(counter >> 8); out[5] = uint8_t(counter);
  out[6] = laptop; out[7] = servo;
  uint8_t msg[8 + 1 + 1 + 1 + 4 + 2];
  size_t n = 0;
  for (int i = 0; i < 8; i++) msg[n++] = device_id[i];
  msg[n++] = 'R'; msg[n++] = kVersion; msg[n++] = status;
  msg[n++] = out[2]; msg[n++] = out[3]; msg[n++] = out[4]; msg[n++] = out[5];
  msg[n++] = laptop; msg[n++] = servo;
  uint8_t full[32];
  hmac_sha256(key, key_len, msg, n, full);
  for (size_t i = 0; i < kTagLen; i++) out[8 + i] = full[i];
}

// Is a PRESS duration acceptable? Refused (not clamped) when outside the firmware limits.
inline bool press_ms_ok(uint16_t ms) { return ms >= kMinPressMs && ms <= kMaxPressMs; }


// ---- power-LED light sensor (optional). Mirrors docs/cortex-wake/reference.py classify_led().
// laptop byte of an answer: low nibble state (0 off, 1 on, 2 unknown, 3 blink), high nibble raw level.
enum Laptop : uint8_t { LAPTOP_OFF = 0, LAPTOP_ON = 1, LAPTOP_UNKNOWN = 2, LAPTOP_BLINK = 3 };
static const int LED_SWING_MIN = 400;
static const int LED_ON_MIN = 1200;
inline uint8_t classify_led(int lo, int hi) {
  if (lo < 0) lo = 0;
  if (hi < 0) hi = 0;
  if (lo > 4095) lo = 4095;
  if (hi > 4095) hi = 4095;
  if (lo > hi) return uint8_t(LAPTOP_UNKNOWN);
  int raw4 = hi >> 8;
  if (raw4 > 15) raw4 = 15;
  uint8_t state = (hi - lo >= LED_SWING_MIN) ? LAPTOP_BLINK : (lo >= LED_ON_MIN ? LAPTOP_ON : LAPTOP_OFF);
  return uint8_t((raw4 << 4) | state);
}

}  // namespace cw
