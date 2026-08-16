"""The watering decision engine.

Pure logic, no I/O: given the current soil reading, a weather summary, and
when the garden was last watered, produce a plan — should we water right
now, for how long, and if not, when do we expect to next.

Two modes, chosen by whether the soil probe is reporting:

  no probe  — fixed daily slots (07:00 and 17:00) for a flat 5 minutes, the
              rhythm the old ESP32 system ran on. Weather's only say is
              skipping a slot the rain is already covering.
  with probe — the cadence is predicted, not fixed: the interval between
              waterings stretches and shrinks with soil moisture and
              weather, and the dose scales with how hot the day is.

The split is deliberate. Guessing an interval from the forecast alone is a
guess dressed up as a decision; once the probe can say the soil is dry, the
adaptive cadence has something real to stand on and switches on by itself.
Either way every plan carries a human-readable list of the factors that
produced it, which the app surfaces as "why".
"""

from dataclasses import dataclass, field
from datetime import datetime, timedelta, time as dtime
from typing import Optional

from config import Config
from weather import WeatherSummary


@dataclass
class Plan:
    water_now: bool
    duration_s: int
    next_water_at: Optional[datetime]   # prediction (None only if watering now)
    interval_h: float                   # the computed cadence
    reasons: list = field(default_factory=list)
    mode: str = "adaptive"              # "fixed" while there is no soil probe
    schedule: str = ""                  # fixed mode: "7:00 AM, 5:00 PM"
    headline: str = ""                  # the decision, in one sentence
    status: str = "scheduled"           # machine-readable; see Why.STATUSES

    def to_dict(self) -> dict:
        return {
            "water_now": self.water_now,
            "duration_s": self.duration_s,
            "next_water_at": self.next_water_at.isoformat() if self.next_water_at else None,
            "interval_h": round(self.interval_h, 1),
            "reasons": self.reasons,
            "mode": self.mode,
            "schedule": self.schedule,
            "headline": self.headline,
            "status": self.status,
        }


class Why:
    """The facts behind a plan, collected so the decision can come first.

    The reasons list used to be an append-as-you-go pile: six bullets in
    which three said "it is raining" in different words, one repeated the
    schedule shown directly beside it, one repeated the next slot time shown
    directly above it, and the actual decision sat fifth. Grouping the facts
    by source means each one is stated once, in a fixed order, led by what
    the system is actually doing.

    Deliberately absent: the schedule and the next slot time. Both are
    already on screen next to this list, and repeating them was most of what
    made it unreadable.
    """

    # What the system is doing. The UI switches on this rather than
    # pattern-matching the prose, which is how "Waiting out the rain" ended
    # up showing for plans that had nothing to do with rain.
    STATUSES = ("due", "rain_hold", "already_wet", "missed", "done",
                "soil_hold", "scheduled")

    def __init__(self):
        self.decision = ""
        self.camera = ""
        self.weather = ""
        self.soil = ""
        self.status = "scheduled"

    def decide(self, status: str, sentence: str):
        self.status = status
        self.decision = sentence

    def to_list(self) -> list:
        return [t for t in (self.decision, self.camera, self.weather, self.soil) if t]


def _parse_hhmm(s: str) -> dtime:
    h, m = s.split(":")
    return dtime(int(h), int(m))


def _apply_vision(cfg: Config, obs, rain_expected: bool, wet_hours: float,
                  why: "Why") -> tuple:
    """Let the camera correct the forecast.

    Returns (rain_expected, force, skip_note) — the note being how to phrase
    a skip, since "rain is doing the watering" is a lie when what the camera
    actually saw was someone with a hose.

    The camera outranks the forecast on principle: the forecast describes a
    city, the camera is pointed at the actual roof we are deciding about.

    The two directions are deliberately NOT symmetric, because the mistakes
    are not symmetric. Being wrongly told "it's dry" costs a few litres of
    water. Being wrongly told "it's already wet" costs a watering, and in a
    40 °C week that costs plants. So a dry reading may cancel a forecast
    skip freely, while a wet reading may only cause a skip for so long
    before we water regardless and stop believing it.
    """
    if obs.raining_now:
        why.camera = "Camera: rain falling on the roof"
        return True, False, ("rain_hold", "rain is doing the watering")

    if obs.is_wet and cfg.vision_may_skip:
        if wet_hours > cfg.vision_max_wet_hours:
            why.camera = (f"Camera: reading the roof wet for {wet_hours:.0f} h "
                          "straight, which looks stuck, so watering anyway")
            return False, True, None
        if obs.wetness_source == "watering":
            why.camera = ("Camera: wet around the pots but dry further out, "
                          "so the garden has been watered")
            return True, False, ("already_wet", "the garden has already been watered")
        if obs.wetness_source == "rain":
            why.camera = "Camera: the roof is wet from rain"
            return True, False, ("rain_hold", "rain is doing the watering")
        why.camera = f"Camera: the roof is {obs.ground}"
        return True, False, ("already_wet", "the roof is already wet")

    # The roof isn't wet enough to skip on. Now see whether the forecast's
    # rain claim survives contact with the actual roof.
    if rain_expected and not obs.raining_now:
        if obs.is_dry:
            why.camera = ("Camera: the roof is dry, so the forecast rain "
                          "hasn't arrived here")
            rain_expected = False
        elif obs.light == "direct_sun":
            # Crisp shadows and "it is raining right now" cannot both be true.
            why.camera = ("Camera: direct sunlight on the roof, so the "
                          "forecast rain hasn't arrived here")
            rain_expected = False

    if obs.stressed and not obs.is_wet:
        why.camera = "Camera: the plants are drooping"
        return False, True, None

    if not why.camera:
        why.camera = f"Camera: the roof is {obs.ground}"
    return rain_expected, False, None


