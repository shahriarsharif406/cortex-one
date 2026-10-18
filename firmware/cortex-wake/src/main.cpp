// Cortex Wake: ESP32 firmware. BLE server + HMAC-authenticated commands + servo that presses a
// laptop power button. See docs/cortex-wake/PROTOCOL.md for the contract.
//
// !!! NOT COMPILED, NOT FLASHED, NOT TESTED ON HARDWARE. The authentication code it relies on
// (include/cw_auth.h) is tested against shared vectors on a PC (WebAssembly), the rest is
// written carefully but unverified. Read NEEDS_ME.md / BUILD_GUIDE_BN.md before the first run,
// and do the first test with the servo NOT yet glued to the laptop.
#include <Arduino.h>
#include <ESP32Servo.h>
#include <NimBLEDevice.h>
#include <Preferences.h>

#include "cw_auth.h"
#include "secrets.h"  // copy include/secrets.example.h -> include/secrets.h and fill it in

// ----------------------------------------------------------------------- pins / limits
static const int PIN_SERVO = 18;        // servo signal. Power the servo from the 5 V power bank, NOT from the ESP32.
static const int PIN_LED = 2;           // on-board LED
static const int PIN_CAL_BUTTON = 0;    // BOOT button: opens a 60 s calibration window
static const int PIN_SENSE = 34;        // optional: laptop USB 5 V through a divider (input only pin)
static const int PIN_LIGHT = 35;        // optional: photoresistor/phototransistor divider aimed at the power LED (ADC1)
static const uint32_t LIGHT_WINDOW_MS = 3000;   // one classification window
static const uint32_t LIGHT_SAMPLE_MS = 40;

static const uint32_t PRESS_WATCHDOG_MS = cw::kMaxPressMs + 500;   // servo is never held longer
static const uint32_t MIN_PRESS_GAP_MS = 5000;
static const uint32_t CAL_WINDOW_MS = 60000;
static const uint32_t SERVO_DETACH_AFTER_MS = 800;
static const int DEFAULT_REST = 90, DEFAULT_PRESS = 70;
static const int MIN_ANGLE = 10, MAX_ANGLE = 170, MIN_SPREAD = 5, MAX_SPREAD = 80;

static const char* SERVICE_UUID = "6e5c0001-8a0b-4c52-9f3e-c0de7a1c0f01";  // secret-scan:allow public BLE UUID
static const char* CMD_UUID = "6e5c0002-8a0b-4c52-9f3e-c0de7a1c0f01";  // secret-scan:allow public BLE UUID
static const char* ANS_UUID = "6e5c0003-8a0b-4c52-9f3e-c0de7a1c0f01";  // secret-scan:allow public BLE UUID

// ------------------------------------------------------------------------------ state
static Preferences prefs;
static Servo servo;
static NimBLECharacteristic* answerChar = nullptr;

static uint32_t storedCounter = 0;
static int angleRest = DEFAULT_REST, anglePress = DEFAULT_PRESS;
static int currentAngle = DEFAULT_REST;
static bool servoAttached = false;
static uint32_t lastServoMove = 0, lastPressEnd = 0, pressStarted = 0, calOpenUntil = 0;
static bool pressing = false;
static uint32_t pressHoldMs = 0;

// one received frame waits here until loop() handles it (BLE callbacks must stay short)
static uint8_t pending[40];
static size_t pendingLen = 0;
static volatile bool havePending = false;

// ----------------------------------------------------------------------------- servo
static void servoAttach() {
  if (!servoAttached) {
    servo.attach(PIN_SERVO, 500, 2400);
    servoAttached = true;
  }
}

// Soft start: move a couple of degrees at a time, never jump.
static void servoMoveTo(int target) {
  servoAttach();
  while (currentAngle != target) {
    currentAngle += (target > currentAngle) ? 1 : -1;
    servo.write(currentAngle);
    delay(12);
  }
  lastServoMove = millis();
}

static void servoRest() {
  servoMoveTo(angleRest);
  pressing = false;
}

