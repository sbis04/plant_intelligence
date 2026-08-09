# Project plan

**Contest:** Invent the Future with Arduino UNO Q and App Lab (Hackster.io)
**Category:** Home Automation — Adaptive Climate Control
**Deadline:** August 30, 2026 · submit August 29

## Current state (Aug 9)

- [x] UNO Q booted, App Lab running, board named `PlantIntelligence`
- [x] Bridge RPC validated end-to-end ("Blink LED with UI")
- [x] Hub app written: firmware, decision engine, storage, API, dashboard
- [ ] Hardware cutover: relays + DHT11 rewired from the ESP32 to the UNO Q
- [ ] Soil probe: order, coat, seal, install, calibrate, enable
- [ ] iOS companion app
- [ ] Hackster writeup + demo video

## Decisions on record

- **Single board.** The ESP32 is retired from the build; the UNO Q's STM32
  takes over its real-time duties directly. The old controller stays flashed
  and shelf-ready as a rollback (photograph its wiring before disassembly).
- **Local-first.** No cloud dependency: SQLite + local API + dashboard.
  Cloud sync returns later through `hub/python/cloud.py`; stored document
  shapes already match the old Firestore schema so nothing needs redesigning.
- **Dynamic cadence, not fixed times.** The engine predicts the next
  watering (interval × weather × soil) instead of hard-coding 07:00/17:00.
  Neutral weather reproduces the old rhythm; hot, cool, and rainy days bend it.
- **Failsafe before cutover.** The MCU dead-man's switch must be proven
  (kill the Python process, watch water still arrive) before the UNO Q
  becomes the only thing watering the garden.
- One soil probe for now, placed in a *typical* pot; code is N-probe-ready.

## Remaining schedule

| Dates | Work | Gate |
|---|---|---|
| Aug 9–11 | Deploy hub app; bench-test relays + DHT11 on the UNO Q; verify failsafe by killing Python | Relays click, telemetry flows, failsafe fires |
| Aug 12–15 | Physical cutover; run the garden on the new system in parallel-watch mode; probe arrives: coat, seal, install | A full scheduled watering executes end-to-end |
| Aug 16–20 | Calibrate probe, enable soil in config; tune cadence factors against real days; iOS app skeleton against the local API | A rain-skip or hot-day adjustment observed in the wild |
| Aug 21–26 | iOS app usable; polish dashboard; 48 h unattended soak | Phone demo with no laptop attached |
| Aug 27–29 | Writeup, wiring diagram, BOM, demo video; **submit Aug 29** | Submitted |

## Writeup checklist (one section per judged criterion)

- Dual-brain: what runs on the STM32 vs the MPU, and why the split is real
- App Lab: Bricks used (web_ui, weather_forecast, dbstorage_tsstore) and
  the sketch+Python single-app workflow
- AI/intelligence: the predictive cadence engine; every decision explains
  itself; anomaly detection as the roadmap item
- Sustainability: measured litres saved from skipped/shortened cycles
- UX: dashboard + iOS app; one-tap override; "why" surfaced everywhere
- Scalability: N-probe config, spare relay channel, retrofit story
