"""Plant Intelligence — composition root.

Wires the hardware bridge, weather service, decision engine, storage, and
the local API together, then runs a 1-second scheduler loop:

  every tick   — execute a due watering decision
  every 3 s    — push telemetry to connected dashboard/app clients
  every 30 s   — heartbeat the MCU (feeds its dead-man failsafe)
  every 60 s   — persist sensor samples to the time-series store
  every 5 min  — recompute the watering plan (weather + soil + history)
  every 30 min — refresh the weather (cached inside WeatherService)

The MCU waters on its own conservative timer if this process dies — that
failsafe is tested by killing this process, not by trusting this comment.
"""

import time
from datetime import datetime
from zoneinfo import ZoneInfo

from arduino.app_utils import App
from arduino.app_bricks.web_ui import WebUI
from arduino.app_bricks.dbstorage_tsstore import TimeSeriesStore

import api
import location
from cloud import NullSync
from config import Config
from decision import compute_plan
from hardware import Hardware
from store import Store
from weather import WeatherService


class AppContext:
    def __init__(self):
        self.config = Config.load()
        self.tz = ZoneInfo(self.config.timezone)
        self.store = Store()
        self.hardware = Hardware()
        self.weather_svc = WeatherService(self.config)
        self.cloud = NullSync()   # future Firebase sync plugs in here (see cloud.py)

        self.current_plan = None
        self.current_weather = None
        self.assistant = None   # attached in main() after bricks are up
        self.camera = None
        self.relay = None       # go2rtc live-stream relay
        self.push = None        # APNs sender, attached in main()
        self._open_watering_row = None
        self._pending_trigger = None   # trigger/reason for the next start event

        self.hardware.on_event(self._on_mcu_event)

    # ---- location -------------------------------------------------------------
    def try_autolocate(self) -> bool:
        """IP-geolocate on first boot. Never overrides a device/manual fix."""
        if self.config.location_source not in ("unset", "ip"):
            return True
        found = location.detect()
        if not found:
            return self.config.location_source == "ip"  # keep a previous fix
        lat, lon, name = found
        self.config.latitude, self.config.longitude = lat, lon
        self.config.location_source = "ip"
        self.config.location_name = name
        self.config.save()
        self.store.log("SYSTEM", f"Location auto-detected: {name} ({lat:.3f}, {lon:.3f})")
        return True

    def set_location(self, lat: float, lon: float, source: str = "device",
                     name: str = "") -> None:
        self.config.latitude, self.config.longitude = float(lat), float(lon)
        self.config.location_source = source
        self.config.location_name = name
        self.config.save()
        self.store.log("SYSTEM", f"Location set ({source}): {lat:.4f}, {lon:.4f}")
        self.recompute_plan()

    # ---- watering orchestration ---------------------------------------------
    def request_manual_watering(self, duration_s: int) -> bool:
        if self.hardware.is_watering():
            return False
        self._pending_trigger = ("manual", "requested via API")
        self.hardware.start_watering(duration_s)
        return True

    def execute_plan(self):
        plan = self.current_plan
        if plan and plan.water_now and not self.hardware.is_watering():
            self._pending_trigger = ("scheduled", "; ".join(plan.reasons))
            self.hardware.start_watering(plan.duration_s)
            # Re-plan immediately so we don't double-trigger on the next tick.
            self.recompute_plan()

    def _on_mcu_event(self, name: str, label: str, is_error: bool):
        self.store.log("MCU", label, is_error)

        if name in ("watering_started", "failsafe_watering_started"):
            trigger, reason = self._pending_trigger or (
                "failsafe" if name.startswith("failsafe") else "scheduled", "")
            self._pending_trigger = None
            self._open_watering_row = self.store.watering_started(
                trigger, 0, reason)
            doc = {"trigger": trigger, "reason": reason}
            self.cloud.push_watering_event(doc)
            self._announce_watering_started(trigger, reason)
        elif name in ("watering_ended", "watering_stopped"):
            self.store.watering_ended(self._open_watering_row)
            self._open_watering_row = None
            self.recompute_plan()
            self._announce_watering_ended(name == "watering_stopped")

    # ---- phone notifications ----------------------------------------------------
    # Pushed straight to APNs (see push.py). Each watering raises a live
    # activity card with a self-running countdown, plus a normal alert for
    # the cases you actually want to know about away from home.
    def _announce_watering_started(self, trigger: str, reason: str):
        if not self.push:
            return
        try:
            snap = self.hardware.snapshot()
            duration = snap.get("watering_seconds_left") or (
                self.current_plan.duration_s if self.current_plan else 300)
            state = {
                "endsAtEpoch": time.time() + duration,
                "totalSeconds": int(duration),
                "trigger": trigger,
                "finished": False,
                "note": reason[:90],
            }
            attributes = {"locationName": self.config.location_name or "Garden"}
            titles = {
                "manual": "Watering started",
                "scheduled": "Watering started",
                "failsafe": "Failsafe watering",
            }
            body = {
                "failsafe": "The microcontroller started watering on its own — "
                            "it hadn't heard from the hub.",
            }.get(trigger, reason or f"Running for about {int(duration / 60)} min.")
            self.push.activity_start(
                state, attributes,
                alert={"title": titles.get(trigger, "Watering started"), "body": body})
            self.push.notify(titles.get(trigger, "Watering started"), body,
                             interruption="time-sensitive" if trigger == "failsafe"
                             else "active")
        except Exception as e:
            self.store.log("SYSTEM", f"Push (start) failed: {e}", is_error=True)

    def _announce_watering_ended(self, stopped: bool):
        if not self.push:
            return
        try:
            state = {
                "endsAtEpoch": time.time(),
                "totalSeconds": 0,
                "trigger": "",
                "finished": True,
                "note": "",
            }
            self.push.activity_update(state, event="end", dismiss_in_s=90)
            nxt = ""
            if self.current_plan and self.current_plan.next_water_at:
                nxt = " Next: " + self.current_plan.next_water_at.strftime(
                    "%a %d %b, %I:%M %p")
            self.push.notify("Watering finished" if not stopped else "Watering stopped",
                             ("The garden has been watered." if not stopped
                              else "Stopped by request.") + nxt)
        except Exception as e:
            self.store.log("SYSTEM", f"Push (end) failed: {e}", is_error=True)

    # ---- periodic work ----------------------------------------------------------
    def recompute_plan(self):
        now = datetime.now(self.tz)
        snap = self.hardware.snapshot()
        soil_pct = self.config.soil_raw_to_pct(snap.get("soil_raw", -1))
        self.current_weather = self.weather_svc.get()
        self.current_plan = compute_plan(
            self.config, now, soil_pct, self.current_weather,
            self.store.last_watering_end(),
        )