// -------------------------------------------------------------------------- sensing
#ifdef LIGHT_SENSOR_FITTED
// Power-LED sensing: steady lit = ON, blinking = sleep, dark = OFF (classification lives in cw_auth.h,
// shared with the test vectors). The result is the previous complete window.
static uint8_t lightResult = 2;           // unknown until the first window is complete
static int winLo = 4095, winHi = 0;
static uint32_t winStart = 0, lastSample = 0;
static void lightTick() {
  uint32_t now = millis();
  if (now - lastSample < LIGHT_SAMPLE_MS) return;
  lastSample = now;
  int v = analogRead(PIN_LIGHT);
  if (v < winLo) winLo = v;
  if (v > winHi) winHi = v;
  if (now - winStart >= LIGHT_WINDOW_MS) {
    lightResult = cw::classify_led(winLo, winHi);
    winLo = 4095; winHi = 0; winStart = now;
  }
}
#endif

static uint8_t laptopState() {
#ifdef LIGHT_SENSOR_FITTED
  return lightResult;
#endif
  // Without a sensor wired the pin floats: we cannot tell, so report "unknown" unless it was
  // enabled in config.h-like fashion. Here: sensor present only if SENSOR_FITTED is defined.
#ifdef SENSOR_FITTED
  static uint32_t stableSince = 0;
  static int last = -1;
  int v = digitalRead(PIN_SENSE);
  if (v != last) { last = v; stableSince = millis(); }
  if (millis() - stableSince < 1000) return 2;  // debounce: not stable yet
  return v == HIGH ? 1 : 0;
#else
  return 2;
#endif
}

// ----------------------------------------------------------------------------- answers
static void sendAnswer(uint8_t status, uint32_t counter) {
  uint8_t out[8 + cw::kTagLen];
  cw::build_response(CW_KEY, sizeof(CW_KEY), CW_DEVICE_ID, status, counter, laptopState(),
                     pressing ? 1 : (millis() < calOpenUntil ? 2 : 0), out);
  if (answerChar) {
    answerChar->setValue(out, sizeof(out));
    answerChar->notify();
  }
}

// -------------------------------------------------------------------------- commands
static void handleFrame(const uint8_t* frame, size_t len) {
  cw::Parsed p = cw::parse_command(frame, len, CW_KEY, sizeof(CW_KEY), CW_DEVICE_ID, storedCounter);
  if (p.result != cw::OK) return;  // ignore silently: no reply, no change

  // 4. persist the counter BEFORE acting, so a reset can never allow a replay
  if (prefs.putUInt("ctr", p.counter) == 0) return;   // not saved: do NOT act (a reset would reopen a replay)
  storedCounter = p.counter;

  switch (p.cmd) {
    case cw::PING:
    case cw::STATE:
      sendAnswer(cw::ST_OK, p.counter);
      break;

    case cw::PRESS: {
      uint16_t ms = (uint16_t(p.args[0]) << 8) | p.args[1];
      if (!cw::press_ms_ok(ms)) { sendAnswer(cw::ST_BAD_ARGS, p.counter); break; }
      if (pressing) { sendAnswer(cw::ST_BUSY, p.counter); break; }
      if (lastPressEnd != 0 && millis() - lastPressEnd < MIN_PRESS_GAP_MS) {
        sendAnswer(cw::ST_RATE, p.counter);
        break;
      }
      pressing = true;
      pressStarted = millis();
      pressHoldMs = ms;
      sendAnswer(cw::ST_OK, p.counter);  // answer first: the press itself blocks for ~1 s
      servoMoveTo(anglePress);
      uint32_t held = millis() - pressStarted;
      if (held < pressHoldMs) delay(pressHoldMs - held);
      servoRest();
      lastPressEnd = millis();
      break;
    }

    case cw::CALIBRATE: {
      if (millis() >= calOpenUntil) { sendAnswer(cw::ST_CAL_LOCKED, p.counter); break; }
      int rest = p.args[0], press = p.args[1];
      int spread = rest > press ? rest - press : press - rest;
      if (rest < MIN_ANGLE || rest > MAX_ANGLE || press < MIN_ANGLE || press > MAX_ANGLE ||
          spread < MIN_SPREAD || spread > MAX_SPREAD) {
        sendAnswer(cw::ST_BAD_ARGS, p.counter);
        break;
      }
      angleRest = rest;
      anglePress = press;
      prefs.putInt("rest", rest);
      prefs.putInt("press", press);
      sendAnswer(cw::ST_OK, p.counter);
      servoMoveTo(anglePress);   // let the owner SEE the new press position
      delay(700);
      servoRest();
      break;
    }
    default:
      break;
  }
}

