"""What the garden actually looks like, as opposed to what the forecast says.

The forecast is city-level: it is wrong about one rooftop often enough that
acting on it alone wastes water and, worse, skips waterings the plants
needed. The camera is already pointed at the thing we are making decisions
about, so this asks Gemini to read the frame and report the conditions it
can genuinely see.

What the view supports, and why each signal is readable:

  ground      Bare concrete is a good wetness gauge — wet concrete is
              markedly darker, standing water throws specular highlights.
  raining_now Falling rain streaks, ripples in puddles, veiling haze.
  light       Shadow hardness: crisp shadows = sun, flat grey = overcast.
  plants      Leaf posture — turgid and upright, or drooping and limp.
  wetness_source  Rain wets *everything*, right out to the parapet and the
              corners far from any pot. Hand watering and the irrigation
              system wet a halo around the pots and leave the outer terrace
              pale and dry. That spatial difference is the whole trick.

Two things make the source call much more reliable than a bare guess:

  - The hub knows with certainty when it watered, so that possibility is
    resolved from the database rather than from pixels, and the model is
    told the answer instead of having to infer it.
  - The forecast is deliberately NOT shown to the model. The entire point
    is an independent second opinion; feeding it the forecast would just
    invite it to agree with the thing we already distrust.

Observations are advisory input to the decision engine, never a command —
see decision.py for how far they are allowed to move a watering, and the
deliberate asymmetry between letting one happen and calling one off.
"""

import base64
import json
import threading
import urllib.error
import urllib.request
from dataclasses import dataclass, asdict
from datetime import datetime, timedelta
from typing import Optional

PROMPT = """You are the eyes of an automated rooftop irrigation system.
The camera is fixed and looks DOWN at a flat concrete roof terrace holding
potted plants. Report only what you can genuinely see in THIS frame.

How to read this particular view:
- The bare concrete floor is the main wetness gauge. Wet concrete is clearly
  DARKER; standing water shows bright specular highlights and sharp-edged
  puddles. Old stains and mould are dark too, but they have fixed irregular
  shapes and dry edges - do not call those wet.
- Soil surface in the pots: freshly watered soil is near-black and evenly
  dark; dry soil is pale grey-brown, often cracked or dusty.
- Rain falling is visible as streaks, ripples in puddles, or a general
  veiling haze, and the whole scene loses contrast.
- Shadows tell you the light: crisp dark shadows = direct sun; no shadows
  and flat grey light = overcast; scene very dark = night or storm.
- Leaf posture: turgid upright leaves = fine; drooping, curled or limp
  leaves hanging down = water stress.

If the roof IS wet, decide what wet it. This distinction matters more than
anything else you report, so weigh it carefully:
- RAIN falls on everything. The whole floor darkens evenly right out to the
  corners, the parapet wall and surfaces far from any pot. Wetness that
  respects no boundary and covers areas no hose would reach is rain.
- WATERING wets a patch. Dark soil in the pots, wet concrete in a halo or
  runoff trail around them, while concrete far from the plants stays pale
  and dry. Wetness that is clearly organised around the plants is watering.
%s

Be conservative and prefer "unclear" to a guess. State your confidence
honestly: a wrong "the roof is already wet" reading means the plants go
unwatered through a hot day, which is the costliest mistake you can make.
"""

SCHEMA = {
    "type": "object",
    "properties": {
        "ground": {"type": "string",
                   "enum": ["dry", "damp", "wet", "puddles", "unclear"]},
        "raining_now": {"type": "boolean"},
        "light": {"type": "string",
                  "enum": ["direct_sun", "hazy", "overcast", "dark", "unclear"]},
        "plants": {"type": "string",
                   "enum": ["healthy", "slightly_wilted", "wilting", "unclear"]},
        "wetness_source": {"type": "string",
                           "enum": ["rain", "watering", "none", "unclear"]},
        "confidence": {"type": "number"},
        "note": {"type": "string"},
    },
    "required": ["ground", "raining_now", "light", "plants", "wetness_source",
                 "confidence", "note"],
}