def _duration_label(d: timedelta) -> str:
    mins = int(d.total_seconds() // 60)
    if mins < 90:
        return f"{mins} min"
    h, m = divmod(mins, 60)
    return f"{h} h" if m == 0 else f"{h} h {m} min"


def _slot_label(t: datetime) -> str:
    return t.strftime("%I:%M %p").lstrip("0")


def _fixed_slots(cfg: Config, now: datetime) -> list:
    """Today's fixed watering times, ascending, in the garden's local zone."""
    slots = []
    for s in cfg.fixed_times:
        try:
            t = _parse_hhmm(s)
        except (ValueError, AttributeError):
            continue    # a malformed entry shouldn't take the schedule down
        slots.append(now.replace(hour=t.hour, minute=t.minute,
                                 second=0, microsecond=0))
    return sorted(slots)


def _plan_fixed(
    cfg: Config,
    now: datetime,
    duration_s: int,
    rain_expected: bool,
    last_watering_end: Optional[datetime],
    why: "Why",
    force: bool = False,
    skip: tuple = ("rain_hold", "rain is doing the watering"),
) -> Plan:
    """Fixed daily slots — used until the soil probe is calibrated.

    A slot fires if it has passed, hasn't been served yet, and wasn't missed
    by more than the catch-up grace (so a hub that boots at noon doesn't
    immediately water for a 07:00 slot it slept through).
    """
    slots = _fixed_slots(cfg, now)
    upcoming = [s for s in slots if s > now]
    past = [s for s in slots if s <= now]
    next_at = upcoming[0] if upcoming else slots[0] + timedelta(days=1)
    interval_h = 24.0 / len(slots)
    schedule = ", ".join(_slot_label(s) for s in slots)

    def plan(water_now, next_water_at):
        return Plan(water_now, duration_s, next_water_at, interval_h,
                    why.to_list(), mode="fixed", schedule=schedule,
                    headline=why.decision, status=why.status)

    if past:
        slot = past[-1]
        label = _slot_label(slot)
        late = now - slot
        # A watering that ended just before the slot counts as serving it,
        # otherwise a manual run at 06:50 would be followed by the 07:00 one.
        served = (last_watering_end is not None
                  and last_watering_end >= slot - timedelta(hours=1))
        if served:
            why.decide("done", f"The {label} watering is done")
        elif late > timedelta(minutes=cfg.fixed_catchup_min):
            why.decide("missed",
                       f"Missed the {label} watering by {_duration_label(late)}, "
                       "so waiting for the next one")
        elif rain_expected and not force:
            why.decide(skip[0], f"Skipping the {label} watering: {skip[1]}")
        else:
            why.decide("due", f"Watering now: the {label} slot is due")
            return plan(True, None)
    else:
        why.decide("scheduled", f"Waiting for the {_slot_label(next_at)} watering")

    return plan(False, next_at)


def _snap_into_window(t: datetime, cfg: Config) -> datetime:
    """Move a proposed watering time into the allowed local-time window."""
    start, end = _parse_hhmm(cfg.window_start), _parse_hhmm(cfg.window_end)
    if t.time() < start:
        return t.replace(hour=start.hour, minute=start.minute, second=0)
    if t.time() > end:
        nxt = t + timedelta(days=1)
        return nxt.replace(hour=start.hour, minute=start.minute, second=0)
    return t


def compute_plan(
    cfg: Config,
    now: datetime,                      # tz-aware, garden-local
    soil_pct: Optional[float],
    weather: Optional[WeatherSummary],
    last_watering_end: Optional[datetime],
    vision=None,                        # vision.Observation, if recent enough
    vision_wet_hours: float = 0.0,
) -> Plan:
    why = Why()
    interval_h = cfg.base_interval_h
    duration = float(cfg.base_duration_s)

    # No moisture reading → fixed slots, flat dose. Weather's only remaining
    # say is skipping a slot rain would waste. Calibrating the probe switches
    # the adaptive cadence back on by itself.
    fixed = soil_pct is None and cfg.fixed_when_no_soil and bool(cfg.fixed_times)

    # ---- weather shapes the cadence and the dose (adaptive mode only) --------
    # Everything the forecast has to say lands on ONE line. Three separate
    # bullets all meaning "it might rain" was most of the old confusion.
    rain_expected = False
    bits = []
    if weather is not None:
        t = weather.temp_max_next12h
        if t is not None and not fixed:
            if t >= cfg.very_hot_day_c:
                interval_h *= 0.6
                duration *= 1.4
                bits.append(f"very hot ({t:.0f}°C max), watering more often and longer")
            elif t >= cfg.hot_day_c:
                interval_h *= 0.75
                duration *= 1.2
                bits.append(f"hot ({t:.0f}°C max), watering more often")
            elif t <= cfg.cool_day_c:
                interval_h *= 1.3
                duration *= 0.8
                bits.append(f"cool ({t:.0f}°C max), watering less often")

        p = weather.precip_prob_max_next12h
        if p is not None and p >= cfg.rain_skip_probability:
            interval_h *= 2.0
            duration *= 0.7
            rain_expected = True
            bits.append(f"rain {p:.0f}% likely in the next 12 h")
        if weather.is_raining_now:
            interval_h *= 2.0
            rain_expected = True
            bits.append("reported raining now")
        if bits:
            why.weather = "Forecast: " + ", ".join(bits)
    else:
        why.weather = "Forecast: unavailable"

    # ---- the camera gets the last word on the weather -------------------------
    force = False
    skip = ("rain_hold", "rain is doing the watering")
    if vision is not None:
        rain_expected, force, verdict = _apply_vision(
            cfg, vision, rain_expected, vision_wet_hours, why)
        skip = verdict or skip

    # ---- soil overrides the calendar when available ---------------------------
    urgent = False
    if soil_pct is not None:
        if soil_pct >= cfg.soil_skip_above_pct:
            interval_h = max(interval_h, cfg.base_interval_h * 1.5)
            why.soil = f"Soil: wet ({soil_pct:.0f}%), postponing"
        elif soil_pct <= cfg.soil_water_below_pct:
            urgent = True
            deficit = (cfg.soil_water_below_pct - soil_pct) / max(cfg.soil_water_below_pct, 1)
            duration *= 1.0 + 0.5 * deficit
            why.soil = f"Soil: dry ({soil_pct:.0f}%)"
        else:
            why.soil = f"Soil: {soil_pct:.0f}%"

    if fixed:
        # Flat dose — a plain 5 minutes, exactly what the old system ran.
        # The rain multiplier above only survives as the slot-skip signal.
        duration = float(cfg.base_duration_s)

    interval_h = max(cfg.min_interval_h, min(cfg.max_interval_h, interval_h))
    duration_s = int(max(cfg.min_duration_s, min(cfg.max_duration_s, duration)))

    # History rows are stored in UTC; every comparison below is against a
    # local wall-clock time, or 05:30 becomes 05:30 UTC (11:00 in Kolkata).
    if last_watering_end is not None and now.tzinfo is not None:
        last_watering_end = last_watering_end.astimezone(now.tzinfo)

    if fixed:
        return _plan_fixed(cfg, now, duration_s, rain_expected,
                           last_watering_end, why, force, skip)

    # Visibly drooping plants are as good a reason as a dry probe reading.
    urgent = urgent or force

    # ---- when is the next watering due? ---------------------------------------
    postponed = False
    if last_watering_end is None:
        # Never watered. Normally that means "due immediately", but with no
        # anchor to postpone from, rain must block explicitly, or a fresh
        # install waters straight into a storm.
        if rain_expected:
            due_at = now + timedelta(hours=6)
            postponed = True
        else:
            due_at = now
    else:
        due_at = last_watering_end + timedelta(hours=interval_h)
        # Rain trumps the calendar. However overdue the schedule is, watering
        # into rain wastes water, so keep pushing the due time while a storm
        # is here or inbound. A genuinely dry soil reading (urgent) still wins.
        if rain_expected and now >= due_at:
            due_at = now + timedelta(hours=6)
            postponed = True

    due_at = _snap_into_window(due_at, cfg)
    in_window = _parse_hhmm(cfg.window_start) <= now.time() <= _parse_hhmm(cfg.window_end)

    def plan(water_now, next_water_at):
        return Plan(water_now, duration_s, next_water_at, interval_h,
                    why.to_list(), headline=why.decision, status=why.status)

    if urgent and in_window:
        why.decide("due", "Watering now: the garden needs it")
        return plan(True, None)

    if now >= due_at and in_window:
        why.decide("due", "Watering now: the interval since the last one has elapsed")
        return plan(True, None)

    if urgent and not in_window:
        why.decide("scheduled",
                   "The garden needs water, but it is outside the watering "
                   "window, so waiting for it to open")
    elif postponed:
        why.decide(skip[0], f"Postponing the watering: {skip[1]}")
    elif soil_pct is not None and soil_pct >= cfg.soil_skip_above_pct:
        why.decide("soil_hold", "Holding off: the soil is still wet")
    else:
        why.decide("scheduled", "Waiting for the next watering")

    return plan(False, due_at)
