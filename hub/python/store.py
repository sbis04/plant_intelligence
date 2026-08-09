"""Local persistence.

SQLite for documents (watering history, system logs) and the App Lab
time-series Brick for sensor samples. Document shapes deliberately mirror
the field names of the previous system's Firestore collections
(water_history, system_logs) so a future cloud sync is a mapping exercise,
not a redesign — see cloud.py.
"""

import os
import sqlite3
import threading
from datetime import datetime, timezone
from typing import Optional

from config import CONFIG_DIR, DB_PATH

_SCHEMA = """
CREATE TABLE IF NOT EXISTS water_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    water_started_at TEXT NOT NULL,
    water_ended_at   TEXT,
    planned_duration_ms INTEGER,
    trigger TEXT NOT NULL,            -- scheduled | manual | failsafe
    manual_override INTEGER NOT NULL DEFAULT 0,
    reason TEXT,
    synced INTEGER NOT NULL DEFAULT 0 -- for future cloud sync
);
CREATE TABLE IF NOT EXISTS system_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    event_type TEXT NOT NULL,
    message TEXT NOT NULL,
    is_error INTEGER NOT NULL DEFAULT 0,
    synced INTEGER NOT NULL DEFAULT 0
);
"""


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class Store:
    def __init__(self, db_path: str = DB_PATH):
        os.makedirs(CONFIG_DIR, exist_ok=True)
        self._lock = threading.Lock()
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(_SCHEMA)
        self._db.commit()

    # ---- logs -----------------------------------------------------------------
    def log(self, event_type: str, message: str, is_error: bool = False):
        with self._lock:
            self._db.execute(
                "INSERT INTO system_logs (timestamp, event_type, message, is_error)"
                " VALUES (?, ?, ?, ?)",
                (_now_iso(), event_type, message, 1 if is_error else 0),
            )
            self._db.commit()

    def recent_logs(self, limit: int = 50) -> list:
        with self._lock:
            rows = self._db.execute(
                "SELECT timestamp, event_type, message, is_error FROM system_logs"
                " ORDER BY id DESC LIMIT ?", (limit,),
            ).fetchall()
        return [
            {"timestamp": r[0], "event_type": r[1], "message": r[2],
             "is_error": bool(r[3])}
            for r in rows
        ]

    # ---- watering history --------------------------------------------------------
    def watering_started(self, trigger: str, planned_duration_ms: int,
                         reason: str = "") -> int:
        with self._lock:
            cur = self._db.execute(
                "INSERT INTO water_history (water_started_at, planned_duration_ms,"
                " trigger, manual_override, reason) VALUES (?, ?, ?, ?, ?)",
                (_now_iso(), planned_duration_ms, trigger,
                 1 if trigger == "manual" else 0, reason),
            )
            self._db.commit()
            return cur.lastrowid

    def watering_ended(self, row_id: Optional[int]):
        with self._lock:
            if row_id is not None:
                self._db.execute(
                    "UPDATE water_history SET water_ended_at = ? WHERE id = ?",
                    (_now_iso(), row_id),
                )
            else:  # unknown row (e.g. failsafe started while Python was down)
                self._db.execute(
                    "UPDATE water_history SET water_ended_at = ? WHERE id ="
                    " (SELECT id FROM water_history WHERE water_ended_at IS NULL"
                    "  ORDER BY id DESC LIMIT 1)",
                    (_now_iso(),),
                )
            self._db.commit()

    def recent_history(self, limit: int = 30) -> list:
        with self._lock:
            rows = self._db.execute(
                "SELECT water_started_at, water_ended_at, planned_duration_ms,"
                " trigger, manual_override, reason FROM water_history"
                " ORDER BY id DESC LIMIT ?", (limit,),
            ).fetchall()
        return [
            {"water_started_at": r[0], "water_ended_at": r[1],
             "planned_duration_ms": r[2], "trigger": r[3],
             "manual_override": bool(r[4]), "reason": r[5]}
            for r in rows
        ]

    def last_watering_end(self) -> Optional[datetime]:
        with self._lock:
            row = self._db.execute(
                "SELECT water_ended_at FROM water_history"
                " WHERE water_ended_at IS NOT NULL ORDER BY id DESC LIMIT 1"
            ).fetchone()
        if row and row[0]:
            try:
                return datetime.fromisoformat(row[0])
            except ValueError:
                return None
        return None
