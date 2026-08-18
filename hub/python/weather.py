"""Weather intake.

Two sources, deliberately:
  - the App Lab weather_forecast Brick for the current-conditions category
    (simple, no key, part of the platform)
  - Open-Meteo's hourly forecast (same upstream the Brick uses, also keyless)
    for the numbers the cadence math needs: max temperature and max
    precipitation probability over the next 12 hours.

Both are cached and both fail soft — the decision engine treats missing
weather as "neutral" rather than erroring.
"""

import json
import threading
import time
import urllib.request
from dataclasses import dataclass
from typing import Optional

try:
    from arduino.app_bricks.weather_forecast import WeatherForecast
except ImportError:          # running off-board (tests, development)
    WeatherForecast = None

RAINY_CATEGORIES = {"RAINY", "RAIN", "DRIZZLE", "THUNDERSTORM", "SHOWERS"}
CACHE_TTL_S = 30 * 60


@dataclass
class WeatherSummary:
    category: Optional[str] = None            # from the Brick, e.g. "SUNNY"
    description: Optional[str] = None
    temp_now_c: Optional[float] = None        # current outside conditions
    humidity_now_pct: Optional[float] = None
    temp_max_next12h: Optional[float] = None  # °C
    precip_prob_max_next12h: Optional[float] = None  # %
    is_raining_now: bool = False
    fetched_at: float = 0.0

    def to_dict(self) -> dict:
        return {
            "category": self.category,
            "description": self.description,
            "temp_now_c": self.temp_now_c,
            "humidity_now_pct": self.humidity_now_pct,
            "temp_max_next12h": self.temp_max_next12h,
            "precip_prob_max_next12h": self.precip_prob_max_next12h,
            "is_raining_now": self.is_raining_now,
        }


class WeatherService:
    """Fetches in the background, answers from cache.

    `get()` used to fetch inline, on the scheduler thread. The Brick's
    forecast call has no timeout of its own, and one half-open TLS
    connection wedged that thread for eighteen hours: no plans, no camera
    looks, and no heartbeat to the MCU, which eventually concluded Linux
    was dead and watered on its own failsafe. Nothing on the network is
    allowed to stall a watering decision again, so the fetch happens on its
    own thread and `get()` never blocks.
    """

    def __init__(self, config, on_update=None):
        self._config = config           # live reference: location may be set later
        self._cache: Optional[WeatherSummary] = None
        self._cache_key = None
        self._brick = WeatherForecast() if WeatherForecast else None
        self._lock = threading.Lock()
        self._fetching = False
        self._on_update = on_update     # called after a successful refresh

    @property
    def lat(self):
        return self._config.latitude

    @property
    def lon(self):
        return self._config.longitude

    def get(self) -> Optional[WeatherSummary]:
        """The cached summary, refreshing in the background when stale.
        Returns None only before the very first fetch lands; the decision
        engine already treats missing weather as neutral."""
        key = (round(self.lat, 3), round(self.lon, 3))
        cache = self._cache
        if (cache and self._cache_key == key
                and time.time() - cache.fetched_at < CACHE_TTL_S):
            return cache
        self._refresh_soon(key)
        return cache if self._cache_key == key else None

    def _refresh_soon(self, key):
        with self._lock:
            if self._fetching:
                return
            self._fetching = True
        threading.Thread(target=self._refresh, args=(key,),
                         name="weather-refresh", daemon=True).start()

    def _refresh(self, key):
        try:
            summary = self._fetch()
        except Exception:
            summary = None
        finally:
            with self._lock:
                self._fetching = False
        if summary is None:
            return
        self._cache_key = key
        self._cache = summary
        if self._on_update:
            try:
                self._on_update()
            except Exception:
                pass

    def _fetch(self) -> Optional[WeatherSummary]:
        summary = WeatherSummary(fetched_at=time.time())

        if self._brick:
            try:
                fc = self._brick.get_forecast_by_coords(
                    latitude=str(self.lat), longitude=str(self.lon))
                summary.category = getattr(fc, "category", None)
                summary.description = getattr(fc, "description", None)
                if summary.category and str(summary.category).upper() in RAINY_CATEGORIES:
                    summary.is_raining_now = True
            except Exception:
                pass  # Brick unavailable or slow: the numbers below still work

        try:
            hours = 12
            url = (
                "https://api.open-meteo.com/v1/forecast"
                f"?latitude={self.lat}&longitude={self.lon}"
                "&current=temperature_2m,relative_humidity_2m"
                "&hourly=temperature_2m,precipitation_probability"
                f"&forecast_hours={hours}&timezone=auto"
            )
            with urllib.request.urlopen(url, timeout=10) as r:
                data = json.load(r)
            current = data.get("current") or {}
            summary.temp_now_c = current.get("temperature_2m")
            summary.humidity_now_pct = current.get("relative_humidity_2m")
            temps = data.get("hourly", {}).get("temperature_2m") or []
            probs = data.get("hourly", {}).get("precipitation_probability") or []
            if temps:
                summary.temp_max_next12h = max(t for t in temps if t is not None)
            if probs:
                summary.precip_prob_max_next12h = max(p for p in probs if p is not None)
        except Exception:
            pass

        # Only accept it if we got something useful; a blank summary would
        # otherwise overwrite good data and reset the cache clock.
        if summary.category or summary.temp_max_next12h is not None:
            return summary
        return None
