/*
 * Plant Intelligence — MCU firmware (STM32U585, Arduino Core on Zephyr)
 *
 * The microcontroller owns everything real-time and safety-critical:
 *   - relay control (fan / solenoid valve / pump) with safe sequencing
 *   - DHT11 temperature & humidity
 *   - capacitive soil moisture on A0 (power-switched rail on D9)
 *   - fan thermostat with hysteresis (works even if Linux is down)
 *   - dead-man failsafe: if the Linux side goes silent, water on a
 *     conservative timer so the garden never depends on the MPU being up
 *
 * The Linux side (python/) decides WHEN and HOW LONG to water.
 * This side decides WHETHER IT IS SAFE TO and does the actual switching.
 *
 * RPC surface (Bridge):
 *   provided (callable from Python):
 *     start_watering(int duration_ms)  — begin a watering cycle (clamped to hard cap)
 *     stop_watering()                  — graceful stop (pump first, then valve)
 *     ping()                           — heartbeat; feeds the dead-man timer
 *     set_failsafe(int hours)          — silence threshold before autonomous watering
 *   notified (pushed to Python):
 *     on_temperature(float °C)   every TELEMETRY_MS
 *     on_humidity(float %)       every TELEMETRY_MS
 *     on_soil(int raw ADC)       every TELEMETRY_MS (-1 until first valid read)
 *     on_state(int)              watering state machine state
 *     on_seconds_left(int)       remaining watering time, 0 when idle
 *     on_event(int)              event codes below
 *
 * Event codes:
 *   1 watering started (commanded)     5 watering rejected: too soon after last
 *   2 watering ended (normal)          6 failsafe watering started
 *   3 watering stopped (commanded)     7 fan on
 *   4 watering rejected: already active 8 fan off
 *   9 DHT read failing (persistent)  10 DHT recovered
 */

#include "Arduino_RouterBridge.h"
#include <Arduino_LED_Matrix.h>

// ---------------------------------------------------------------- pins
// 4-channel relay module, ACTIVE LOW (LOW = energized), as on the old rig.
const int PIN_RELAY_FAN   = 4;  // IN1
const int PIN_RELAY_VALVE = 5;  // IN2 — solenoid valve
const int PIN_RELAY_PUMP  = 6;  // IN3 — 12 V diaphragm pump
// IN4 spare
const int PIN_DHT         = 8;  // DHT11 data
const int PIN_SOIL        = A0; // capacitive probe, MUST be powered from 3.3 V
const int PIN_SOIL_RAIL   = 9;  // MOSFET gate switching the sensor supply rail

const bool RELAY_ON  = LOW;
const bool RELAY_OFF = HIGH;

// ---------------------------------------------------------------- tuning
// Pump sequencing (protects the 12 V supply from inrush, limits water hammer)
const unsigned long VALVE_LEAD_MS  = 750;   // valve open before pump start
const unsigned long PUMP_TRAIL_MS  = 1000;  // pump off before valve close

// Hard safety limits, enforced HERE regardless of what Linux asks for
const unsigned long MAX_WATERING_MS      = 10UL * 60UL * 1000UL; // 10 min cap
const unsigned long MIN_GAP_AFTER_END_MS = 60UL * 1000UL;        // 1 min between cycles

// Dead-man failsafe: if Linux is silent this long, water autonomously.
unsigned long failsafeSilenceMs          = 14UL * 60UL * 60UL * 1000UL; // 14 h
const unsigned long FAILSAFE_DURATION_MS = 5UL * 60UL * 1000UL;  // 5 min (old fixed schedule)
const unsigned long FAILSAFE_MIN_GAP_MS  = 10UL * 60UL * 60UL * 1000UL; // 10 h between failsafe runs

// Fan thermostat (from the previous system's tuning)
const float FAN_ON_TEMP  = 38.0;
const float FAN_OFF_TEMP = 36.5;

const unsigned long TELEMETRY_MS   = 5000;
const unsigned long DHT_PERIOD_MS  = 10000; // DHT11 max ~0.5 Hz; read every 10 s
const unsigned long SOIL_RAIL_WARMUP_MS = 150; // capacitive oscillator settle time

// ---------------------------------------------------------------- state
enum WaterState { W_IDLE = 0, W_VALVE_OPENING = 1, W_PUMPING = 2, W_CLOSING = 3 };

