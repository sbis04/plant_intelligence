"""The watering decision engine.

Pure logic, no I/O: given the current soil reading, a weather summary, and
when the garden was last watered, produce a plan — should we water right
now, for how long, and if not, when do we expect to next.

The cadence is *predicted*, not fixed. The old system watered at 07:00 and
17:00 for exactly 5 minutes regardless of conditions. Here the interval
between waterings stretches and shrinks with the weather (and with soil
moisture once the probe is installed), and the duration scales with how
hot/dry the day actually is. Every plan carries a human-readable list of
the factors that produced it, which the app surfaces as "why".
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

    # ---- weather shapes both cadence and dose --------------------------------
    rain_expected = False
    if weather is not None:
        t = weather.temp_max_next12h
        if t is not None:
            if t >= cfg.very_hot_day_c:
                interval_h *= 0.6
                duration *= 1.4
                reasons.append(f"very hot ({t:.0f}°C max): watering more often, longer")
            elif t >= cfg.hot_day_c:
                interval_h *= 0.75
                duration *= 1.2
                reasons.append(f"hot ({t:.0f}°C max): watering more often, a little longer")
            elif t <= cfg.cool_day_c:
                interval_h *= 1.3
                duration *= 0.8
                reasons.append(f"cool ({t:.0f}°C max): watering less often, shorter")

        p = weather.precip_prob_max_next12h
        if p is not None and p >= cfg.rain_skip_probability:
            interval_h *= 2.0
            duration *= 0.7
            rain_expected = True
            reasons.append(f"rain likely ({p:.0f}% in next 12 h): postponing, rain will do the work")
        if weather.is_raining_now:
            interval_h *= 2.0
            rain_expected = True
            reasons.append("currently raining: no irrigation needed")
    else:
        reasons.append("no weather data: using neutral cadence")

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

    # ---- when is the next watering due? ---------------------------------------
    # History rows are stored in UTC; window snapping must happen in the
    # garden's local time or 05:30 becomes 05:30 UTC (11:00 in Kolkata).
    if last_watering_end is not None and now.tzinfo is not None:
        last_watering_end = last_watering_end.astimezone(now.tzinfo)

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
