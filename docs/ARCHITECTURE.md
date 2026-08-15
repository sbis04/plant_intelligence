# Architecture

## System overview

```
┌───────────────── Arduino UNO Q ─────────────────┐
│                                                  │
│  Qualcomm Dragonwing · Debian Linux              │
│  ┌────────────────────────────────────────────┐  │
│  │ main.py — scheduler loop (1 s tick)        │  │
│  │  decision.py   cadence + duration engine   │  │
│  │  weather.py    weather_forecast Brick +    │  │
│  │                Open-Meteo hourly numbers   │  │
│  │  store.py      SQLite (events, logs)       │  │
│  │  api.py        web_ui Brick: REST + WS     │  │
│  │  cloud.py      future cloud sync (no-op)   │  │
│  └───────────────────┬────────────────────────┘  │
│                      │ Bridge RPC                 │
│  ┌───────────────────┴────────────────────────┐  │
│  │ sketch.ino — STM32U585 (Zephyr)            │  │
│  │  relay sequencing · DHT11 · soil ADC       │  │
│  │  fan thermostat · dead-man failsafe        │  │
│  │  hard caps enforced in firmware            │  │
│  └────────────────────────────────────────────┘  │
└───────┬──────────────────────────────────────────┘
        │ relays (active-low)                LAN
   pump · valve · fan                 dashboard / iOS app
```

## Division of responsibility

The split follows one rule: **anything that must keep working when software
fails lives on the microcontroller; anything that benefits from data lives
on Linux.**

| Concern | Where | Why |
|---|---|---|
| Relay switching & sequencing | MCU | Timing-sensitive, safety-adjacent |
| Watering hard caps (10 min, min gap) | MCU | Must hold even against a buggy brain |
| Fan thermostat | MCU | Works with Linux down |
| Dead-man failsafe | MCU | The whole point is Linux being gone |
| Watering cadence & duration | Linux | Needs weather, history, soil trends |
| Storage, API, dashboard | Linux | Filesystem, network |

## RPC contract

Python → MCU (`Bridge.call`):

| Function | Args | Effect |
|---|---|---|
| `start_watering` | duration_ms | Begin cycle; firmware clamps and can reject |
| `stop_watering` | — | Graceful stop (pump first, valve after) |
| `ping` | — | Heartbeat; feeds the dead-man timer |
| `set_failsafe` | hours (6–72) | Silence threshold before autonomous watering |

MCU → Python (`Bridge.notify`):

| Event | Payload | Cadence |
|---|---|---|
| `on_temperature` / `on_humidity` | float | every 5 s |
| `on_soil` | int raw ADC (−1 = no probe) | every 5 s |
| `on_state` | 0 idle · 1 opening · 2 watering · 3 closing | on change + 5 s |
| `on_seconds_left` | int | every 5 s |
| `on_event` | code (see sketch header) | as they happen |

## The decision engine

`decision.py` is pure logic — no I/O — so the cadence math is unit-testable
off the board. Inputs: soil % (optional), a weather summary, the time of the
last completed watering, and the clock. Output: a `Plan`.

It runs in one of two modes, selected by whether the soil probe reports:

**Fixed (no probe).** Watering happens at fixed daily slots — 07:00 and
17:00 by default (`fixed_times`), the rhythm the old ESP32 system ran on.
A slot fires only if it hasn't already been served and wasn't missed by
more than `fixed_catchup_min` (90 min), so a hub that boots at noon doesn't
immediately water for a slot it slept through. The dose is flat — a plain
`base_duration_s` (5 min), exactly what the old system ran. Weather's only
say here is skipping a slot rain is already covering.

**Adaptive (probe calibrated).** Enabling `soil_enabled` switches this on by
itself — no second setting to remember.

- **Interval** starts at 12 h (the old twice-a-day rhythm) and is scaled by
  forecast: ×0.6 on very hot days, ×2 when rain is likely, ×1.3 when cool.
- **Duration** starts at 300 s and scales the opposite way.
- **Soil overrides the calendar**: wet soil postpones regardless of schedule;
  dry soil waters now (inside the allowed window) regardless of the interval.
- Watering only starts inside a local-time window (default 05:30–20:00).

The split is deliberate: extrapolating an interval from the forecast alone
is a guess dressed up as a decision. Once the probe can say the soil is
actually dry, the adaptive cadence has something real to stand on.

Either way every plan carries human-readable `reasons`, surfaced in the
dashboard and the API — the system can always explain itself.

## Failure model

| Failure | Behaviour |
|---|---|
| Python process dies | MCU waters 5 min every ~10 h after 14 h of silence |
| Wi-Fi/LAN down | Everything local continues; only remote clients lose access |
| Weather API unreachable | Engine runs on neutral cadence; last cache reused |
| Soil probe absent/miscalibrated | `soil_enabled` off → fixed 07:00/17:00 slots |
| MCU reset mid-watering | Relays initialize OFF; valve closes by default |
| Runaway command bug | Firmware cap: 10 min max, enforced below the RPC |

## Storage

SQLite at `~/.plant_intelligence/plant.db` (WAL mode):

- `water_history(water_started_at, water_ended_at, planned_duration_ms,
  trigger, manual_override, reason, synced)`
- `system_logs(timestamp, event_type, message, is_error, synced)`

Sensor samples additionally stream into the `dbstorage_tsstore` Brick
(`temperature_c`, `humidity_pct`, `soil_raw`, `soil_pct`).

Field names deliberately mirror the previous system's Firestore collections;
`synced` is the outbox flag for the future cloud sync (see `cloud.py`).

## Porting notes (from the ESP32 system)

Carried over: relay sequencing delays (750 ms / 1000 ms), fan hysteresis
(38.0 / 36.5 °C), 5-minute default dose, twice-a-day baseline rhythm,
active-low relay convention, event-log style.

Deliberately not ported: the Wi-Fi reconnect/watchdog stack, offline queue,
and exponential backoff — roughly a thousand lines that existed to work
around microcontroller constraints. On Debian, NetworkManager, systemd, and
the filesystem do those jobs.