WaterState waterState = W_IDLE;
unsigned long stateEnteredMs   = 0;
unsigned long wateringEndMs    = 0;   // when pumping should stop
unsigned long lastWateringEnd  = 0;   // millis at last completed cycle (0 = never)
bool everWatered = false;

// Written from the Bridge RPC context, read from loop() — hence volatile,
// and all comparisons against it use signed differences (see failsafe block).
volatile unsigned long lastPingMs = 0;
unsigned long lastFailsafeRunMs = 0;
bool everPinged = false, everFailsafed = false;

float lastTemp = NAN, lastHum = NAN;
int   dhtFailStreak = 0;
bool  dhtFailing = false;   // episodic reporting: one event per failure episode
int   lastSoilRaw = -1;
bool  fanOn = false;

unsigned long lastTelemetryMs = 0, lastDhtMs = 0;
bool soilRailOn = false;
unsigned long soilRailOnMs = 0;

// ---------------------------------------------------------------- LED matrix
// The 8x13 grid is the board's face: a sprout grows at boot, rain falls
// while watering, a wave rolls when idle, sparse drops mark a rain hold
// and sparkles show the assistant thinking. All procedural — no frame
// tables — ticked non-blocking from loop(). The hub picks the ambient
// mode over the Bridge; watering and boot always win.
enum LedMode { LED_IDLE = 0, LED_RAIN_HOLD = 1, LED_THINKING = 2 };
volatile int ledMode = LED_IDLE;
Arduino_LED_Matrix matrix;
uint8_t fb[104];                       // row-major 8x13 framebuffer, 0..7
unsigned long lastAnimMs = 0;
unsigned long bootAnimStart = 0;

inline void px(int r, int c, uint8_t v) {
  if (r >= 0 && r < 8 && c >= 0 && c < 13) fb[r * 13 + c] = v;
}

void animBoot(unsigned long now) {     // sprout grows from the soil
  unsigned long t = now - bootAnimStart;
  memset(fb, 0, sizeof(fb));
  for (int c = 0; c < 13; c++) px(7, c, 1);          // soil line
  int h = t / 220;                                    // stem height over time
  for (int r = 6; r >= 7 - h && r >= 2; r--) px(r, 6, 6);
  if (h >= 3) { px(4, 5, 4); px(4, 7, 4); }           // first leaves
  if (h >= 4) { px(3, 4, 3); px(3, 8, 3); px(2, 6, 7); } // crown
  if (t > 2600) {                                     // fade out, hand to idle
    uint8_t fade = min(7UL, (t - 2600) / 120);
    for (int i = 0; i < 104; i++) fb[i] = fb[i] > fade ? fb[i] - fade : 0;
  }
}

void animRain(unsigned long) {         // drops falling while watering
  for (int r = 7; r > 0; r--)                          // shift + fade down
    for (int c = 0; c < 13; c++) {
      uint8_t v = fb[(r - 1) * 13 + c];
      fb[r * 13 + c] = v > 2 ? v - 2 : 0;
    }
  for (int c = 0; c < 13; c++)                         // spawn new drops
    fb[c] = (random(100) < 14) ? 7 : 0;
}

void animIdle(unsigned long) {         // dark — LEDs live longer off
  memset(fb, 0, sizeof(fb));
}

void animRainHold(unsigned long now) { // rain expected: a brief reminder —
  if ((now / 1000) % 60 < 4) {         // drops for ~4 s once a minute
    for (int r = 7; r > 0; r--)
      for (int c = 0; c < 13; c++) {
        uint8_t v = fb[(r - 1) * 13 + c];
        fb[r * 13 + c] = v > 1 ? v - 1 : 0;
      }
    for (int c = 0; c < 13; c++)
      fb[c] = (random(100) < 8) ? 5 : 0;
  } else {
    memset(fb, 0, sizeof(fb));
  }
}

void animThinking(unsigned long now) { // a soft pulse sweeping to and fro
  memset(fb, 0, sizeof(fb));
  int phase = (now / 70) % 24;                         // ~1.7 s per round trip
  int c = phase < 12 ? phase : 24 - phase;             // bounce 0..12..0
  for (int dc = -2; dc <= 2; dc++) {
    int cc = c + dc;
    if (cc < 0 || cc > 12) continue;
    uint8_t v = dc == 0 ? 6 : (abs(dc) == 1 ? 3 : 1);  // bright core, soft tail
    for (int r = 2; r <= 5; r++) px(r, cc, v);
  }
}

