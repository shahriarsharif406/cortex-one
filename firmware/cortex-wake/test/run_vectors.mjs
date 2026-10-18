// Runs cw_auth.h (compiled to wasm) against docs/cortex-wake/test_vectors.json.
// usage: node run_vectors.mjs <cw_auth.wasm> <test_vectors.json>
import { readFileSync } from 'node:fs';

const [wasmPath, vectorsPath] = process.argv.slice(2);
const v = JSON.parse(readFileSync(vectorsPath, 'utf8'));
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), {});
const x = instance.exports;
const mem = () => new Uint8Array(x.memory.buffer);
const base = x.scratch_ptr();
const hex = (b) => Buffer.from(b).toString('hex');
const bytes = (h) => Uint8Array.from(Buffer.from(h, 'hex'));

// scratch layout: key @0, dev @64, in @128, out @4224
const KEY = 0, DEV = 64, IN = 128, OUT = 4224;
function put(offset, data) { mem().set(data, base + offset); }
function get(offset, n) { return mem().slice(base + offset, base + offset + n); }

let failures = 0, checks = 0;
function expect(name, got, want) {
  checks++;
  if (got !== want) { failures++; console.error(`FAIL ${name}: got ${got} want ${want}`); }
}

const names = ['ok', 'bad_length', 'bad_version', 'bad_cmd', 'bad_tag', 'replay', 'jump'];
const key = bytes(v.key_hex), dev = bytes(v.device_id_hex);

for (const t of v.hmac_sha256_rfc4231) {
  const k = bytes(t.key_hex), m = bytes(t.msg_hex);
  put(KEY, k); put(IN, m);
  x.t_hmac(base + KEY, k.length, base + IN, m.length, base + OUT);
  expect('rfc4231 ' + t.key_hex.slice(0, 8), hex(get(OUT, 32)), t.mac_hex);
}
put(KEY, key); put(DEV, dev);

for (const c of v.commands) {
  const f = bytes(c.frame_hex);
  put(IN, f);
  const r = x.t_parse(base + IN, f.length, base + KEY, key.length, base + DEV, (c.counter - 1) >>> 0, base + OUT);
  const out = get(OUT, 8);
  expect('command ' + c.name + ' result', names[r], 'ok');
  expect('command ' + c.name + ' cmd', out[1], c.cmd);
  expect('command ' + c.name + ' counter', (((out[2] << 24) | (out[3] << 16) | (out[4] << 8) | out[5]) >>> 0), c.counter);
  expect('command ' + c.name + ' args', hex(out.slice(6, 6 + c.args_hex.length / 2)), c.args_hex);
}

for (const p of v.parse_cases) {
  const f = bytes(p.frame_hex);
  put(IN, f.length ? f : new Uint8Array(1));
  const r = x.t_parse(base + IN, f.length, base + KEY, key.length, base + DEV, p.stored_counter >>> 0, base + OUT);
  expect('parse ' + p.name, names[r], p.expect);
}

for (const c of (v.led_cases || [])) {
  const b = x.t_led(c.lo, c.hi);
  expect('led ' + c.lo + '/' + c.hi, [b & 15, b >> 4].join(','), [c.state, c.raw4].join(','));
}
for (const r of v.responses) {
  x.t_response(base + KEY, key.length, base + DEV, r.status, r.counter >>> 0, r.laptop, r.servo, base + OUT);
  expect('response ' + r.name, hex(get(OUT, 24)), r.frame_hex);
}

expect('press 99', x.t_press_ok(99), 0);
expect('press 100', x.t_press_ok(100), 1);
expect('press max', x.t_press_ok(v.constants.max_press_ms), 1);
expect('press max+1', x.t_press_ok(v.constants.max_press_ms + 1), 0);
expect('press 65535', x.t_press_ok(65535), 0);

console.log(`${checks} checks, ${failures} failures`);
process.exit(failures ? 1 : 0);
