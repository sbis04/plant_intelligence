"""On-board AI assistant.

Hybrid: with an API key configured, questions go to Gemini Flash (fast,
smart) whenever the internet is reachable; the local LLM (llama.cpp on the
UNO Q's Linux side — no cloud, no key) answers whenever it isn't. Both are
grounded in the same fresh snapshot of everything the hub knows, composed
per request.

Robustness note: Gemma's chat template hard-rejects conversations that are
not strictly user/assistant alternating — a separate system role, or any
unpaired turn left behind by an aborted request, 400s at template-parse
time. So this module sends exactly ONE user message per request: persona,
a short self-managed transcript, live data, and the question, all folded
together. No system role, no server-side memory — nothing to get poisoned.
"""

import base64
import json
import threading
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

from arduino.app_bricks.llm import LargeLanguageModel

MODEL = "llamacpp:gemma-3-1b-it-Q4_0"

PERSONA = (
    "You are Plant Intelligence, the assistant built into an Arduino UNO Q "
    "that runs an automated rooftop garden irrigation system, fully locally. "
    "Answer using ONLY the LIVE DATA below; if it doesn't answer the "
    "question, say so plainly. Be friendly, concrete and brief — one to "
    "three sentences unless asked for detail.\n"
    "How to read the data:\n"
    "- watering_plan.reasons is THE authoritative explanation of why the "
    "system is or isn't watering, and watering_plan.next_water_at is when "
    "it will next water. Always answer 'why' questions from it.\n"
    "- recent_logs are diagnostics only — never present them as the cause "
    "of a watering decision.\n"
    "- sensors.soil_pct null means the soil probe isn't installed yet; "
    "box_temperature_c null means the box sensor isn't wired yet. Say it "
    "that way, not 'null'.\n"
    "- All times are already in the garden's local timezone — repeat them "
    "as written.\n"
    "- If a photo of the garden is attached, it is the camera's CURRENT "
    "view — use it whenever the question is about how the plants look.\n"
    "- Answer in plain conversational sentences. Never output raw JSON, "
    "field names, or machine-formatted timestamps."
)