void serviceMatrix(unsigned long now) {
  if (now - lastAnimMs < 90) return;
  lastAnimMs = now;
  // "Growing up": loop the sprout until the hub's first ping, so the whole
  // initialization is visibly alive. Capped at 5 minutes so a hub that
  // never comes up doesn't burn the LEDs; the running cycle finishes
  // before handing over, which reads as "ready".
  bool waitingForHub = !everPinged && now < 300000UL;
  if (waitingForHub && (bootAnimStart == 0 || now - bootAnimStart >= 3600)) {
    bootAnimStart = now ? now : 1;
  }
  bool booting = bootAnimStart && now - bootAnimStart < 3600;
  if (booting)                                    animBoot(now);
  else if (waterState == W_PUMPING ||
           waterState == W_VALVE_OPENING)         animRain(now);
  else if (ledMode == LED_THINKING)               animThinking(now);
  else if (ledMode == LED_RAIN_HOLD)              animRainHold(now);
  else                                            animIdle(now);
  matrix.draw(fb);
}

// ---------------------------------------------------------------- helpers
void notifyEvent(int code) { Bridge.notify("on_event", code); }

void setWaterState(WaterState s) {
  waterState = s;
  stateEnteredMs = millis();
  Bridge.notify("on_state", (int)s);
}

// Minimal DHT11 bit-bang read — no library dependency, so nothing to break
// on the Zephyr core. Returns true and fills temp/hum on success.
bool readDHT11(float &temp, float &hum) {
  uint8_t data[5] = {0};

  pinMode(PIN_DHT, OUTPUT);
  digitalWrite(PIN_DHT, LOW);
  delay(20);                       // >18 ms start signal
  digitalWrite(PIN_DHT, HIGH);
  delayMicroseconds(35);
  pinMode(PIN_DHT, INPUT);

  // Sensor response: ~80 µs low, ~80 µs high
  unsigned long t0 = micros();
  while (digitalRead(PIN_DHT) == HIGH) { if (micros() - t0 > 100) return false; }
  t0 = micros();
  while (digitalRead(PIN_DHT) == LOW)  { if (micros() - t0 > 100) return false; }
  t0 = micros();
  while (digitalRead(PIN_DHT) == HIGH) { if (micros() - t0 > 100) return false; }

  // 40 data bits: 50 µs low, then ~27 µs high = 0, ~70 µs high = 1
  for (int i = 0; i < 40; i++) {
    t0 = micros();
    while (digitalRead(PIN_DHT) == LOW)  { if (micros() - t0 > 80)  return false; }
    unsigned long hiStart = micros();
    while (digitalRead(PIN_DHT) == HIGH) { if (micros() - hiStart > 100) return false; }
    data[i / 8] <<= 1;
    if (micros() - hiStart > 45) data[i / 8] |= 1;
  }

  if ((uint8_t)(data[0] + data[1] + data[2] + data[3]) != data[4]) return false;
  hum  = data[0];         // DHT11: integer humidity
  temp = data[2];         // integer temperature; data[3] is decimal on some units
  if (data[3] < 10) temp += data[3] * 0.1;
  return true;
}

int readSoilMedian() {
  int v[5];
  for (int i = 0; i < 5; i++) { v[i] = analogRead(PIN_SOIL); delay(2); }
  // insertion sort, take middle
  for (int i = 1; i < 5; i++) {
    int k = v[i], j = i - 1;
    while (j >= 0 && v[j] > k) { v[j + 1] = v[j]; j--; }
    v[j + 1] = k;
  }
  return v[2];
}

// ---------------------------------------------------------------- watering
bool beginWatering(unsigned long durationMs, bool failsafe) {
  if (waterState != W_IDLE) { notifyEvent(4); return false; }
  if (everWatered && millis() - lastWateringEnd < MIN_GAP_AFTER_END_MS) {
    notifyEvent(5);
    return false;
  }
  if (durationMs > MAX_WATERING_MS) durationMs = MAX_WATERING_MS;
  if (durationMs < 1000) durationMs = 1000;

  digitalWrite(PIN_RELAY_VALVE, RELAY_ON);
  setWaterState(W_VALVE_OPENING);
  wateringEndMs = millis() + VALVE_LEAD_MS + durationMs;
  notifyEvent(failsafe ? 6 : 1);
  Monitor.print("Watering start, ms=");
  Monitor.println(durationMs);
  return true;
}

