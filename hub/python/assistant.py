"""On-board AI assistant.

A local LLM (llama.cpp on the UNO Q's Linux side — no cloud, no API key)
that answers questions about the garden, grounded in a fresh snapshot of
everything the hub knows on every request.

Robustness note: Gemma's chat template hard-rejects conversations that are
not strictly user/assistant alternating — a separate system role, or any
unpaired turn left behind by an aborted request, 400s at template-parse
time. So this module sends exactly ONE user message per request: persona,
a short self-managed transcript, live data, and the question, all folded
together. No system role, no server-side memory — nothing to get poisoned.
"""

import json
from collections import deque
from datetime import datetime, timezone

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
    "- Timestamps are ISO format."
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
        self.history: deque = deque(maxlen=3)   # (question, answer)

    # ---- context ----------------------------------------------------------
    def _live_data(self) -> dict:
        ctx = self.ctx
        snap = ctx.hardware.snapshot()
        snap["soil_pct"] = ctx.config.soil_raw_to_pct(snap.get("soil_raw", -1))
        waterings = [
            {"started": h["water_started_at"], "ended": h["water_ended_at"],
             "trigger": h["trigger"]}
            for h in ctx.store.recent_history(4)
        ]
        logs = [
            {"t": l["timestamp"], "msg": l["message"], "err": l["is_error"]}
            for l in ctx.store.recent_logs(5)
        ]
        return {
            "now_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "garden_location": ctx.config.location_name,
            "sensors": snap,
            "watering_plan": ctx.current_plan.to_dict() if ctx.current_plan else None,
            "weather": ctx.current_weather.to_dict() if ctx.current_weather else None,
            "recent_waterings": waterings,
            "recent_logs": logs,
            "settings": {
                "base_duration_s": ctx.config.base_duration_s,
                "watering_window": f"{ctx.config.window_start}-{ctx.config.window_end}",
                "soil_probe_enabled": ctx.config.soil_enabled,
            },
        }

    def _compose(self, question: str) -> str:
        parts = [PERSONA]
        if self.history:
            lines = []
            for q, a in self.history:
                lines.append(f"User asked: {q}\nYou answered: {a}")
            parts.append("EARLIER IN THIS CONVERSATION:\n" + "\n".join(lines))
        parts.append("LIVE DATA:\n" +
                     json.dumps(self._live_data(), default=str, separators=(",", ":")))
        parts.append(f"USER QUESTION: {question}")
        return "\n\n".join(parts)

    # ---- chat --------------------------------------------------------------
    def ask(self, question: str) -> str:
        # Belt and braces: even though we never use server-side memory, clear
        # any the brick may have accumulated so each request is a single turn.
        try:
            self.llm.clear_memory()
        except Exception:
            pass
        reply = self.llm.chat(self._compose(question))
        self.history.append((question, reply))
        return reply

    def reset(self) -> None:
        self.history.clear()
        try:
            self.llm.clear_memory()
        except Exception:
            pass