@dataclass
class Observation:
    at: datetime
    ground: str = "unclear"
    raining_now: bool = False
    light: str = "unclear"
    plants: str = "unclear"
    wetness_source: str = "unclear"
    confidence: float = 0.0
    note: str = ""
    # What the previous look reported. A single "dry" frame between wet ones
    # is far more likely to be the model misreading dark weathered concrete
    # than a roof that dried in half an hour, so the decision engine treats
    # an unconfirmed flip as no opinion rather than as evidence.
    prev_ground: str = ""

    # ---- derived meaning, so the decision engine doesn't re-derive it -------
    @property
    def is_wet(self) -> bool:
        return self.ground in ("wet", "puddles")

    @property
    def is_dry(self) -> bool:
        return self.ground == "dry"

    @property
    def stressed(self) -> bool:
        return self.plants in ("wilting", "slightly_wilted")

    def age_minutes(self, now: datetime) -> float:
        return (now - self.at).total_seconds() / 60.0

    def to_dict(self) -> dict:
        d = asdict(self)
        d["at"] = self.at.isoformat()
        return d


class VisionService:
    """Looks at the garden on a schedule, and on demand before a decision."""

    def __init__(self, ctx, log=None):
        self.ctx = ctx
        self._log = log or (lambda *a, **k: None)
        self._lock = threading.Lock()
        self._latest: Optional[Observation] = None
        self._last_attempt: Optional[datetime] = None
        # When the roof first read wet in the current unbroken run. A reading
        # that never clears is far more likely to be a dark stain the model
        # keeps misreading than a roof that stayed soaked for two days, so
        # the decision engine stops trusting it after a while.
        self._wet_since: Optional[datetime] = None
        self.busy = False

    @property
    def configured(self) -> bool:
        cam = getattr(self.ctx, "camera", None)
        return bool(self.ctx.config.cloud_llm_api_key
                    and self.ctx.config.vision_enabled
                    and cam is not None and cam.configured)

    @property
    def latest(self) -> Optional[Observation]:
        with self._lock:
            return self._latest

    def fresh(self, now: datetime) -> Optional[Observation]:
        """The latest observation, or None if it's too old to act on."""
        obs = self.latest
        if obs is None:
            return None
        if obs.age_minutes(now) > self.ctx.config.vision_max_age_min:
            return None
        if obs.confidence < self.ctx.config.vision_min_confidence:
            return None
        return obs

    # ---- scheduling ---------------------------------------------------------
    def daylight(self, now: datetime) -> bool:
        """The night view is infrared and monochrome, which is precisely the
        information wetness lives in. Don't pretend to read it."""
        return (self.ctx.config.vision_hour_start
                <= now.hour < self.ctx.config.vision_hour_end)

    def due(self, now: datetime) -> bool:
        """Regular ambient look, on the configured interval."""
        if not self.configured or not self.daylight(now):
            return False
        if self._last_attempt is None:
            return True
        gap = (now - self._last_attempt).total_seconds() / 60.0
        return gap >= self.ctx.config.vision_interval_min

    # ---- the look -----------------------------------------------------------
    def observe(self, now: datetime, why: str = "scheduled") -> Optional[Observation]:
        if not self.configured:
            return None
        self._last_attempt = now
        self.busy = True
        try:
            obs = self._observe(now, why)
        except Exception as e:
            self._log("VISION", f"Could not read the camera view: {e}", True)
            return None
        finally:
            self.busy = False
        return obs

    def _observe(self, now: datetime, why: str) -> Optional[Observation]:
        jpeg = self.ctx.camera.snapshot()
        if not jpeg:
            self._log("VISION", "No camera frame to look at", True)
            return None
        jpeg = self._shrink(jpeg, self.ctx.config.vision_image_width)

        data = self._ask_gemini(jpeg, self._system_watering_context(now))
        obs = Observation(
            at=now,
            ground=str(data.get("ground", "unclear")),
            raining_now=bool(data.get("raining_now", False)),
            light=str(data.get("light", "unclear")),
            plants=str(data.get("plants", "unclear")),
            wetness_source=str(data.get("wetness_source", "unclear")),
            confidence=float(data.get("confidence", 0.0) or 0.0),
            note=str(data.get("note", ""))[:300],
        )
        with self._lock:
            previous = self._latest
            obs.prev_ground = previous.ground if previous else ""
            self._latest = obs
            if obs.is_wet:
                self._wet_since = self._wet_since or now
            else:
                self._wet_since = None
        self._record(obs, previous, why)
        return obs

    def wet_hours(self, now: datetime) -> float:
        """How long the roof has been reading wet without a break."""
        with self._lock:
            since = self._wet_since
        if since is None:
            return 0.0
        return max(0.0, (now - since).total_seconds() / 3600.0)

    def _system_watering_context(self, now: datetime) -> str:
        """Resolve our own irrigation from the database, not from pixels.

        Wet concrete has three possible causes and we can eliminate one of
        them with certainty, which makes the remaining call far easier.
        """
        last = self.ctx.store.last_watering_end()
        if last is None:
            return ("- The irrigation system has no record of ever running, so any\n"
                    "  wetness is either rain or someone watering by hand.")
        if last.tzinfo is None:
            last = last.replace(tzinfo=now.tzinfo)
        hours = (now - last.astimezone(now.tzinfo)).total_seconds() / 3600.0
        if hours <= 3:
            return (f"- KNOWN FACT: the irrigation system itself ran {hours:.1f} hours\n"
                    "  ago. Wetness around the pots is most likely that, and you\n"
                    "  should answer \"watering\" unless the whole roof including its\n"
                    "  far corners is evenly wet, which the system cannot do.")
        return (f"- KNOWN FACT: the irrigation system has NOT run for {hours:.0f} hours,\n"
                "  so it cannot be the cause. Any wetness is rain or a person with\n"
                "  a hose - use the spatial test above to say which.")

    def _ask_gemini(self, jpeg: bytes, watering_context: str) -> dict:
        cfg = self.ctx.config
        body = json.dumps({
            "contents": [{"parts": [
                {"text": PROMPT % watering_context},
                {"inline_data": {"mime_type": "image/jpeg",
                                 "data": base64.b64encode(jpeg).decode()}}]}],
            # Temperature 0: this is a measurement, not a conversation, and
            # the same frame should not read differently twice.
            "generationConfig": {"temperature": 0.0, "maxOutputTokens": 2048,
                                 "responseMimeType": "application/json",
                                 "responseSchema": SCHEMA},
        }).encode()
        req = urllib.request.Request(
            f"https://generativelanguage.googleapis.com/v1beta/models/"
            f"{cfg.cloud_llm_model}:generateContent",
            data=body, method="POST",
            headers={"Content-Type": "application/json",
                     "x-goog-api-key": cfg.cloud_llm_api_key})
        with urllib.request.urlopen(req, timeout=45) as r:
            payload = json.loads(r.read().decode("utf-8", "replace"))
        text = "".join(p.get("text", "") for p in
                       payload["candidates"][0]["content"]["parts"])
        return json.loads(text)

    # ---- bookkeeping --------------------------------------------------------
    def _record(self, obs: Observation, previous: Optional[Observation], why: str):
        try:
            self.ctx.store.vision_save(obs.to_dict())
        except Exception:
            pass
        # Only narrate real changes: an observation every half hour saying
        # "still dry, still sunny" is noise in the activity feed.
        if previous is None or self._changed(previous, obs):
            self._log("VISION", self.headline(obs), False)

    @staticmethod
    def _changed(a: Observation, b: Observation) -> bool:
        return (a.ground != b.ground or a.raining_now != b.raining_now
                or a.wetness_source != b.wetness_source
                or a.stressed != b.stressed)

    @staticmethod
    def headline(obs: Observation) -> str:
        if obs.raining_now:
            return "Camera: it is raining on the roof right now"
        if obs.is_wet and obs.wetness_source == "rain":
            return "Camera: the roof is wet from rain"
        if obs.is_wet and obs.wetness_source == "watering":
            return ("Camera: the roof was watered, wet around the pots but "
                    "dry further out")
        if obs.stressed:
            return "Camera: the plants look like they need water"
        if obs.is_dry:
            return "Camera: the roof is dry"
        return f"Camera: ground {obs.ground}, {obs.light.replace('_', ' ')}"

    @staticmethod
    def _shrink(jpeg: bytes, max_w: int) -> bytes:
        """Downscale before upload. Wetness is a broad tonal cue rather than
        a fine detail, so this survives the resize — verified against the
        full-resolution frame — and it halves time-to-answer."""
        try:
            import cv2
            import numpy as np
            img = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
            h, w = img.shape[:2]
            if w <= max_w:
                return jpeg
            img = cv2.resize(img, (max_w, int(h * max_w / w)),
                             interpolation=cv2.INTER_AREA)
            ok, out = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 85])
            return out.tobytes() if ok else jpeg
        except Exception:
            return jpeg