class Assistant:
    def __init__(self, ctx):
        self.ctx = ctx
        self.llm = LargeLanguageModel(
            model=MODEL,
            system_prompt="",      # deliberate: Gemma's template rejects system turns
            temperature=0.3,
            max_tokens=280,
        )
        self.last_backend = "local"
        self.busy = False   # drives the board's "thinking" LED animation
        # The brick allows one generation at a time; concurrent requests
        # (dashboard + phone) queue here instead of erroring.
        self._lock = threading.Lock()

    # ---- context ----------------------------------------------------------
    def _live_data(self) -> dict:
        """Compact on purpose: every token here is prompt-prefill time on the
        A53 — i.e. the silent wait before the first streamed token. Nulls
        are dropped, lists are short, timestamps trimmed to minutes."""
        ctx = self.ctx

        def clean(d):
            return {k: v for k, v in d.items() if v is not None} if d else None

        tz = ZoneInfo(ctx.config.timezone)

        def ts(v):
            """ISO timestamp -> 'Mon 10 Aug, 09:50 PM' garden-local. A 1B
            model can't do timezone math; hand it display-ready strings."""
            try:
                dt = datetime.fromisoformat(v) if isinstance(v, str) else v
                return dt.astimezone(tz).strftime("%a %d %b, %I:%M %p")
            except (ValueError, TypeError, AttributeError):
                return v

        snap = ctx.hardware.snapshot()
        snap["soil_pct"] = ctx.config.soil_raw_to_pct(snap.get("soil_raw", -1))
        snap.pop("soil_raw", None)
        snap.pop("mcu_seen_seconds_ago", None)
        if snap.get("watering_seconds_left") == 0:
            snap.pop("watering_seconds_left", None)

        waterings = [
            {"at": ts(h["water_started_at"]), "trigger": h["trigger"]}
            for h in ctx.store.recent_history(3)
        ]
        logs = [f'{ts(l["timestamp"])} {l["message"]}'
                for l in ctx.store.recent_logs(3)]

        plan = clean(ctx.current_plan.to_dict()) if ctx.current_plan else None
        if plan and plan.get("next_water_at"):
            plan["next_water_at"] = ts(plan["next_water_at"])

        return {
            "now": ts(datetime.now(tz)),
            "garden_location": ctx.config.location_name,
            "sensors": clean(snap),
            "watering_plan": plan,
            "weather": clean(ctx.current_weather.to_dict()) if ctx.current_weather else None,
            "recent_waterings": waterings,
            "recent_logs": logs,
            "soil_probe_installed": ctx.config.soil_enabled,
            "schedule_mode": (
                "adaptive (soil + weather decide the cadence)"
                if ctx.config.soil_enabled or not ctx.config.fixed_when_no_soil
                else "fixed daily slots at " + ", ".join(ctx.config.fixed_times) +
                     " (no soil probe yet); weather only changes the duration "
                     "or skips a slot it would waste"),
        }

    def _compose(self, question: str, thread_id: int) -> str:
        parts = [PERSONA]
        # Per-thread history from the store — resuming a thread days later
        # picks up right where it left off.
        history = self.ctx.store.thread_messages(thread_id, limit=8)
        if history:
            lines = [f"{'User' if m['role'] == 'user' else 'You'}: {m['content']}"
                     for m in history]
            parts.append("EARLIER IN THIS CONVERSATION:\n" + "\n".join(lines))
        parts.append("LIVE DATA:\n" +
                     json.dumps(self._live_data(), default=str, separators=(",", ":")))
        parts.append(f"USER QUESTION: {question}")
        return "\n\n".join(parts)

    # ---- chat --------------------------------------------------------------
    def _fresh_turn(self):
        """Clear anything that could poison the next request: a stream a
        disconnected client left running, and any brick-side memory."""
        try:
            self.llm.stop_stream()
        except Exception:
            pass
        try:
            self.llm.clear_memory()
        except Exception:
            pass

    # ---- cloud (Gemini Flash) ----------------------------------------------
    def _cloud_request(self, path: str, composed: str,
                       attachment: bytes = None):
        cfg = self.ctx.config
        parts = [{"text": composed}]
        # Gemini is multimodal: attach the camera's current frame so the
        # assistant can actually look at the plants. The on-device fallback
        # is text-only, so vision simply isn't available offline.
        cam = getattr(self.ctx, "camera", None)
        if cam is not None and cam.configured:
            jpeg = cam.snapshot()
            if jpeg:
                jpeg = self._shrink(jpeg)
                parts.append({"inline_data": {
                    "mime_type": "image/jpeg",
                    "data": base64.b64encode(jpeg).decode()}})
        if attachment:
            parts.append({"inline_data": {
                "mime_type": "image/jpeg",
                "data": base64.b64encode(self._shrink(attachment)).decode()}})
        body = json.dumps({
            "contents": [{"parts": parts}],
            # Generous cap: Gemini's hidden thinking tokens count against
            # this limit, and a tight one truncates the visible answer.
            # Minimal thinking: first token in ~2 s instead of ~20 s — for
            # grounded garden Q&A the deep-reasoning mode buys nothing.
            "generationConfig": {"temperature": 0.3, "maxOutputTokens": 8192,
                                 "thinkingConfig": {"thinkingLevel": "minimal"}},
        }).encode()
        req = urllib.request.Request(
            f"https://generativelanguage.googleapis.com/v1beta/models/"
            f"{cfg.cloud_llm_model}:{path}",
            data=body, method="POST",
            headers={"Content-Type": "application/json",
                     "x-goog-api-key": cfg.cloud_llm_api_key})
        # The short timeout doubles as the "is the internet up?" check.
        return urllib.request.urlopen(req, timeout=15)

    @staticmethod
    def _shrink(jpeg: bytes, max_w: int = 1024) -> bytes:
        """Downscale the camera frame before upload: the model tiles images
        anyway, and a 2K frame just slows time-to-first-token."""
        try:
            import cv2
            import numpy as np
            img = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
            h, w = img.shape[:2]
            if w <= max_w:
                return jpeg
            img = cv2.resize(img, (max_w, int(h * max_w / w)),
                             interpolation=cv2.INTER_AREA)
            ok, out = cv2.imencode(".jpg", img,
                                   [cv2.IMWRITE_JPEG_QUALITY, 80])
            return out.tobytes() if ok else jpeg
        except Exception:
            return jpeg

    def _cloud_stream(self, composed: str, attachment: bytes = None):
        """Yield text chunks from Gemini's SSE stream. Raises on failure —
        the caller falls back to the local model."""
        with self._cloud_request("streamGenerateContent?alt=sse", composed,
                                 attachment) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                try:
                    data = json.loads(line[5:].strip())
                    for part in data["candidates"][0]["content"]["parts"]:
                        if part.get("text"):
                            yield part["text"]
                except (KeyError, IndexError, ValueError):
                    continue

    def _cloud_ask(self, composed: str) -> str:
        with self._cloud_request("generateContent", composed) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
        return "".join(p.get("text", "")
                       for p in data["candidates"][0]["content"]["parts"])

    # ---- ask ----------------------------------------------------------------
    def _finish_turn(self, thread_id: int, question: str, reply: str,
                     attachment_ref: str = ""):
        self.ctx.store.thread_add_message(thread_id, "user", question,
                                          attachment=attachment_ref)
        if reply:
            self.ctx.store.thread_add_message(thread_id, "assistant", reply)

    def ask_stream(self, question: str, thread_id: int,
                   attachment: bytes = None, attachment_ref: str = ""):
        """Yield the reply incrementally: cloud first when a key is set,
        on-device model when the cloud is unreachable. The exchange is
        persisted to the thread, including a partial reply if the client
        disconnects mid-stream."""
        self.busy = True
        try:
            yield from self._ask_stream(question, thread_id,
                                        attachment, attachment_ref)
        finally:
            self.busy = False

    def _ask_stream(self, question: str, thread_id: int,
                    attachment: bytes = None, attachment_ref: str = ""):
        if attachment:
            question_stored = question
            question = (question +
                        "\n(The user attached a photo — it is the LAST image; "
                        "the garden camera frame, if present, comes before it.)")
        else:
            question_stored = question
        composed = self._compose(question, thread_id)
        with self._lock:
            if self.ctx.config.cloud_llm_api_key:
                # Optimistically mark the attempt so clients polling status
                # mid-generation see which backend is actually working.
                self.last_backend = "cloud"
                collected = []
                try:
                    for text in self._cloud_stream(composed, attachment):
                        collected.append(text)
                        yield text
                    self._finish_turn(thread_id, question_stored, "".join(collected), attachment_ref)
                    return
                except GeneratorExit:
                    self._finish_turn(thread_id, question_stored, "".join(collected), attachment_ref)
                    raise
                except Exception as e:
                    if collected:   # died mid-reply: don't restart locally
                        self._finish_turn(thread_id, question_stored, "".join(collected), attachment_ref)
                        yield "\n[cloud connection lost]"
                        return
                    # never produced a byte — offline or bad key: go local
                    try:
                        self.ctx.store.log(
                            "SYSTEM", f"Cloud model unreachable ({type(e).__name__}), answering on-device")
                    except Exception:
                        pass

            self.last_backend = "local"
            self._fresh_turn()
            collected = []
            try:
                for chunk in self.llm.chat_stream(composed):
                    text = chunk if isinstance(chunk, str) else str(chunk)
                    collected.append(text)
                    yield text
            except GeneratorExit:
                # Client went away mid-reply — stop generation so the brick
                # doesn't stay "in progress" forever.
                try:
                    self.llm.stop_stream()
                except Exception:
                    pass
                self._finish_turn(thread_id, question_stored, "".join(collected), attachment_ref)
                raise
            self._finish_turn(thread_id, question_stored, "".join(collected), attachment_ref)

    def ask(self, question: str, thread_id: int) -> str:
        self.busy = True
        try:
            return self._ask(question, thread_id)
        finally:
            self.busy = False

    def _ask(self, question: str, thread_id: int) -> str:
        composed = self._compose(question, thread_id)
        with self._lock:
            if self.ctx.config.cloud_llm_api_key:
                try:
                    reply = self._cloud_ask(composed)
                    self.last_backend = "cloud"
                    self._finish_turn(thread_id, question, reply)
                    return reply
                except Exception:
                    pass
            self.last_backend = "local"
            self._fresh_turn()
            reply = self.llm.chat(composed)
            self._finish_turn(thread_id, question, reply)
            return reply
