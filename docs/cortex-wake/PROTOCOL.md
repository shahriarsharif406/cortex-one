# Cortex Wake: protocol

Cortex Wake is a small robot that presses the laptop's power button. An ESP32 drives a servo and
talks Bluetooth Low Energy (BLE). A "gateway" Android phone (the Cortex One app in gateway mode,
with a SIM) is its only client. This file is the contract between the phone, the firmware and the
tests. **Status: designed and unit-tested in software; the hardware has never been built or run.**

```
 owner's phone ──SMS "ON 123456"──▶  gateway phone ──BLE, signed frame──▶  ESP32 ──PWM──▶ servo ─▶ power button
 owner's phone ──HTTP over Tailscale (token)──▶  (same gateway phone)
```

## 1. What it must resist

| Threat | Defence |
|---|---|
| Someone nearby sends BLE frames | Every frame carries a 16-byte HMAC tag. Wrong tag = ignored, no reply, no state change. |
| Someone records a good frame and replays it | A strictly increasing 32-bit counter, saved in flash **before** the servo moves. A frame with a counter not above the stored one is ignored. |
| A stolen key | Keys are 32 random bytes, copied by hand into the firmware and the phone's secure storage. Replace both to revoke. Calibration additionally needs a physical button (below). |
| A bug or attack asks for a long press | The press time is capped in firmware (100..1500 ms). Longer = refused, not clamped. The servo also returns to rest by itself. |
| A fake answer to the phone | Answers are signed too (different message prefix, so a command can never pass as an answer). |
| Pressing a running laptop | The gateway phone checks the state sensor and refuses unless the sender typed `FORCE` (see section 7). |

**Not defended:** a frame that an attacker blocks and delivers later is still accepted once (its
counter is still fresh). Radio jamming stops the robot. Someone with physical access can press the
button themselves. BLE link-layer encryption is not relied on.

## 2. BLE GATT

Advertised name: `CortexWake-XXXX` (XXXX = first 2 bytes of the device id, hex).

| Item | UUID | Properties |
|---|---|---|
| Service | `6e5c0001-8a0b-4c52-9f3e-c0de7a1c0f01` | |
| Command characteristic | `6e5c0002-8a0b-4c52-9f3e-c0de7a1c0f01` | write (with response) |
| Answer characteristic | `6e5c0003-8a0b-4c52-9f3e-c0de7a1c0f01` | notify |

One command is in flight at a time. The phone writes a command frame and waits (6 s) for one
notification.

## 3. Keys and ids

* `key`: 32 random bytes (64 hex characters). Created once by the app ("show the key once"), typed
  into `firmware/cortex-wake/include/secrets.h`, and kept in the phone's Android-Keystore-backed
  storage. Never logged, never sent by SMS.
* `device_id`: 8 random bytes (16 hex characters), same way. It is part of every MAC (so a frame for
  one robot is useless for another) but is not sent on the air.

## 4. Command frame (phone → ESP32)

Big-endian everywhere.

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | version = `0x01` |
| 1 | 1 | command |
| 2 | 4 | counter (uint32) |
| 6 | n | arguments (n fixed per command) |
| 6+n | 16 | tag = first 16 bytes of `HMAC-SHA256(key, device_id ‖ counter(4) ‖ command(1) ‖ arguments)` |

| Command | Code | Arguments | Meaning |
|---|---:|---|---|
| PRESS | 1 | `ms` uint16 | hold the button for `ms` milliseconds (100..1500), then release |
| STATE? | 2 | none | report laptop sensor and servo state |
| CALIBRATE | 3 | `angle_rest` u8, `angle_press` u8 | store the two servo angles (see section 6) |
| PING | 4 | none | alive check |

Frame sizes: PRESS 24 bytes, STATE? 22, CALIBRATE 24, PING 22.

### What the firmware does with a frame, in this order

1. Length, version, command known and length matches the command → otherwise ignore.
2. **Verify the tag** (constant time). Bad tag → ignore. (The tag is checked *before* the counter so
   a forger learns nothing about the stored counter.)
3. Counter must be `> stored` and `<= stored + 100000` → otherwise ignore.
4. **Write the new counter to flash.** Only then act.
5. Check the arguments and state, act, and send a signed answer.

"Ignore" means: no reply, no counter change, no movement.

## 5. Answer frame (ESP32 → phone)

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | version = `0x01` |
| 1 | 1 | status |
| 2 | 4 | counter of the command being answered |
| 6 | 1 | laptop: 0 looks OFF, 1 looks ON, 2 unknown (no sensor) |
| 7 | 1 | servo: 0 rest, 1 pressing, 2 calibrating |
| 8 | 16 | tag = first 16 bytes of `HMAC-SHA256(key, device_id ‖ 'R' ‖ version ‖ status ‖ counter(4) ‖ laptop ‖ servo)` |