def main():
    ctx = AppContext()
    ui = WebUI()
    ts = TimeSeriesStore()
    ts.start()

    try:
        from assistant import Assistant
        ctx.assistant = Assistant(ctx)
        ctx.store.log("SYSTEM", "On-board assistant ready (local LLM)")
    except Exception as e:
        ctx.store.log("SYSTEM", f"Assistant unavailable: {e}", is_error=True)

    try:
        from camera import CameraService
        ctx.camera = CameraService(ctx.config)
    except Exception as e:
        ctx.store.log("SYSTEM", f"Camera service unavailable: {e}", is_error=True)

    try:
        from push import PushService
        ctx.push = PushService(ctx.config, ctx.store, log=ctx.store.log)
    except Exception as e:
        ctx.store.log("SYSTEM", f"Push service unavailable: {e}", is_error=True)

    try:
        from relay import CameraRelay
        ctx.relay = CameraRelay(ctx.config, log=ctx.store.log)
        ctx.relay.start_async()
    except Exception as e:
        ctx.relay = None
        ctx.store.log("SYSTEM", f"Camera relay unavailable: {e}", is_error=True)

    api.register(ui, ctx)

    ctx.store.log("SYSTEM", "Plant Intelligence hub started")
    stale = ctx.store.close_stale_open_rows()
    if stale:
        ctx.store.log("SYSTEM", f"Closed {stale} watering record(s) left open by a restart")
    ctx.hardware.set_failsafe_hours(ctx.config.failsafe_silence_h)
    located = ctx.try_autolocate()
    ctx.recompute_plan()

    last = {"ping": 0.0, "telemetry": 0.0, "samples": 0.0, "plan": 0.0,
            "locate": time.time(), "leds": 0.0}
    led_state = {"mode": -1, "healthy": None}

    def service_leds():
        """Board lights: the matrix ambient mode (idle wave / rain hold /
        assistant thinking) and LED1 = hub health (green ok, red when the
        MCU has gone quiet). Pushed only on change."""
        if ctx.assistant and ctx.assistant.busy:
            mode = 2
        elif ctx.current_plan and any("rain" in r for r in ctx.current_plan.reasons):
            mode = 1
        else:
            mode = 0
        if mode != led_state["mode"]:
            led_state["mode"] = mode
            try:
                ctx.hardware.set_led_mode(mode)
            except Exception:
                led_state["mode"] = -1   # retry next tick
        seen = ctx.hardware.snapshot().get("mcu_seen_seconds_ago")
        healthy = seen is not None and seen < 180
        if healthy != led_state["healthy"]:
            led_state["healthy"] = healthy
            try:
                from arduino.app_utils import Leds
                Leds.set_led1_color(0, 1, 0) if healthy else Leds.set_led1_color(1, 0, 0)
            except Exception:
                pass

    def loop():
        nonlocal located
        now = time.time()

        if now - last["ping"] >= 30:
            last["ping"] = now
            ctx.hardware.ping()

        if now - last["leds"] >= 2:
            last["leds"] = now
            service_leds()

        # Retry auto-location hourly until it succeeds (e.g. boot before Wi-Fi).
        if not located and now - last["locate"] >= 3600:
            last["locate"] = now
            located = ctx.try_autolocate()
            if located:
                ctx.recompute_plan()

        if now - last["plan"] >= 300:
            last["plan"] = now
            # Orphaned rows (a restart mid-watering) can close after just
            # 2 min when the MCU verifiably reports idle.
            ctx.store.close_stale_open_rows(
                max_age_min=15 if ctx.hardware.is_watering() else 2)
            ctx.recompute_plan()

        ctx.execute_plan()

        if now - last["telemetry"] >= 3:
            last["telemetry"] = now
            api.push_telemetry(ui, ctx)

        if now - last["samples"] >= 60:
            last["samples"] = now
            snap = ctx.hardware.snapshot()
            if snap["box_temperature_c"] is not None:
                ts.write_sample("box_temperature_c", snap["box_temperature_c"])
            if snap["box_humidity_pct"] is not None:
                ts.write_sample("box_humidity_pct", snap["box_humidity_pct"])
            w = ctx.current_weather
            if w and w.temp_now_c is not None:
                ts.write_sample("outside_temperature_c", w.temp_now_c)
            if w and w.humidity_now_pct is not None:
                ts.write_sample("outside_humidity_pct", w.humidity_now_pct)
            if snap["soil_raw"] >= 0:
                ts.write_sample("soil_raw", snap["soil_raw"])
                pct = ctx.config.soil_raw_to_pct(snap["soil_raw"])
                if pct is not None:
                    ts.write_sample("soil_pct", pct)

        time.sleep(1)

    App.run(user_loop=loop)


main()
