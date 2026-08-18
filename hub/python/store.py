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
from datetime import datetime, timedelta, timezone
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
CREATE TABLE IF NOT EXISTS chat_threads (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id INTEGER NOT NULL,
    role TEXT NOT NULL,               -- user | assistant
    content TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS vision_observations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    observed_at TEXT NOT NULL,
    ground TEXT NOT NULL,
    raining_now INTEGER NOT NULL DEFAULT 0,
    light TEXT NOT NULL DEFAULT '',
    plants TEXT NOT NULL DEFAULT '',
    wetness_source TEXT NOT NULL DEFAULT '',
    confidence REAL NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS push_tokens (
    token TEXT PRIMARY KEY,
    kind TEXT NOT NULL,               -- alert | activity-start | activity-update
    updated_at TEXT NOT NULL
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
        try:   # migration: photo attachments on chat messages
            self._db.execute("ALTER TABLE chat_messages ADD COLUMN"
                             " attachment TEXT NOT NULL DEFAULT ''")
        except sqlite3.OperationalError:
            pass
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

    def recent_logs(self, limit: int = 50, hours: Optional[float] = None) -> list:
        """Newest first. `hours` bounds how far back to look, which is what
        the dashboard's time filter uses; timestamps are stored as UTC ISO
        strings, so a string comparison is a valid ordering."""
        with self._lock:
            if hours:
                since = (datetime.now(timezone.utc)
                         - timedelta(hours=hours)).isoformat()
                rows = self._db.execute(
                    "SELECT timestamp, event_type, message, is_error FROM system_logs"
                    " WHERE timestamp >= ? ORDER BY id DESC LIMIT ?",
                    (since, limit),
                ).fetchall()
            else:
                rows = self._db.execute(
                    "SELECT timestamp, event_type, message, is_error FROM system_logs"
                    " ORDER BY id DESC LIMIT ?", (limit,),
                ).fetchall()
        return [
            {"timestamp": r[0], "event_type": r[1], "message": r[2],
             "is_error": bool(r[3])}
            for r in rows
        ]

    # ---- camera observations ------------------------------------------------
    def vision_save(self, obs: dict):
        with self._lock:
            self._db.execute(
                "INSERT INTO vision_observations (observed_at, ground, raining_now,"
                " light, plants, wetness_source, confidence, note)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (obs.get("at"), obs.get("ground", ""),
                 1 if obs.get("raining_now") else 0, obs.get("light", ""),
                 obs.get("plants", ""), obs.get("wetness_source", ""),
                 float(obs.get("confidence", 0.0)), obs.get("note", "")),
            )
            self._db.commit()

    def recent_observations(self, limit: int = 20) -> list:
        with self._lock:
            rows = self._db.execute(
                "SELECT observed_at, ground, raining_now, light, plants,"
                " wetness_source, confidence, note FROM vision_observations"
                " ORDER BY id DESC LIMIT ?", (limit,),
            ).fetchall()
        return [
            {"at": r[0], "ground": r[1], "raining_now": bool(r[2]), "light": r[3],
             "plants": r[4], "wetness_source": r[5], "confidence": r[6],
             "note": r[7]}
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

    def close_stale_open_rows(self, max_age_min: int = 15):
        """Reconcile rows left open by a restart.

        The MCU hard-caps a watering at 10 minutes, so an open row older
        than max_age_min cannot still be running — its end event was lost
        while this process was down. Close it at start + cap rather than
        leaving a forever-"running" entry.
        """
        with self._lock:
            rows = self._db.execute(
                "SELECT id, water_started_at FROM water_history"
                " WHERE water_ended_at IS NULL"
            ).fetchall()
            closed = 0
            for row_id, started in rows:
                try:
                    started_dt = datetime.fromisoformat(started)
                except ValueError:
                    continue
                age_min = (datetime.now(timezone.utc) - started_dt).total_seconds() / 60
                if age_min >= max_age_min:
                    self._db.execute(
                        "UPDATE water_history SET water_ended_at = ?,"
                        " reason = reason || ' [end lost across restart]'"
                        " WHERE id = ?",
                        ((started_dt + timedelta(minutes=10)).isoformat(), row_id),
                    )
                    closed += 1
            self._db.commit()
        return closed

    # ---- assistant threads ------------------------------------------------------
    def thread_create(self, title: str = "") -> int:
        now = _now_iso()
        with self._lock:
            cur = self._db.execute(
                "INSERT INTO chat_threads (title, created_at, updated_at)"
                " VALUES (?, ?, ?)", (title, now, now))
            self._db.commit()
            return cur.lastrowid

    def thread_list(self, limit: int = 30) -> list:
        with self._lock:
            rows = self._db.execute(
                "SELECT t.id, t.title, t.updated_at,"
                " (SELECT content FROM chat_messages m WHERE m.thread_id = t.id"
                "  ORDER BY m.id DESC LIMIT 1)"
                " FROM chat_threads t ORDER BY t.updated_at DESC LIMIT ?",
                (limit,)).fetchall()
        return [{"id": r[0], "title": r[1], "updated_at": r[2],
                 "snippet": (r[3] or "")[:80]} for r in rows]

    def thread_exists(self, thread_id: int) -> bool:
        with self._lock:
            return self._db.execute(
                "SELECT 1 FROM chat_threads WHERE id = ?", (thread_id,)
            ).fetchone() is not None

    def thread_delete(self, thread_id: int) -> list:
        """Delete the thread; returns attachment ids so files can go too."""
        with self._lock:
            rows = self._db.execute(
                "SELECT attachment FROM chat_messages"
                " WHERE thread_id = ? AND attachment != ''",
                (thread_id,)).fetchall()
            self._db.execute("DELETE FROM chat_messages WHERE thread_id = ?",
                             (thread_id,))
            self._db.execute("DELETE FROM chat_threads WHERE id = ?",
                             (thread_id,))
            self._db.commit()
        return [r[0] for r in rows]

    def thread_messages(self, thread_id: int, limit: int = 200) -> list:
        with self._lock:
            rows = self._db.execute(
                "SELECT role, content, created_at, attachment FROM chat_messages"
                " WHERE thread_id = ? ORDER BY id DESC LIMIT ?",
                (thread_id, limit)).fetchall()
        return [{"role": r[0], "content": r[1], "created_at": r[2],
                 "attachment": r[3] or ""}
                for r in reversed(rows)]

    def thread_add_message(self, thread_id: int, role: str, content: str,
                           attachment: str = ""):
        now = _now_iso()
        with self._lock:
            self._db.execute(
                "INSERT INTO chat_messages (thread_id, role, content,"
                " created_at, attachment) VALUES (?, ?, ?, ?, ?)",
                (thread_id, role, content, now, attachment))
            # Auto-title from the first user message; bump recency either way.
            self._db.execute(
                "UPDATE chat_threads SET updated_at = ?,"
                " title = CASE WHEN title = '' AND ? = 'user'"
                "              THEN substr(?, 1, 60) ELSE title END"
                " WHERE id = ?",
                (now, role, content, thread_id))
            self._db.commit()

    # ---- push tokens ------------------------------------------------------------
    # How long a token may go unrefreshed before we forget it. The app
    # re-registers on every launch, so silence means the install is gone.
    # An activity-update token belongs to one card and is worthless once
    # that watering is over, so it expires far sooner.
    TOKEN_TTL_DAYS = {"alert": 30, "activity-start": 30, "activity-update": 2}

    def push_token_prune(self) -> int:
        """Forget tokens no app has refreshed in a long time.

        APNs accepts a well-formed token from an old install or a wiped
        simulator and reports success, so dead tokens make "notified 4
        devices" mean nothing.
        """
        removed = 0
        now = datetime.now(timezone.utc)
        with self._lock:
            for kind, days in self.TOKEN_TTL_DAYS.items():
                cutoff = (now - timedelta(days=days)).isoformat()
                cur = self._db.execute(
                    "DELETE FROM push_tokens WHERE kind = ? AND updated_at < ?",
                    (kind, cutoff))
                removed += cur.rowcount
            self._db.commit()
        return removed

    def push_token_age_s(self, token: str) -> float:
        """Seconds since this token was last registered; inf if unknown."""
        with self._lock:
            row = self._db.execute(
                "SELECT updated_at FROM push_tokens WHERE token = ?", (token,)
            ).fetchone()
        if not row:
            return float("inf")
        try:
            return (datetime.now(timezone.utc)
                    - datetime.fromisoformat(row[0])).total_seconds()
        except ValueError:
            return float("inf")

    def push_token_save(self, token: str, kind: str):
        """Register a device/activity token.

        Every kind keeps one row per device. This used to wipe all rows of
        an activity kind on each registration, which looked fine with one
        phone and quietly broke the moment there were two: the second phone
        to open the app deleted the first one's token, so only one device
        could ever receive a watering card. Superseded tokens are retired by
        age and by APNs telling us the app is gone, not by assuming the
        newest registration is the only real device.
        """
        with self._lock:
            self._db.execute(
                "INSERT INTO push_tokens (token, kind, updated_at) VALUES (?, ?, ?)"
                " ON CONFLICT(token) DO UPDATE SET kind = excluded.kind,"
                " updated_at = excluded.updated_at",
                (token, kind, _now_iso()))
            self._db.commit()

    def push_tokens(self, kind: str) -> list:
        with self._lock:
            rows = self._db.execute(
                "SELECT token FROM push_tokens WHERE kind = ?", (kind,)).fetchall()
        return [r[0] for r in rows]

    def push_token_delete(self, token: str):
        with self._lock:
            self._db.execute("DELETE FROM push_tokens WHERE token = ?", (token,))
            self._db.commit()

    def push_token_counts(self) -> dict:
        with self._lock:
            rows = self._db.execute(
                "SELECT kind, COUNT(*) FROM push_tokens GROUP BY kind").fetchall()
        return {r[0]: r[1] for r in rows}

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