// ----------------------------------------------------------------------------- BLE
class CmdCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    std::string v = c->getValue();
    if (v.size() > sizeof(pending) || havePending) return;  // too long, or still busy: drop
    memcpy(pending, v.data(), v.size());
    pendingLen = v.size();
    havePending = true;
  }
};

class ServerCallbacks : public NimBLEServerCallbacks {
  void onDisconnect(NimBLEServer*) override { NimBLEDevice::startAdvertising(); }
};

static void startBle() {
  char name[24];
  snprintf(name, sizeof(name), "CortexWake-%02X%02X", CW_DEVICE_ID[0], CW_DEVICE_ID[1]);
  NimBLEDevice::init(name);
  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  NimBLEService* svc = server->createService(SERVICE_UUID);
  NimBLECharacteristic* cmd = svc->createCharacteristic(CMD_UUID, NIMBLE_PROPERTY::WRITE);
  cmd->setCallbacks(new CmdCallbacks());
  answerChar = svc->createCharacteristic(ANS_UUID, NIMBLE_PROPERTY::NOTIFY);
  svc->start();
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->start();
}

// ------------------------------------------------------------------------------ main
static void updateLed() {
  if (millis() < calOpenUntil) {
    digitalWrite(PIN_LED, (millis() / 250) % 2);  // blinking = calibration window open
  } else {
    digitalWrite(PIN_LED, pressing ? HIGH : LOW);
  }
}

void setup() {
  pinMode(PIN_LED, OUTPUT);
  pinMode(PIN_CAL_BUTTON, INPUT_PULLUP);
#ifdef SENSOR_FITTED
  pinMode(PIN_SENSE, INPUT);
#endif
#ifdef LIGHT_SENSOR_FITTED
  pinMode(PIN_LIGHT, INPUT);
  winStart = millis();
#endif
  prefs.begin("cortexwake", false);
  storedCounter = prefs.getUInt("ctr", 0);
  angleRest = prefs.getInt("rest", DEFAULT_REST);
  anglePress = prefs.getInt("press", DEFAULT_PRESS);
  // stored values must still be inside the allowed range, whatever is in flash
  if (angleRest < MIN_ANGLE || angleRest > MAX_ANGLE) angleRest = DEFAULT_REST;
  if (anglePress < MIN_ANGLE || anglePress > MAX_ANGLE) anglePress = DEFAULT_PRESS;
  currentAngle = angleRest;
  servoAttach();
  servo.write(angleRest);  // the servo starts at rest
  lastServoMove = millis();
  startBle();
}

void loop() {
#ifdef LIGHT_SENSOR_FITTED
  lightTick();
#endif
  if (havePending) {
    uint8_t copy[40];
    size_t n = pendingLen;
    memcpy(copy, pending, n);
    havePending = false;
    handleFrame(copy, n);
  }
  // physical BOOT button opens a 60 s calibration window
  if (digitalRead(PIN_CAL_BUTTON) == LOW) calOpenUntil = millis() + CAL_WINDOW_MS;
  // watchdog: whatever happened, the servo goes back to rest
  if (pressing && millis() - pressStarted > PRESS_WATCHDOG_MS) servoRest();
  // let the servo relax a moment after it reached rest (no buzzing, less heat)
  if (!pressing && servoAttached && millis() - lastServoMove > SERVO_DETACH_AFTER_MS) {
    servo.detach();
    servoAttached = false;
  }
  updateLed();
  delay(5);
}
