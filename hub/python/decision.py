"""The watering decision engine.

Pure logic, no I/O: given the current soil reading, a weather summary, and
when the garden was last watered, produce a plan — should we water right
now, for how long, and if not, when do we expect to next.

Two modes, chosen by whether the soil probe is reporting:

  no probe  — fixed daily slots (07:00 and 17:00), the rhythm the old ESP32
              system ran on. Weather can still shorten a dose or skip a slot
              it would only waste, but it never moves the clock.
  with probe — the cadence is predicted, not fixed: the interval between
              waterings stretches and shrinks with soil moisture and weather.

The split is deliberate. Guessing an interval from the forecast alone is a
guess dressed up as a decision; once the probe can say the soil is dry, the
adaptive cadence has something real to stand on and switches on by itself.
Either way the duration scales with how hot the day actually is, and every
plan carries a human-readable list of the factors that produced it, which
the app surfaces as "why".
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

    def to_dict(self) -> dict:
        return {
            "water_now": self.water_now,
            "duration_s": self.duration_s,
            "next_water_at": self.next_water_at.isoformat() if self.next_water_at else None,
            "interval_h": round(self.interval_h, 1),
            "reasons": self.reasons,
        }


def _parse_hhmm(s: str) -> dtime:
    h, m = s.split(":")
    return dtime(int(h), int(m))


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
    reasons: list,
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

    reasons.append("fixed schedule (" + ", ".join(_slot_label(s) for s in slots) +
                   "): no soil probe yet, so the clock decides")

    if past:
        slot = past[-1]
        late_min = int((now - slot).total_seconds() // 60)
        # A watering that ended just before the slot counts as serving it —
        # otherwise a manual run at 06:50 would be followed by the 07:00 one.
        served = (last_watering_end is not None
                  and last_watering_end >= slot - timedelta(hours=1))
        if served:
            pass
        elif late_min > cfg.fixed_catchup_min:
            reasons.append(f"the {_slot_label(slot)} slot was missed by "
                           f"{late_min} min: waiting for the next one")
        elif rain_expected:
            reasons.append(f"skipping the {_slot_label(slot)} slot: rain is "
                           "doing the watering")
        else:
            reasons.append(f"the {_slot_label(slot)} watering is due")
            return Plan(True, duration_s, None, interval_h, reasons)

    reasons.append(f"next slot at {_slot_label(next_at)}")
    return Plan(False, duration_s, next_at, interval_h, reasons)


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
) -> Plan:
    reasons: list = []
    interval_h = cfg.base_interval_h
    duration = float(cfg.base_duration_s)

    # No moisture reading → the clock decides when, weather only decides how
    # much. Calibrating the probe switches the adaptive cadence back on.
    fixed = soil_pct is None and cfg.fixed_when_no_soil and bool(cfg.fixed_times)

    # ---- weather shapes the dose, and (adaptive mode only) the cadence -------
    rain_expected = False
    if weather is not None:
        t = weather.temp_max_next12h
        if t is not None:
            if t >= cfg.very_hot_day_c:
                interval_h *= 0.6
                duration *= 1.4
                reasons.append(f"very hot ({t:.0f}°C max): watering longer" if fixed
                               else f"very hot ({t:.0f}°C max): watering more often, longer")
            elif t >= cfg.hot_day_c:
                interval_h *= 0.75
                duration *= 1.2
                reasons.append(f"hot ({t:.0f}°C max): watering a little longer" if fixed
                               else f"hot ({t:.0f}°C max): watering more often, a little longer")
            elif t <= cfg.cool_day_c:
                interval_h *= 1.3
                duration *= 0.8
                reasons.append(f"cool ({t:.0f}°C max): watering shorter" if fixed
                               else f"cool ({t:.0f}°C max): watering less often, shorter")

        p = weather.precip_prob_max_next12h
        if p is not None and p >= cfg.rain_skip_probability:
            interval_h *= 2.0
            duration *= 0.7
            rain_expected = True
            reasons.append(f"rain likely ({p:.0f}% in next 12 h)" if fixed else
                           f"rain likely ({p:.0f}% in next 12 h): postponing, "
                           "rain will do the work")
        if weather.is_raining_now:
            interval_h *= 2.0
            rain_expected = True
            reasons.append("currently raining: no irrigation needed")
    else:
        reasons.append("no weather data: using the standard dose" if fixed
                       else "no weather data: using neutral cadence")

    # ---- soil overrides the calendar when available ---------------------------
    urgent = False
    if soil_pct is not None:
        if soil_pct >= cfg.soil_skip_above_pct:
            interval_h = max(interval_h, cfg.base_interval_h * 1.5)
            reasons.append(f"soil wet ({soil_pct:.0f}%): postponing")
        elif soil_pct <= cfg.soil_water_below_pct:
            urgent = True
            deficit = (cfg.soil_water_below_pct - soil_pct) / max(cfg.soil_water_below_pct, 1)
            duration *= 1.0 + 0.5 * deficit
            reasons.append(f"soil dry ({soil_pct:.0f}%): watering now")
        else:
            reasons.append(f"soil ok ({soil_pct:.0f}%)")

    interval_h = max(cfg.min_interval_h, min(cfg.max_interval_h, interval_h))
    duration_s = int(max(cfg.min_duration_s, min(cfg.max_duration_s, duration)))

    # History rows are stored in UTC; every comparison below is against a
    # local wall-clock time, or 05:30 becomes 05:30 UTC (11:00 in Kolkata).
    if last_watering_end is not None and now.tzinfo is not None:
        last_watering_end = last_watering_end.astimezone(now.tzinfo)

    if fixed:
        return _plan_fixed(cfg, now, duration_s, rain_expected,
                           last_watering_end, reasons)

    # ---- when is the next watering due? ---------------------------------------
    if last_watering_end is None:
        # Never watered. Normally that means "due immediately" — but with no
        # anchor to postpone from, rain must block explicitly, or a fresh
        # install waters straight into a storm.
        if rain_expected:
            due_at = now + timedelta(hours=6)
            reasons.append("no watering on record, but rain expected: checking again later")
        else:
            due_at = now
            reasons.append("no watering on record yet")
    else:
        due_at = last_watering_end + timedelta(hours=interval_h)
        # Rain trumps the calendar. However overdue the schedule is, watering
        # into rain wastes water — keep pushing the due time while a storm is
        # here or inbound. A genuinely dry soil reading (urgent) still wins.
        if rain_expected and now >= due_at:
            due_at = now + timedelta(hours=6)
            reasons.append("overdue, but rain is handling it: checking again later")

    due_at = _snap_into_window(due_at, cfg)
    in_window = _parse_hhmm(cfg.window_start) <= now.time() <= _parse_hhmm(cfg.window_end)

    if urgent and in_window:
        return Plan(True, duration_s, None, interval_h, reasons)

    if now >= due_at and in_window:
        reasons.append("cadence interval elapsed")
        return Plan(True, duration_s, None, interval_h, reasons)

    if urgent and not in_window:
        reasons.append("soil dry but outside watering window: waiting for window")

    return Plan(False, duration_s, due_at, interval_h, reasons)
