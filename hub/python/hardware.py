"""Bridge to the microcontroller.

The MCU pushes telemetry via Bridge.notify; we keep the latest snapshot
here behind a lock. Commands go the other way with Bridge.call. This module
is the only place that talks to the Bridge, so the rest of the code stays
testable off-board.
"""

import threading
import time
from typing import Callable, Optional

from arduino.app_utils import Bridge

# Watering state machine states, mirroring the sketch.
STATES = {0: "idle", 1: "valve_opening", 2: "watering", 3: "closing"}

# Event codes, mirroring the sketch.
EVENTS = {
    1: ("watering_started", False),
    2: ("watering_ended", False),
    3: ("watering_stopped", False),
    4: ("watering_rejected_busy", True),
    5: ("watering_rejected_too_soon", True),
    6: ("failsafe_watering_started", True),
    7: ("fan_on", False),
    8: ("fan_off", False),
    9: ("dht_read_failing", True),
    10: ("dht_recovered", False),
}


class Hardware:
    def __init__(self):
        self._lock = threading.Lock()
        self._temp: Optional[float] = None
        self._hum: Optional[float] = None
        self._soil_raw: int = -1
        self._state: int = 0
        self._seconds_left: int = 0
        self._fan_on: bool = False
        self._last_seen: float = 0.0
        self._event_listeners: list[Callable[[str, bool], None]] = []

        Bridge.provide("on_temperature", self._on_temperature)
        Bridge.provide("on_humidity", self._on_humidity)
        Bridge.provide("on_soil", self._on_soil)
        Bridge.provide("on_state", self._on_state)
        Bridge.provide("on_seconds_left", self._on_seconds_left)
        Bridge.provide("on_event", self._on_event)

    # ---- MCU → Python -------------------------------------------------------
    def _touch(self):
        self._last_seen = time.time()

    def _on_temperature(self, v: float):
        with self._lock:
            self._temp = float(v)
            self._touch()

    def _on_humidity(self, v: float):
        with self._lock:
            self._hum = float(v)
            self._touch()

    def _on_soil(self, v: int):
        with self._lock:
            self._soil_raw = int(v)
            self._touch()

    def _on_state(self, v: int):
        with self._lock:
            self._state = int(v)
            self._touch()

    def _on_seconds_left(self, v: int):
        with self._lock:
            self._seconds_left = int(v)
            self._touch()

    def _on_event(self, code: int):
        name, is_error = EVENTS.get(int(code), (f"unknown_event_{code}", True))
        if name in ("fan_on", "fan_off"):
            with self._lock:
                self._fan_on = name == "fan_on"
        for listener in list(self._event_listeners):
            try:
                listener(name, is_error)
            except Exception:
                pass

    # ---- Python → MCU ---------------------------------------------------------
    def start_watering(self, duration_s: int):
        Bridge.call("start_watering", int(duration_s) * 1000)

    def stop_watering(self):
        Bridge.call("stop_watering")

    def ping(self):
        """Heartbeat feeding the MCU's dead-man failsafe."""
        Bridge.call("ping")

    def set_failsafe_hours(self, hours: int):
        Bridge.call("set_failsafe", int(hours))

    # ---- accessors --------------------------------------------------------------
    def on_event(self, listener: Callable[[str, bool], None]):
        self._event_listeners.append(listener)

    def snapshot(self) -> dict:
        with self._lock:
            return {
                # DHT11 lives inside the control box; the fan cools the box.
                "box_temperature_c": self._temp,
                "box_humidity_pct": self._hum,
                "fan_on": self._fan_on,
                "soil_raw": self._soil_raw,
                "watering_state": STATES.get(self._state, "unknown"),
                "watering_seconds_left": self._seconds_left,
                "mcu_seen_seconds_ago": round(time.time() - self._last_seen, 1)
                if self._last_seen else None,
            }

    def is_watering(self) -> bool:
        with self._lock:
            return self._state in (1, 2)
