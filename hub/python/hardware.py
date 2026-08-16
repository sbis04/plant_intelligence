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

# Event codes, mirroring the sketch: machine name (for logic), human label
# (for logs and UI), is_error.
EVENTS = {
    1: ("watering_started", "Watering started", False),
    2: ("watering_ended", "Watering finished", False),
    3: ("watering_stopped", "Watering stopped by request", False),
    4: ("watering_rejected_busy", "Watering rejected: already running", True),
    5: ("watering_rejected_too_soon", "Watering rejected: too soon after the last one", True),
    6: ("failsafe_watering_started", "Failsafe watering started — the MCU hasn't heard from Linux", True),
    7: ("fan_on", "Cooling fan on", False),
    8: ("fan_off", "Cooling fan off", False),
    9: ("dht_read_failing", "DHT sensor not responding", True),
    10: ("dht_recovered", "DHT sensor recovered", False),
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
        self._rpc_failures: int = 0
        self._last_rpc_error: str = ""
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
        name, label, is_error = EVENTS.get(
            int(code), (f"unknown_event_{code}", f"Unknown MCU event ({code})", True))
        if name in ("fan_on", "fan_off"):
            with self._lock:
                self._fan_on = name == "fan_on"
        for listener in list(self._event_listeners):
            try:
                listener(name, label, is_error)
            except Exception:
                pass

    # ---- Python → MCU ---------------------------------------------------------
    def _call(self, method: str, *args) -> bool:
        """Every MCU command goes through here, and none of them may raise.

        Bridge.call times out if the MCU is mid-reset or its serial link
        hiccups. That used to propagate out of the scheduler loop and take
        the whole hub down — which is backwards: the Linux side exists to
        keep deciding, and the MCU has its own failsafe for real silence.
        A failed command is reported, never fatal.
        """
        try:
            Bridge.call(method, *args)
            with self._lock:
                self._rpc_failures = 0
                self._last_rpc_error = ""
            return True
        except Exception as e:
            with self._lock:
                self._rpc_failures += 1
                self._last_rpc_error = f"{method}: {e}"
            return False

    def start_watering(self, duration_s: int) -> bool:
        return self._call("start_watering", int(duration_s) * 1000)

    def stop_watering(self) -> bool:
        return self._call("stop_watering")

    def ping(self) -> bool:
        """Heartbeat feeding the MCU's dead-man failsafe."""
        return self._call("ping")

    def set_failsafe_hours(self, hours: int) -> bool:
        return self._call("set_failsafe", int(hours))

    def set_led_mode(self, mode: int) -> bool:
        """Ambient LED matrix mode: 0 idle, 1 rain hold, 2 thinking."""
        return self._call("set_led_mode", int(mode))

    def rpc_health(self) -> tuple:
        """(consecutive failures, last error) — for logging and the API."""
        with self._lock:
            return self._rpc_failures, self._last_rpc_error

    # ---- accessors --------------------------------------------------------------
    def on_event(self, listener: Callable[[str, str, bool], None]):
        """listener(machine_name, human_label, is_error)"""
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
                "mcu_rpc_failures": self._rpc_failures,
            }

    def is_watering(self) -> bool:
        with self._lock:
            return self._state in (1, 2)
