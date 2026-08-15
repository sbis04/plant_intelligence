"""Runtime configuration.

Persisted as JSON next to the database so settings survive restarts and can
be edited through the API without touching code. Every value has a sane
default; the file is created on first run.
"""

import json
import os
from dataclasses import dataclass, asdict, field

# Data lives INSIDE the app directory: it's the only path bind-mounted from
# the host into the app container, so it survives container rebuilds (adding
# a brick recreates the container — anything outside this mount is wiped).
_APP_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_DIR = os.path.join(_APP_ROOT, "data")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")
DB_PATH = os.path.join(CONFIG_DIR, "plant.db")


@dataclass
class Config:
    # --- location ----------------------------------------------------------
    # Detected automatically on first boot via IP geolocation (city-level —
    # the same granularity weather forecasts have). Set through the API for
    # precision: POST /api/location with the phone's GPS fix. A manual or
    # device-set location is never overwritten by auto-detection.
    latitude: float = 22.5726            # fallback until detection succeeds
    longitude: float = 88.3639
    location_source: str = "unset"       # unset | ip | device | manual
    location_name: str = ""
    timezone: str = "Asia/Kolkata"

    # --- cadence -------------------------------------------------------------
    # The engine predicts the next watering as: last watering + interval,
    # where the interval stretches/shrinks with weather (and soil, once the
    # probe is installed). base_interval_h = 12 reproduces the old twice-a-day
    # rhythm in neutral weather.
    base_interval_h: float = 12.0
    min_interval_h: float = 6.0
    max_interval_h: float = 36.0
    # Watering is only started inside this local-time window.
    window_start: str = "05:30"
    window_end: str = "20:00"

    # --- duration --------------------------------------------------------------
    base_duration_s: int = 300          # the old fixed 5 minutes
    min_duration_s: int = 60
    max_duration_s: int = 600           # MCU enforces its own hard cap too

    # --- weather response ------------------------------------------------------
    rain_skip_probability: float = 60.0  # % precip probability that postpones
    hot_day_c: float = 35.0              # shortens interval, lengthens watering
    very_hot_day_c: float = 40.0
    cool_day_c: float = 25.0             # stretches interval, shortens watering

    # --- soil probe (disabled until installed & calibrated) ---------------------
    soil_enabled: bool = False
    soil_raw_dry: int = 850              # ADC raw in dry air  (calibrate!)
    soil_raw_wet: int = 400              # ADC raw in water    (calibrate!)
    soil_skip_above_pct: float = 60.0    # wet enough → postpone
    soil_water_below_pct: float = 30.0   # dry enough → water regardless of clock

    # --- garden camera (Tapo RTSP; set via POST /api/camera/config) ---------------
    # Credentials live in hub/data/config.json on the board — gitignored,
    # never committed. Create them in the Tapo app: Advanced Settings →
    # Camera Account.
    camera_rtsp_url: str = ""            # e.g. rtsp://192.168.68.63:554/stream1
    camera_username: str = ""
    camera_password: str = ""

    # --- assistant (hybrid) --------------------------------------------------
    # With an API key set, questions go to Gemini Flash whenever the internet
    # is reachable — the on-device model stays as the offline fallback. The
    # key lives only in hub/data/config.json on the board (gitignored).
    cloud_llm_api_key: str = ""
    cloud_llm_model: str = "gemini-flash-latest"   # evergreen alias, never stale

    # --- push notifications (APNs, direct — no Firebase) ---------------------
    # The .p8 key contents and its ids; set via POST /api/push/config or the
    # app's Settings. Stored only in hub/data/config.json (gitignored).
    apns_key_p8: str = ""
    apns_key_id: str = ""
    apns_team_id: str = ""
    apns_bundle_id: str = "com.souvikbiswas.plants"
    apns_use_sandbox: bool = True        # development builds use the sandbox

    # --- failsafe ----------------------------------------------------------------
    failsafe_silence_h: int = 14         # MCU waters on its own after this silence

    def save(self) -> None:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(CONFIG_PATH, "w") as f:
            json.dump(asdict(self), f, indent=2)

    @classmethod
    def load(cls) -> "Config":
        try:
            with open(CONFIG_PATH) as f:
                data = json.load(f)
            known = {k: v for k, v in data.items() if k in cls.__dataclass_fields__}
            return cls(**known)
        except (FileNotFoundError, json.JSONDecodeError, TypeError):
            cfg = cls()
            cfg.save()
            return cfg

    def soil_raw_to_pct(self, raw: int):
        """Convert a raw ADC reading to 0–100 % moisture, or None if unusable."""
        if not self.soil_enabled or raw < 0:
            return None
        span = self.soil_raw_dry - self.soil_raw_wet
        if span == 0:
            return None
        pct = (self.soil_raw_dry - raw) * 100.0 / span
        return max(0.0, min(100.0, pct))
