// Test shim: compiles cw_auth.h to WebAssembly (no libc) so Node can run it against
// docs/cortex-wake/test_vectors.json on a PC. NOT part of the firmware.
#include "../include/cw_auth.h"

extern "C" {
// the compiler may turn byte loops into these calls; there is no libc in a bare wasm module
void* memcpy(void* d, const void* s, size_t n) {
  uint8_t* dd = (uint8_t*)d;
  const uint8_t* ss = (const uint8_t*)s;
  for (size_t i = 0; i < n; i++) dd[i] = ss[i];
  return d;
}
void* memset(void* d, int c, size_t n) {
  uint8_t* dd = (uint8_t*)d;
  for (size_t i = 0; i < n; i++) dd[i] = (uint8_t)c;
  return d;
}

static uint8_t g_scratch[8192];

__attribute__((used)) uint8_t* scratch_ptr() { return g_scratch; }

__attribute__((used)) void t_hmac(const uint8_t* key, size_t klen, const uint8_t* msg, size_t mlen,
                                  uint8_t* out) {
  cw::hmac_sha256(key, klen, msg, mlen, out);
}

// out[0]=result, out[1]=cmd, out[2..5]=counter BE, out[6..7]=args
__attribute__((used)) int t_parse(const uint8_t* frame, size_t len, const uint8_t* key, size_t klen,
                                  const uint8_t* dev, uint32_t stored, uint8_t* out) {
  cw::Parsed p = cw::parse_command(frame, len, key, klen, dev, stored);
  out[0] = p.result;
  out[1] = p.cmd;
  out[2] = uint8_t(p.counter >> 24); out[3] = uint8_t(p.counter >> 16);
  out[4] = uint8_t(p.counter >> 8); out[5] = uint8_t(p.counter);
  out[6] = p.args[0]; out[7] = p.args[1];
  return p.result;
}

__attribute__((used)) void t_response(const uint8_t* key, size_t klen, const uint8_t* dev, int status,
                                      uint32_t counter, int laptop, int servo, uint8_t* out) {
  cw::build_response(key, klen, dev, uint8_t(status), counter, uint8_t(laptop), uint8_t(servo), out);
}

__attribute__((used)) int t_led(int lo, int hi) { return cw::classify_led(lo, hi); }

__attribute__((used)) int t_press_ok(int ms) { return cw::press_ms_ok(uint16_t(ms)) ? 1 : 0; }
}
