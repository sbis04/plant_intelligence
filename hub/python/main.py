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

import os
import socket
import threading
import time
from datetime import datetime
from zoneinfo import ZoneInfo

# Backstop for every library that forgets to pass a timeout. urllib3 (and
# therefore requests, and therefore the weather Brick) falls back to the
# socket default, so this caps calls we don't control. Belt to the braces
# of keeping network work off the scheduler thread entirely.
socket.setdefaulttimeout(20)

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
        self.weather_svc = WeatherService(self.config,
                                          on_update=self.recompute_plan)
        self.cloud = NullSync()   # future Firebase sync plugs in here (see cloud.py)

        self.current_plan = None
        self.current_weather = None
        self.assistant = None   # attached in main() after bricks are up
        self.camera = None
        self.vision = None      # Gemini reading the actual roof (vision.py)
        self.relay = None       # go2rtc live-stream relay
        self.push = None        # APNs sender, attached in main()
        self._open_watering_row = None
        self._pending_trigger = None   # trigger/reason for the next start event
        self._preslot_checked_for = None   # slot whose pre-watering look is done
        self._last_command_at = None       # when we last told the MCU to water
        self._warmup_logged = False        # said "waiting for sensors" once
        self._soil_block_since = None      # when soil last started blocking
        self._soil_dry_since = None        # when soil first read below the trigger

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
    # The MCU reports its state on a 5 s telemetry cycle, so is_watering()
    # is stale for a few seconds after a watering starts AND after one ends.
    # This is how long our own command stays the authority instead.
    COMMAND_SETTLE_S = 15

    # FAILSAFE_DURATION_MS in sketch.ino. The MCU picks this itself when it
    # waters without us, so the phone card has to be told the same number.
    MCU_FAILSAFE_DURATION_S = 300

    def watering_in_flight(self) -> bool:
        """Is a watering running, starting, or finishing right now?

        Three guards for three different windows, because the obvious one is
        stale exactly when it matters:
          is_watering()      - the steady state, but 5 s behind reality
          _open_watering_row - set on the MCU's start event and cleared on
                               its end event, so it covers the gap between
                               the state going idle and the end arriving
          _last_command_at   - covers the gap between us commanding a start
                               and the MCU's start event coming back
        """
        if self.hardware.is_watering() or self._open_watering_row is not None:
            return True
        return (self._last_command_at is not None
                and time.time() - self._last_command_at < self.COMMAND_SETTLE_S)

    def request_manual_watering(self, duration_s: int) -> bool:
        # A second tap inside the settle window would otherwise sail past
        # is_watering() and be refused by the firmware instead.
        if self.watering_in_flight():
            return False
        self._pending_trigger = ("manual", "requested via API")
        if not self.hardware.start_watering(duration_s):
            self._pending_trigger = None
            _, err = self.hardware.rpc_health()
            self.store.log("SYSTEM", f"Watering command not accepted by the MCU ({err})",
                           is_error=True)
            return False
        self._last_command_at = time.time()
        return True

    def execute_plan(self):
        plan = self.current_plan
        if not plan or not plan.water_now:
            return
        if not self.sensors_ready():
            if not self._warmup_logged:
                self._warmup_logged = True
                self.store.log("SYSTEM",
                               "Holding off until the sensors report in")
            return
        if self._warmup_logged:
            # The sensors have just started reporting. The current plan was
            # formed while they were silent — with no soil term at all — so
            # decide again on the full picture rather than executing a plan
            # made in ignorance.
            self._warmup_logged = False
            self.recompute_plan()
            plan = self.current_plan
            if not plan or not plan.water_now:
                return

        if self.watering_in_flight():
            return

        self._pending_trigger = ("scheduled", "; ".join(plan.reasons))
        if not self.hardware.start_watering(plan.duration_s):
            # The MCU didn't take it. Leave the plan due so the next tick
            # tries again rather than silently losing the watering.
            self._pending_trigger = None
            return
        self._last_command_at = time.time()
        # Mark the plan as acted on. Re-planning here would NOT do it: the
        # history row is still open, so last_watering_end is unchanged and
        # compute_plan would say "due" all over again. The real re-plan
        # happens on the MCU's end event, once the row has closed.
        plan.water_now = False

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
            # At the moment the start event lands the MCU still reports 0
            # seconds left, so this falls through to a planned duration. A
            # failsafe run is the MCU's own fixed 5 minutes, not whatever
            # the plan happened to want.
            reported = snap.get("watering_seconds_left") or 0
            if reported > 0:
                duration = reported
            elif trigger == "failsafe":
                duration = self.MCU_FAILSAFE_DURATION_S
            else:
                duration = (self.current_plan.duration_s
                            if self.current_plan else 300)
            state = {
                "endsAtEpoch": time.time() + duration,
                "totalSeconds": int(duration),
                "trigger": trigger,
                "finished": False,
                "note": reason[:90],
            }
            location = self.config.location_name or "Location"
            attributes = {"locationName": location.split(",", 1)[0].strip() or "Location"}
            titles = {
                "manual": "Watering started",
                "scheduled": "Watering started",
                "failsafe": "Failsafe watering",
            }
            body = {
                "failsafe": "The microcontroller started watering on its own — "
                            "it hadn't heard from the hub.",
            }.get(trigger, reason or f"Running for about {int(duration / 60)} min.")
            cards = self.push.activity_start(
                state, attributes,
                alert={"title": titles.get(trigger, "Watering started"), "body": body})
            alerts = self.push.notify(
                titles.get(trigger, "Watering started"), body,
                interruption="time-sensitive" if trigger == "failsafe" else "active")
            # Say how many actually went out. Silence here previously looked
            # identical to success, so a watering with no notification gave
            # nothing to investigate afterwards.
            if not alerts:
                self.store.log("SYSTEM",
                               "Watering started but no phone accepted the alert",
                               is_error=True)
            else:
                self.store.log("SYSTEM",
                               f"Notified {alerts} device(s), {cards} live card(s)")
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
            self.push.activity_update(state, event="end", dismiss_in_s=1)
            nxt = ""
            if self.current_plan and self.current_plan.next_water_at:
                nxt = " Next: " + self.current_plan.next_water_at.strftime(
                    "%a %d %b, %I:%M %p")
            alerts = self.push.notify(
                "Watering finished" if not stopped else "Watering stopped",
                ("The garden has been watered." if not stopped
                 else "Stopped by request.") + nxt)
            if not alerts:
                self.store.log("SYSTEM",
                               "Watering ended but no phone accepted the alert",
                               is_error=True)
        except Exception as e:
            self.store.log("SYSTEM", f"Push (end) failed: {e}", is_error=True)

    # ---- periodic work ----------------------------------------------------------
    def recompute_plan(self):
        now = datetime.now(self.tz)
        snap = self.hardware.snapshot()
        soil_pct = self.config.soil_raw_to_pct(snap.get("soil_raw", -1))
        self.current_weather = self.weather_svc.get()
        obs = self.vision.fresh(now) if self.vision else None
        # Track how long soil has been the thing holding watering back, so a
        # probe that never comes down can't block forever.
        blocking = (soil_pct is not None
                    and soil_pct >= self.config.soil_skip_above_pct)
        if blocking:
            self._soil_block_since = self._soil_block_since or now
        else:
            self._soil_block_since = None
        block_h = ((now - self._soil_block_since).total_seconds() / 3600.0
                   if self._soil_block_since else 0.0)
        drying = (soil_pct is not None
                  and soil_pct <= self.config.soil_water_below_pct)
        self._soil_dry_since = (self._soil_dry_since or now) if drying else None
        dry_min = ((now - self._soil_dry_since).total_seconds() / 60.0
                   if self._soil_dry_since else 0.0)
        self.current_plan = compute_plan(
            self.config, now, soil_pct, self.current_weather,
            self.store.last_watering_end(),
            vision=obs,
            vision_wet_hours=self.vision.wet_hours(now) if self.vision else 0.0,
            soil_expected=self.config.soil_enabled,
            soil_block_hours=block_h,
            soil_dry_minutes=dry_min,
        )

    def sensors_ready(self) -> bool:
        """Has enough arrived to decide anything?

        Straight after a restart the hub knows nothing: no telemetry, no
        soil, no weather. Acting then means acting on absence, which is how
        a saturated garden got watered because a fitted probe had not
        reported yet. Wait for the sensors to speak first.
        """
        snap = self.hardware.snapshot()
        if snap.get("mcu_seen_seconds_ago") is None:
            return False
        if self.config.soil_enabled and snap.get("soil_raw", -1) < 0:
            return False
        return True

    def preslot_check_due(self, now: datetime) -> bool:
        """One extra look shortly before a watering is due.

        The ambient look runs every half hour, so without this a slot could
        be decided on a reading old enough for the sky to have changed. This
        makes the last word on a watering a genuinely current one.

        Marks the slot as checked as a side effect, so the window produces
        exactly one look however often the tick asks.
        """
        if not self.vision or not self.vision.configured:
            return False
        if not self.vision.daylight(now):
            return False
        plan = self.current_plan
        if plan is None or plan.water_now or plan.next_water_at is None:
            return False
        lead_min = (plan.next_water_at - now).total_seconds() / 60.0
        if not 0 <= lead_min <= self.config.vision_preslot_min:
            return False
        if self._preslot_checked_for == plan.next_water_at:
            return False
        self._preslot_checked_for = plan.next_water_at
        return True

    def look_at_garden(self, why: str = "scheduled"):
        """Take a fresh look and re-plan on what it saw."""
        if not self.vision:
            return None
        obs = self.vision.observe(datetime.now(self.tz), why)
        if obs is not None:
            self.recompute_plan()
        return obs


