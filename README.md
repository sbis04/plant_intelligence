# Plant Intelligence

Adaptive irrigation for a rooftop garden, built on the Arduino UNO Q's
dual-brain architecture. The system predicts its own watering cadence from
live weather and soil feedback instead of running a fixed timer, keeps a
hardware-level failsafe so the plants never depend on software being up,
and serves a local dashboard and API to a companion mobile app.

## Repository layout

```
PlantIntelligence/
├── hub/            Arduino App Lab app — deploy this to the UNO Q
│   ├── app.yaml    App manifest (Bricks: web_ui, weather_forecast, dbstorage_tsstore)
│   ├── sketch/     STM32 firmware: relays, sensors, safety, failsafe
│   ├── python/     Linux side: decision engine, scheduler, storage, API
│   └── assets/     Built-in web dashboard
├── mobile/
│   └── ios/        Native iOS companion app (in progress)
└── docs/           Architecture and project plan
```

## How it works

**The STM32 (real-time)** owns the relays — pump, solenoid valve, fan — with
safe sequencing (valve leads the pump by 750 ms; the pump stops 1 s before
the valve closes), reads the DHT11 and the soil probe, runs the fan
thermostat, and enforces hard limits: a 10-minute watering cap and a
minimum gap between cycles, regardless of what it's asked to do.

**The Linux side (decisions)** fetches the weather, reads the soil, and
computes a *plan*: when the next watering should happen and how long it
should run. Without a calibrated soil probe it keeps to fixed daily slots
(07:00 and 17:00) for a flat 5 minutes, and the weather may only skip a
slot the rain is already covering — an interval extrapolated from the
forecast alone would be a guess dressed up as a decision. Once the probe is
calibrated the cadence goes adaptive on its own: hot days shorten the
interval and lengthen the dose, rain in the forecast postpones it, and dry
soil overrides the calendar entirely. Every plan carries the list of
reasons that produced it.

**The failsafe** is a dead-man's switch on the microcontroller. The Linux
side heartbeats every 30 s; if the MCU hears nothing for 14 hours it waters
for a conservative 5 minutes on its own and repeats every 10 hours until
the brain comes back. A hub failure costs intelligence, never the garden.

## Deploying

1. Open the `hub/` app in Arduino App Lab (connected to an UNO Q) and run it.
   App Lab flashes the sketch to the MCU and starts the Python side on Linux.
2. Location is detected automatically on first boot (IP geolocation —
   city-level, which matches forecast granularity). For a precise fix,
   `POST /api/location {"latitude": .., "longitude": ..}` — the mobile app
   will do this with the phone's GPS; a device/manual fix is never
   overwritten by auto-detection.
3. Open the dashboard: `http://<board-hostname>.local:7000` (the web_ui
   Brick prints its port on startup).

### Headless workflow (no App Lab GUI)

The board ships `arduino-app-cli`, which manages apps directly on the
device — useful for deploying from this repo and for watching logs while
debugging. With SSH enabled on the board:

```sh
# push the app from the repo to the board
rsync -av --delete hub/ <user>@<board>.local:~/ArduinoApps/plant-intelligence/

# start / stop / follow logs (on the board, or via ssh -t)
arduino-app-cli app start ~/ArduinoApps/plant-intelligence
arduino-app-cli app stop  ~/ArduinoApps/plant-intelligence
arduino-app-cli app logs  ~/ArduinoApps/plant-intelligence --follow
```

Starting an app compiles and flashes the sketch to the MCU and launches the
Python side, same as pressing Run in App Lab.

The soil probe ships disabled (`soil_enabled: false`), which is what puts
the schedule on its fixed 07:00/17:00 slots. After installing and
calibrating it (record the raw ADC value dry and submerged, set
`soil_raw_dry` / `soil_raw_wet`), flip it on — the engine folds soil into
its decisions and the adaptive cadence takes over automatically.

The fixed slots are `fixed_times` (default `["07:00", "17:00"]`), and
`fixed_when_no_soil: false` opts out of them entirely — adaptive cadence
from the start, probe or no probe.

## Local API

| Method | Path          | Purpose                              |
|--------|---------------|--------------------------------------|
| GET    | `/api/status` | Live sensors, watering state, plan, weather |
| GET    | `/api/history`| Recent watering events               |
| GET    | `/api/logs`   | System log                           |
| GET    | `/api/config` | Active configuration                 |
| POST   | `/api/water`  | Start a manual watering              |
| POST   | `/api/stop`   | Stop watering                        |
| POST   | `/api/location` | Set precise coordinates (e.g. phone GPS) |
| POST   | `/api/push/register` | Register an APNs token from the app  |
| POST   | `/api/push/config` | Install the APNs auth key            |
| POST   | `/api/push/test` | Send a test notification               |

A WebSocket `telemetry` event pushes the same status payload every few
seconds for live clients.

## Notifications

Watering start/end reaches the phone three ways, in increasing order of
reach:

1. **Scheduled locally.** The app turns the hub's predicted watering time
   into local notifications. Works offline and needs no setup, but only
   covers waterings already planned when the app last ran.
2. **Pushed from the hub.** The board talks to Apple's APNs directly — no
   Firebase, no relay server — so manual runs and the MCU failsafe reach
   you with the app closed.
3. **Live Activity.** A lock-screen card with a self-running countdown for
   the duration of the watering. The hub can raise it via a push-to-start
   token even if the app was never opened.

Steps 2 and 3 need an APNs auth key, the one part that can't be automated:

1. developer.apple.com → Certificates, Identifiers & Profiles → **Keys** →
   add a key with **Apple Push Notifications service (APNs)** enabled.
   Download the `.p8` (offered once only) and note the **Key ID** and the
   **Team ID**.
2. Install it on the board. The key is stored only in `hub/data/config.json`,
   which is gitignored:

```bash
curl -X POST "http://plantintelligence.local:7000/api/push/config\
?key_id=ABC123DEFG&team_id=P2FZ58Y7VW&bundle_id=com.souvikbiswas.plants&sandbox=1" \
  --data-binary @AuthKey_ABC123DEFG.p8
```

Use `sandbox=1` for builds run from Xcode and `sandbox=0` for TestFlight or
the App Store — the two APNs environments issue different device tokens.
Then open the app on a real device (the simulator is never issued a push
token) and check Settings → Notifications, or:

```bash
curl -X POST http://plantintelligence.local:7000/api/push/test
```

## Roadmap

- Native iOS app over the local API (mobile/ios)
- Cloud sync for remote access — the seam is `hub/python/cloud.py`; local
  document shapes already mirror the previous system's Firestore schema
- Soil probe fleet: the engine takes one probe today, N by config
- On-device anomaly detection (pump ran, soil never responded)