Status: 0 OK, 1 BAD_ARGS (for example a press time out of range: nothing moved), 2 BUSY, 3 CAL_LOCKED
(calibration button not held), 4 RATE (a press came less than 5 s after the last one).

## 6. Servo rules (hardware safety)

* On boot the servo is attached gently and moved to `angle_rest` (soft start: a few degrees at a
  time). A press moves the same way. The servo is detached again a moment after it reaches rest.
* The servo is never held at `angle_press` longer than 1500 ms plus a 500 ms margin: a software check in
  the main loop sends it back to rest. (It does not help if the whole program hangs inside a `delay()`;
  the chip's own task watchdog would then reset the board.) A stored counter of 0xFFFFFFFF locks the
  robot for good: re-flash it with a new key.
* Defaults: rest 90°, press 70°. They are stored in flash after calibration.
* **CALIBRATE is accepted only within 60 s after the physical BOOT button was pressed** (the LED
  blinks while calibration is open). Both angles must be between 10° and 170° and differ by at
  least 5° and at most 80°. A leaked key therefore cannot make the servo push the laptop apart.
  While calibrating, the app moves the arm with CALIBRATE and the owner watches it.

## 7. State sensor and the safety rule

Optional: one GPIO (default 34) reads the laptop's USB 5 V through a resistor divider (wiring in
`BUILD_GUIDE_BN.md`). HIGH = the laptop looks ON. **Many laptops keep USB ports powered in sleep or
even when off ("USB charging"), so "ON" can be wrong.** That is why the rule is conservative:

| Sensor | `ON <code>` (wake) | `PRESS <code>` |
|---|---|---|
| OFF | press | press |
| ON | refuse ("already ON"), even with FORCE | refuse unless `FORCE` |
| unknown | refuse unless `FORCE` | refuse unless `FORCE` |

Pressing the power button of a running laptop puts it to sleep or shuts it down, depending on the
Windows setting "power button action". `scripts/set-power-plan.ps1 -PowerButton Sleep` (default)
sets it to Sleep; `Nothing` makes a press on a running laptop harmless.

## 8. Counter handling on the phone

* The phone stores the counter in secure storage and writes the new value **before** sending.
* After every answer it never falls behind the device's counter.
* If a *read-only* command (STATE?, PING) gets no answer, the phone jumps the counter ahead by 1000
  once and sends it again (the phone's counter may be behind after a reinstall).
* **PRESS is never retried.** If no answer comes back the robot may or may not have pressed; the
  phone says so and does a STATE? query to re-sync the counter.

## 9. How the owner reaches the gateway phone

* **SMS** (works with no internet, only mobile signal). Format (case-insensitive, Bangla digits ok):
  `ON 123456`, `PRESS 123456`, `STATUS`, and `... FORCE` after the code. The code is a 6-digit TOTP
  (RFC 6238, SHA-1, 30 s, ±1 step) from a **wake secret** that differs from the laptop agent's SMS
  secret. A code is accepted once. Unknown senders get no reply at all. Three wrong codes lock the
  gateway for 15 minutes. `STATUS` needs no code but is answered only for numbers on the allowlist.
* **HTTP over Tailscale.** The gateway app listens on its own Tailscale address (never 0.0.0.0):
  `GET /status`, `POST /press {"force": true|false}`, both with `Authorization: Bearer <token>`.
  Five wrong tokens from one address lock it for 10 minutes. This is what the app's "Wake" button
  uses when the Cortex Wake method is chosen. It needs the gateway phone to have internet (its SIM
  data) and Tailscale running.

## 10. Test vectors

`docs/cortex-wake/test_vectors.json` is generated by `reference.py` (Python, the reference). The Dart
code (`mobile/lib/wake/cw_protocol.dart`) and the firmware header (`firmware/cortex-wake/include/cw_auth.h`)
must reproduce it byte for byte, including the negative cases (bad tag, replay, too big a jump,
wrong length, wrong version, other device id, other key) and the RFC 4231 HMAC test cases.

```
python docs/cortex-wake/reference.py --check
flutter test test/wake_test.dart                 (in mobile/)
python firmware/cortex-wake/test/run_cpp_vectors.py
```

The C++ check compiles `cw_auth.h` with clang to WebAssembly and runs it in Node. It does **not**
compile for the ESP32 (Xtensa); the sketch in `firmware/cortex-wake/` has never been compiled.
