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
    def __init__(self, config):
        self._config = config           # live reference: location may be set later
        self._cache: Optional[WeatherSummary] = None
        self._cache_key = None
        self._brick = WeatherForecast() if WeatherForecast else None

    @property
    def lat(self):
        return self._config.latitude

    @property
    def lon(self):
        return self._config.longitude

    def get(self) -> Optional[WeatherSummary]:
        key = (round(self.lat, 3), round(self.lon, 3))
        if (self._cache and self._cache_key == key
                and time.time() - self._cache.fetched_at < CACHE_TTL_S):
            return self._cache
        self._cache_key = key

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
                pass  # Brick unavailable — the numbers below still work

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

        # Only cache if we got something useful; otherwise retry sooner.
        if summary.category or summary.temp_max_next12h is not None:
            self._cache = summary
            return summary
        return self._cache
