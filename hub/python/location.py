"""Automatic location detection.

A headless board has no GPS, but its internet connection knows roughly where
it is: IP geolocation gives city-level coordinates, which is exactly the
granularity weather forecasts have anyway. Detection runs once on first
boot; a manual or device-supplied location (the mobile app sending the
phone's GPS via POST /api/location) always takes precedence and is never
overwritten.

Two keyless providers are tried in order; both fail soft.
"""

import json
import urllib.request
from typing import Optional, Tuple

_PROVIDERS = [
    # (url, lat key, lon key, name builder)
    ("https://ipapi.co/json/",
     "latitude", "longitude",
     lambda d: ", ".join(x for x in (d.get("city"), d.get("region")) if x)),
    ("http://ip-api.com/json/?fields=status,lat,lon,city,regionName",
     "lat", "lon",
     lambda d: ", ".join(x for x in (d.get("city"), d.get("regionName")) if x)),
]


def detect(timeout_s: int = 10) -> Optional[Tuple[float, float, str]]:
    """Return (latitude, longitude, place_name) or None if detection failed."""
    for url, lat_key, lon_key, name_of in _PROVIDERS:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "plant-intelligence-hub"})
            with urllib.request.urlopen(req, timeout=timeout_s) as r:
                data = json.load(r)
            lat, lon = data.get(lat_key), data.get(lon_key)
            if lat is None or lon is None:
                continue
            return float(lat), float(lon), name_of(data) or "unknown"
        except Exception:
            continue
    return None