def main():
    ctx = AppContext()
    ui = WebUI()
    ts = TimeSeriesStore()
    ts.start()

    # Everything optional starts off the critical path, on purpose.
    #
    # Building the LLM brick reaches out to the model runner, which sometimes
    # takes seconds and sometimes minutes — and while it blocked here, the
    # dashboard, the API and the watering scheduler were all unavailable.
    # Watering must never wait on a chatbot, a camera or a push key. Each of
    # these can fail or hang without the hub noticing; every consumer already
    # treats them as optional (None until ready, forever if they never come).
    def start_assistant():
        from assistant import Assistant
        ctx.assistant = Assistant(ctx)
        ctx.store.log("SYSTEM", "On-board assistant ready (local LLM)")

    def start_camera():
        from camera import CameraService
        ctx.camera = CameraService(ctx.config)
        # Vision needs the camera, so it is built here rather than racing it.
        from vision import VisionService
        ctx.vision = VisionService(ctx, log=ctx.store.log)

    def start_push():
        from push import PushService
        ctx.push = PushService(ctx.config, ctx.store, log=ctx.store.log)

    def start_relay():
        from relay import CameraRelay
        ctx.relay = CameraRelay(ctx.config, log=ctx.store.log)
        ctx.relay.start_async()

    def start_service(name: str, fn):
        def run():
            try:
                fn()
            except Exception as e:
                ctx.store.log("SYSTEM", f"{name} unavailable: {e}", is_error=True)
        threading.Thread(target=run, name=f"init-{name}", daemon=True).start()

    start_service("Assistant", start_assistant)
    start_service("Camera service", start_camera)
    start_service("Push service", start_push)
    start_service("Camera relay", start_relay)

    api.register(ui, ctx)

    ctx.store.log("SYSTEM", "Plant Intelligence hub started")
    # The watchdog restarts us from outside the container, so it leaves a
    # note behind rather than trying to write to the database itself.
    _flag = os.path.expanduser("~/.mcu-watchdog-restarted")
    if os.path.exists(_flag):
        try:
            os.remove(_flag)
        except OSError:
            pass
        ctx.store.log("SYSTEM",
                      "Restarted automatically: the MCU had stopped accepting "
                      "commands", is_error=True)
    gone = ctx.store.push_token_prune()
    if gone:
        ctx.store.log("SYSTEM", f"Forgot {gone} phone token(s) that stopped checking in")
    stale = ctx.store.close_stale_open_rows()
    if stale:
        ctx.store.log("SYSTEM", f"Closed {stale} watering record(s) left open by a restart")
    # The MCU may still be booting; if it doesn't take the setting now, the
    # loop retries and it keeps its own compiled-in default meanwhile.
    failsafe_set = ctx.hardware.set_failsafe_hours(ctx.config.failsafe_silence_h)
    located = ctx.try_autolocate()
    ctx.recompute_plan()

    last = {"ping": 0.0, "telemetry": 0.0, "samples": 0.0, "plan": 0.0,
            "locate": time.time(), "leds": 0.0, "vision": 0.0, "due": 0.0,
            "mcu_alarm": 0.0}
    alarm = {"pushed": False}
    # ---- the scheduler, and how it recovers from itself ---------------------
    #
    # The work runs on a worker thread rather than on App.run's own loop, and
    # App.run's loop supervises it. If a tick wedges on something with no
    # deadline, Python cannot kill that thread, but it can be abandoned and
    # replaced, which is the difference between a hub that comes back by
    # itself and one that looks alive for eighteen hours while deciding
    # nothing. Each hang leaks one parked thread; that is a cheap price.
    heartbeat = {"tick": time.time(), "warned": False, "restarts": 0}
    STALL_S = 120

    def scheduler(token: dict):
        last_fault = [""]
        while not token["retired"]:
            try:
                tick()
                heartbeat["tick"] = time.time()
                last_fault[0] = ""
            except Exception as e:
                # A tick that fails usually fails every second; say it once
                # per distinct fault rather than a thousand times an hour.
                fault = repr(e)
                if fault != last_fault[0]:
                    last_fault[0] = fault
                    ctx.store.log("SYSTEM", f"Scheduler tick failed: {fault}",
                                  is_error=True)
            time.sleep(1)

    worker = {"retired": False}

    def loop():
        nonlocal worker
        time.sleep(5)
        stalled = time.time() - heartbeat["tick"]
        if stalled <= STALL_S:
            if heartbeat["warned"]:
                heartbeat["warned"] = False
                ctx.store.log("SYSTEM", "Scheduler is ticking again")
            return

        heartbeat["warned"] = True
        heartbeat["restarts"] += 1
        ctx.store.log("SYSTEM",
                      f"Scheduler stalled for {stalled:.0f}s, starting a "
                      f"replacement (restart #{heartbeat['restarts']})",
                      is_error=True)
        worker["retired"] = True     # the old one stops if it ever returns
        worker = {"retired": False}
        heartbeat["tick"] = time.time()
        threading.Thread(target=scheduler, args=(worker,),
                         name="scheduler", daemon=True).start()
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
            if not ctx.hardware.set_led_mode(mode):
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

    def tick():
        nonlocal located, failsafe_set
        now = time.time()

        if now - last["ping"] >= 30:
            last["ping"] = now
            if not failsafe_set:
                failsafe_set = ctx.hardware.set_failsafe_hours(
                    ctx.config.failsafe_silence_h)
            if not ctx.hardware.ping():
                fails, err = ctx.hardware.rpc_health()
                down = ctx.hardware.rpc_down_seconds()
                # This used to log at exactly 3 and 30 failures and then go
                # quiet. It once failed ten thousand times over two days in
                # total silence while the MCU watered on its own failsafe,
                # so now it keeps saying so, and tells the phone once.
                if fails == 3 or (down > 300 and time.time() - last["mcu_alarm"] > 900):
                    last["mcu_alarm"] = time.time()
                    ctx.store.log("SYSTEM",
                                  f"Cannot command the MCU: {fails} failures over "
                                  f"{down/60:.0f} min. Telemetry still arriving, but "
                                  f"watering commands are not landing — {err}",
                                  is_error=True)
                    if down > 300 and ctx.push and not alarm["pushed"]:
                        alarm["pushed"] = True
                        try:
                            ctx.push.notify(
                                "Hub cannot reach the controller",
                                "Sensor data is still arriving but watering "
                                "commands are not. The board's own failsafe "
                                "will water if this continues.",
                                interruption="time-sensitive")
                        except Exception:
                            pass
            elif alarm["pushed"] or last["mcu_alarm"]:
                alarm["pushed"] = False
                last["mcu_alarm"] = 0.0
                ctx.store.log("SYSTEM", "MCU is accepting commands again")

        if now - last["leds"] >= 2:
            last["leds"] = now
            service_leds()

        # A look at the garden takes several seconds against a cloud model,
        # so it runs off the tick — a watering must never wait behind it.
        # Checked every 20 s so the narrow pre-watering window isn't missed.
        if now - last["vision"] >= 20:
            last["vision"] = now
            if ctx.vision and not ctx.vision.busy:
                local = datetime.now(ctx.tz)
                why = ("before watering" if ctx.preslot_check_due(local)
                       else "scheduled" if ctx.vision.due(local) else None)
                if why:
                    threading.Thread(target=ctx.look_at_garden, args=(why,),
                                     name="vision-look", daemon=True).start()

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

        # The instant a planned watering comes due, re-plan rather than
        # waiting out the rest of the 5-minute cycle. Without this a 17:00
        # slot could start at 17:04, and the pre-watering camera check would
        # have been for nothing.
        plan = ctx.current_plan
        if (now - last["due"] >= 10 and plan and not plan.water_now
                and plan.next_water_at
                and datetime.now(ctx.tz) >= plan.next_water_at):
            last["due"] = now
            last["plan"] = now
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

    # Started here, not where `scheduler` is defined: `tick` is a closure
    # defined below, and launching the thread before that binding exists
    # raised NameError once a second with nothing scheduling anything.
    threading.Thread(target=scheduler, args=(worker,),
                     name="scheduler", daemon=True).start()

    App.run(user_loop=loop)


main()