void finishToClosing(int eventCode) {
  digitalWrite(PIN_RELAY_PUMP, RELAY_OFF);
  setWaterState(W_CLOSING);
  notifyEvent(eventCode);
}

void serviceWatering() {
  unsigned long now = millis();
  switch (waterState) {
    case W_IDLE:
      break;
    case W_VALVE_OPENING:
      if (now - stateEnteredMs >= VALVE_LEAD_MS) {
        digitalWrite(PIN_RELAY_PUMP, RELAY_ON);
        setWaterState(W_PUMPING);
      }
      break;
    case W_PUMPING:
      if (now >= wateringEndMs) finishToClosing(2); // normal end
      break;
    case W_CLOSING:
      if (now - stateEnteredMs >= PUMP_TRAIL_MS) {
        digitalWrite(PIN_RELAY_VALVE, RELAY_OFF);
        lastWateringEnd = now;
        everWatered = true;
        setWaterState(W_IDLE);
      }
      break;
  }
}

// ---------------------------------------------------------------- RPC
void rpc_start_watering(int durationMs) { beginWatering((unsigned long)durationMs, false); }

void rpc_stop_watering() {
  if (waterState == W_VALVE_OPENING) {           // pump never started
    digitalWrite(PIN_RELAY_VALVE, RELAY_OFF);
    lastWateringEnd = millis();
    everWatered = true;
    setWaterState(W_IDLE);
    notifyEvent(3);
  } else if (waterState == W_PUMPING) {
    finishToClosing(3);
  }
}

// ------------------------------------------------------------- RGB LEDs
// Two MCU-owned status lights (active LOW). LED3 glows blue while water
// is actually flowing; LED4 shows red while the DHT is failing and blips
// green on every hub heartbeat — a glanceable "the link is alive".
unsigned long led4PulseUntil = 0;

void serviceRgb(unsigned long now) {
  bool watering = waterState == W_VALVE_OPENING ||
                  waterState == W_PUMPING ||
                  waterState == W_CLOSING;
  digitalWrite(LED3_B, watering ? LOW : HIGH);
  digitalWrite(LED4_R, dhtFailing ? LOW : HIGH);
  bool pulse = !dhtFailing && (long)(led4PulseUntil - now) > 0;
  digitalWrite(LED4_G, pulse ? LOW : HIGH);
}

void rpc_ping() {
  lastPingMs = millis();
  everPinged = true;
  led4PulseUntil = lastPingMs + 150;   // heartbeat blip
}

void rpc_set_led_mode(int mode) {
  if (mode >= LED_IDLE && mode <= LED_THINKING) ledMode = mode;
}

void rpc_set_failsafe(int hours) {
  if (hours >= 6 && hours <= 72)
    failsafeSilenceMs = (unsigned long)hours * 60UL * 60UL * 1000UL;
}

// ---------------------------------------------------------------- setup/loop
void setup() {
  pinMode(PIN_RELAY_FAN, OUTPUT);
  pinMode(PIN_RELAY_VALVE, OUTPUT);
  pinMode(PIN_RELAY_PUMP, OUTPUT);
  digitalWrite(PIN_RELAY_FAN, RELAY_OFF);
  digitalWrite(PIN_RELAY_VALVE, RELAY_OFF);
  digitalWrite(PIN_RELAY_PUMP, RELAY_OFF);

  pinMode(PIN_SOIL_RAIL, OUTPUT);

  // RGB status LEDs, active LOW — all off
  int rgb[] = {LED3_R, LED3_G, LED3_B, LED4_R, LED4_G, LED4_B};
  for (int p : rgb) { pinMode(p, OUTPUT); digitalWrite(p, HIGH); }
  digitalWrite(PIN_SOIL_RAIL, LOW);   // sensor rail off between reads

  Monitor.begin(115200);
  Bridge.begin();
  Bridge.provide("start_watering", rpc_start_watering);
  Bridge.provide("stop_watering",  rpc_stop_watering);
  Bridge.provide("ping",           rpc_ping);
  Bridge.provide("set_failsafe",   rpc_set_failsafe);
  Bridge.provide("set_led_mode",   rpc_set_led_mode);

  matrix.begin();
  matrix.setGrayscaleBits(3);
  matrix.clear();
  bootAnimStart = millis();
  if (bootAnimStart == 0) bootAnimStart = 1;   // 0 means "no boot anim"

  lastPingMs = millis(); // grace period from boot
  Monitor.println("Plant Intelligence MCU ready");
}

