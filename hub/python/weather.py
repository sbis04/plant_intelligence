"""Weather intake.

One source: Open-Meteo, keyless, read with an explicit timeout.

This used to also call the App Lab weather_forecast Brick for the
conditions text. That Brick uses `requests.get()` with no timeout, and
`requests` passes `timeout=None` down explicitly, which overrides
`socket.setdefaulttimeout()` — so a half-open TLS handshake hangs forever
and no global setting can save it. It froze the scheduler once, and after
the fetch was moved onto its own thread it simply froze that thread instead
and wedged the refresh flag, leaving the weather permanently stale.

Open-Meteo already returns a WMO weather code, so the category and the
description come from the same response as the numbers, and every call this
module makes now has a deadline it cannot exceed.
"""

import json
import threading
import time
import urllib.request
from dataclasses import dataclass
from typing import Optional

RAINY_CATEGORIES = {"RAINY", "RAIN", "DRIZZLE", "THUNDERSTORM", "SHOWERS"}
CACHE_TTL_S = 30 * 60
FETCH_TIMEOUT_S = 10

# WMO weather interpretation codes, as returned by Open-Meteo.
WMO = {
    0: ("CLEAR", "Clear sky"),
    1: ("SUNNY", "Mainly clear"),
    2: ("CLOUDY", "Partly cloudy"),
    3: ("CLOUDY", "Overcast"),
    45: ("FOG", "Fog"), 48: ("FOG", "Depositing rime fog"),
    51: ("DRIZZLE", "Light drizzle"),
    53: ("DRIZZLE", "Moderate drizzle"),
    55: ("DRIZZLE", "Dense drizzle"),
    56: ("DRIZZLE", "Light freezing drizzle"),
    57: ("DRIZZLE", "Dense freezing drizzle"),
    61: ("RAIN", "Slight rain"),
    63: ("RAIN", "Moderate rain"),
    65: ("RAIN", "Heavy rain"),
    66: ("RAIN", "Light freezing rain"),
    67: ("RAIN", "Heavy freezing rain"),
    71: ("SNOW", "Slight snowfall"),
    73: ("SNOW", "Moderate snowfall"),
    75: ("SNOW", "Heavy snowfall"),
    77: ("SNOW", "Snow grains"),
    80: ("SHOWERS", "Slight rain showers"),
    81: ("SHOWERS", "Moderate rain showers"),
    82: ("SHOWERS", "Violent rain showers"),
    85: ("SNOW", "Slight snow showers"),
    86: ("SNOW", "Heavy snow showers"),
    95: ("THUNDERSTORM", "Thunderstorm"),
    96: ("THUNDERSTORM", "Thunderstorm with slight hail"),
    99: ("THUNDERSTORM", "Thunderstorm with heavy hail"),
}


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
        self._lock = threading.Lock()
        self._fetch_started = 0.0
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
            # A timestamp rather than a bool: if a fetch ever does wedge, the
            # flag frees itself instead of blocking every future refresh.
            if time.time() - self._fetch_started < 2 * FETCH_TIMEOUT_S:
                return
            self._fetch_started = time.time()
        threading.Thread(target=self._refresh, args=(key,),
                         name="weather-refresh", daemon=True).start()

    def _refresh(self, key):
        try:
            summary = self._fetch()
        except Exception:
            summary = None
        finally:
            with self._lock:
                self._fetch_started = 0.0
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

        try:
            hours = 12
            url = (
                "https://api.open-meteo.com/v1/forecast"
                f"?latitude={self.lat}&longitude={self.lon}"
                "&current=temperature_2m,relative_humidity_2m,weather_code"
                "&hourly=temperature_2m,precipitation_probability"
                f"&forecast_hours={hours}&timezone=auto"
            )
            with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT_S) as r:
                data = json.load(r)
            current = data.get("current") or {}
            summary.temp_now_c = current.get("temperature_2m")
            summary.humidity_now_pct = current.get("relative_humidity_2m")
            code = current.get("weather_code")
            if code is not None:
                summary.category, summary.description = WMO.get(
                    int(code), ("UNKNOWN", f"Weather code {int(code)}"))
                summary.is_raining_now = summary.category in RAINY_CATEGORIES
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