void loop() {
  unsigned long now = millis();

  serviceWatering();
  serviceMatrix(now);
  serviceRgb(now);

  // --- DHT11 + fan thermostat -------------------------------------------
  if (now - lastDhtMs >= DHT_PERIOD_MS) {
    lastDhtMs = now;
    float t, h;
    if (readDHT11(t, h)) {
      lastTemp = t; lastHum = h; dhtFailStreak = 0;
      if (dhtFailing) { dhtFailing = false; notifyEvent(10); }
      if (!fanOn && t > FAN_ON_TEMP) {
        digitalWrite(PIN_RELAY_FAN, RELAY_ON);  fanOn = true;  notifyEvent(7);
      } else if (fanOn && t < FAN_OFF_TEMP) {
        digitalWrite(PIN_RELAY_FAN, RELAY_OFF); fanOn = false; notifyEvent(8);
      }
    } else if (++dhtFailStreak >= 6 && !dhtFailing) {
      dhtFailing = true;                 // one event per failure episode;
      notifyEvent(9);                    // event 10 marks recovery
    }
  }

  // --- soil: two-phase read with switched rail ---------------------------
  if (!soilRailOn && now - lastTelemetryMs >= TELEMETRY_MS - SOIL_RAIL_WARMUP_MS) {
    digitalWrite(PIN_SOIL_RAIL, HIGH);          // energize, let oscillator settle
    soilRailOn = true;
    soilRailOnMs = now;
  }

  // --- telemetry ----------------------------------------------------------
  if (now - lastTelemetryMs >= TELEMETRY_MS) {
    lastTelemetryMs = now;
    if (soilRailOn && now - soilRailOnMs >= SOIL_RAIL_WARMUP_MS) {
      lastSoilRaw = readSoilMedian();
    }
    digitalWrite(PIN_SOIL_RAIL, LOW);
    soilRailOn = false;

    if (!isnan(lastTemp)) Bridge.notify("on_temperature", lastTemp);
    if (!isnan(lastHum))  Bridge.notify("on_humidity",  lastHum);
    Bridge.notify("on_soil", lastSoilRaw);
    Bridge.notify("on_state", (int)waterState);
    int secsLeft = 0;
    if (waterState == W_VALVE_OPENING || waterState == W_PUMPING) {
      long d = (long)(wateringEndMs - now);
      secsLeft = d > 0 ? (int)(d / 1000) : 0;
    }
    Bridge.notify("on_seconds_left", secsLeft);
  }

  // --- dead-man failsafe --------------------------------------------------
  // If Linux has been silent past the threshold, water on a conservative
  // timer. Uses ping silence, not wall-clock: no RTC/NTP needed here.
  //
  // The silence math uses a SIGNED difference on purpose: a ping lands from
  // the Bridge RPC context and can stamp lastPingMs a few ms *after* this
  // iteration's `now` snapshot. Unsigned subtraction would underflow to
  // ~49 days of "silence" and fire the failsafe instantly (observed on the
  // bench: a failsafe watering 15 minutes after boot, mid-thunderstorm).
  long silenceMs = (long)(now - lastPingMs);
  unsigned long sinceLastFailsafe = everFailsafed ? now - lastFailsafeRunMs : FAILSAFE_MIN_GAP_MS;
  unsigned long sinceLastWaterEnd = everWatered   ? now - lastWateringEnd   : FAILSAFE_MIN_GAP_MS;
  if (silenceMs > 0 && (unsigned long)silenceMs >= failsafeSilenceMs &&
      waterState == W_IDLE &&
      sinceLastFailsafe >= FAILSAFE_MIN_GAP_MS &&
      sinceLastWaterEnd >= FAILSAFE_MIN_GAP_MS) {
    if (beginWatering(FAILSAFE_DURATION_MS, true)) {
      lastFailsafeRunMs = now;
      everFailsafed = true;
      lastPingMs = now; // rate-limit: re-arm the silence window
    }
  }
}
