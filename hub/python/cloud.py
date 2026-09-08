"""Cloud sync — Firestore over REST.

The system stays local-first: SQLite is the source of truth and the app talks
straight to the hub whenever it can see it on the LAN. This module is the
mirror for when it can't. It pushes state up, drains an outbox of history and
logs, and picks up commands the app leaves behind while it is away.

Firestore is reached over its REST API rather than the Python SDK: the SDK
pulls in grpc and a long dependency tree for what is, at this volume, half a
dozen HTTP calls a minute. Auth is the same email/password identity the
previous ESP32 system used, so the existing security rules and collections
carry over unchanged.

Two failure modes shaped this file, both learned the hard way elsewhere:

  Liveness is measured by writes, not by auth. A token that refreshes
  happily while every document write fails is the exact shape of a wedge
  that looks healthy from the outside. `_last_write_ok` is the heartbeat.

  A broken session heals by being replaced, not re-authenticated. After
  three consecutive write failures the HTTP session and the token are both
  thrown away, because a half-open TLS connection survives re-auth and will
  keep failing until something forces a new socket.

And every request carries an explicit timeout. A call with no timeout is a
call that can hang forever, which on this hub means the garden stops being
watered — see the weather fetch that wedged the scheduler for 18 hours.
"""

import json
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Callable, Optional, Protocol

import requests

# Connect timeout, read timeout. Generous enough for a slow home uplink,
# short enough that nothing here can stall a loop for long.
_TIMEOUT = (5, 15)

_IDENTITY = "https://identitytoolkit.googleapis.com/v1"
_SECURETOKEN = "https://securetoken.googleapis.com/v1"
_FIRESTORE = "https://firestore.googleapis.com/v1"

# A command that has been sitting in the queue for longer than this is not
# acted on. If the hub was offline overnight, waking up to a stack of "water
# now" taps from yesterday evening and running them all is worse than
# ignoring them.
COMMAND_MAX_AGE_S = 600

# Consecutive write failures before the session is torn down and rebuilt.
WRITE_FAILURES_BEFORE_RESET = 3


class CloudSync(Protocol):
    def push_watering_event(self, doc: dict) -> None: ...
    def push_log(self, doc: dict) -> None: ...
    def push_health(self, doc: dict) -> None: ...


class NullSync:
    """The no-op sync used when no Firebase project is configured."""

    configured = False
    connected = False

    def push_watering_event(self, doc: dict) -> None:
        pass

    def push_log(self, doc: dict) -> None:
        pass

    def push_health(self, doc: dict) -> None:
        pass

    def status(self) -> dict:
        return {"configured": False, "connected": False}

    def start(self) -> None:
        pass

    def nudge(self) -> None:
        pass


# ---- Firestore value encoding ------------------------------------------------
# Firestore's REST API types every field explicitly. These two helpers are the
# whole translation layer between our plain dicts and the wire format.

def _to_rfc3339(value) -> Optional[str]:
    """Firestore timestamps must be RFC3339 with a Z suffix."""
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value)
        except ValueError:
            return None
    if not isinstance(value, datetime):
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _encode(value) -> dict:
    if value is None:
        return {"nullValue": None}
    if isinstance(value, bool):          # before int: bool is an int subclass
        return {"booleanValue": value}
    if isinstance(value, datetime):
        return {"timestampValue": _to_rfc3339(value)}
    if isinstance(value, int):
        return {"integerValue": str(value)}
    if isinstance(value, float):
        return {"doubleValue": value}
    if isinstance(value, dict):
        return {"mapValue": {"fields": {k: _encode(v) for k, v in value.items()}}}
    if isinstance(value, (list, tuple)):
        return {"arrayValue": {"values": [_encode(v) for v in value]}}
    return {"stringValue": str(value)}


def _decode(field: dict):
    if not isinstance(field, dict) or not field:
        return None
    kind, value = next(iter(field.items()))
    if kind == "integerValue":
        return int(value)
    if kind == "doubleValue":
        return float(value)
    if kind == "booleanValue":
        return bool(value)
    if kind == "nullValue":
        return None
    if kind == "mapValue":
        return {k: _decode(v) for k, v in (value.get("fields") or {}).items()}
    if kind == "arrayValue":
        return [_decode(v) for v in (value.get("values") or [])]
    return value


def _fields(doc: dict) -> dict:
    """Our dict → a Firestore document body, dropping Nones we never want
    to store as explicit nulls (absent reads cleaner in the app)."""
    return {"fields": {k: _encode(v) for k, v in doc.items() if v is not None}}


class FirestoreSync:
    """Mirrors hub state into Firestore and drains commands back out.

    Collections, matching the previous system so its rules and indexes carry
    over unchanged:

      water_history/{auto}   one document per watering
      system_logs/{auto}     the same log lines the dashboard shows
      device_state/current   a single live document — what the app reads
                             when it is away from home
      commands/{auto}        remote taps waiting to be executed
    """

    def __init__(self, config, store, snapshot_fn: Callable[[], dict],
                 on_command: Optional[Callable[[str, dict], tuple]] = None,
                 log: Optional[Callable] = None):
        self._cfg = config
        self._store = store
        self._snapshot = snapshot_fn
        self._on_command = on_command
        self._log = log or (lambda *a, **k: None)

        self._lock = threading.Lock()
        self._session: Optional[requests.Session] = None
        self._id_token = ""
        self._refresh_token = ""
        self._token_expires = 0.0
        self._uid = ""

        self._write_failures = 0
        self._last_write_ok = 0.0
        self._last_error = ""
        self._pushed_state = 0
        self._pushed_docs = 0
        self._commands_run = 0
        self._started = False
        self._wake = threading.Event()

    # ---- configuration ------------------------------------------------------
    @property
    def configured(self) -> bool:
        c = self._cfg
        return bool(c.firebase_project_id and c.firebase_api_key
                    and c.firebase_email and c.firebase_password)

    @property
    def connected(self) -> bool:
        """Connected means documents are landing, not that a token exists."""
        return bool(self._last_write_ok
                    and time.time() - self._last_write_ok < 300)

    def status(self) -> dict:
        return {
            "configured": self.configured,
            "connected": self.connected,
            "last_write_s_ago": round(time.time() - self._last_write_ok, 1)
            if self._last_write_ok else None,
            "write_failures": self._write_failures,
            "last_error": self._last_error,
            "state_pushes": self._pushed_state,
            "documents_synced": self._pushed_docs,
            "commands_run": self._commands_run,
        }

    # ---- session and auth ---------------------------------------------------
    def _http(self) -> requests.Session:
        if self._session is None:
            s = requests.Session()
            s.headers["Content-Type"] = "application/json"
            self._session = s
        return self._session

    def _reset_session(self, why: str):
        """Throw away the connection and the token together.

        Re-authenticating over a dead TLS session keeps returning fresh
        tokens down a socket that will never carry another write. The only
        thing that heals it is a new session, so both go.
        """
        try:
            if self._session is not None:
                self._session.close()
        except Exception:
            pass
        self._session = None
        self._id_token = ""
        self._refresh_token = ""
        self._token_expires = 0.0
        self._write_failures = 0
        self._log("CLOUD", f"Firestore session reset: {why}", is_error=True)

    def _authenticate(self) -> bool:
        c = self._cfg
        try:
            if self._refresh_token:
                r = self._http().post(
                    f"{_SECURETOKEN}/token?key={c.firebase_api_key}",
                    data={"grant_type": "refresh_token",
                          "refresh_token": self._refresh_token},
                    headers={"Content-Type": "application/x-www-form-urlencoded"},
                    timeout=_TIMEOUT)
                if r.ok:
                    d = r.json()
                    self._id_token = d.get("id_token", "")
                    self._refresh_token = d.get("refresh_token", self._refresh_token)
                    self._token_expires = time.time() + int(d.get("expires_in", 3600)) - 300
                    return bool(self._id_token)
                # A refresh token that is no longer accepted means starting over.
                self._refresh_token = ""

            r = self._http().post(
                f"{_IDENTITY}/accounts:signInWithPassword?key={c.firebase_api_key}",
                json={"email": c.firebase_email, "password": c.firebase_password,
                      "returnSecureToken": True},
                timeout=_TIMEOUT)
            if not r.ok:
                self._last_error = f"auth {r.status_code}: {r.text[:160]}"
                return False
            d = r.json()
            self._id_token = d.get("idToken", "")
            self._refresh_token = d.get("refreshToken", "")
            self._uid = d.get("localId", "")
            self._token_expires = time.time() + int(d.get("expiresIn", 3600)) - 300
            return bool(self._id_token)
        except Exception as e:
            self._last_error = f"auth: {e}"
            return False

    def _token(self) -> str:
        if self._id_token and time.time() < self._token_expires:
            return self._id_token
        self._authenticate()
        return self._id_token

    def _base(self) -> str:
        return (f"{_FIRESTORE}/projects/{self._cfg.firebase_project_id}"
                f"/databases/(default)/documents")

    # ---- document operations ------------------------------------------------
    def _request(self, method: str, url: str, body=None) -> Optional[dict]:
        token = self._token()
        if not token:
            self._note_failure("no token")
            return None
        try:
            r = self._http().request(
                method, url, json=body,
                headers={"Authorization": f"Bearer {token}"}, timeout=_TIMEOUT)
        except Exception as e:
            self._note_failure(str(e))
            return None
        if r.status_code == 401:
            # The token was rejected mid-flight; drop it and let the next
            # attempt re-auth rather than retrying in a tight loop here.
            self._id_token = ""
            self._token_expires = 0.0
            self._note_failure("401 unauthorized")
            return None
        if not r.ok:
            self._note_failure(f"{r.status_code}: {r.text[:160]}")
            return None
        self._note_success()
        try:
            return r.json()
        except json.JSONDecodeError:
            return {}

    def _note_success(self):
        self._last_write_ok = time.time()
        self._write_failures = 0
        self._last_error = ""

    def _note_failure(self, message: str):
        self._last_error = message
        self._write_failures += 1
        if self._write_failures >= WRITE_FAILURES_BEFORE_RESET:
            self._reset_session(f"{self._write_failures} consecutive failures"
                                f" ({message})")

    def create(self, collection: str, doc: dict) -> bool:
        """Add a document with a generated id."""
        return self._request("POST", f"{self._base()}/{collection}",
                             _fields(doc)) is not None

    def set(self, collection: str, doc_id: str, doc: dict) -> bool:
        """Create or overwrite a document at a known id."""
        return self._request("PATCH", f"{self._base()}/{collection}/{doc_id}",
                             _fields(doc)) is not None

    def update(self, collection: str, doc_id: str, doc: dict) -> bool:
        """Merge fields into an existing document, leaving the rest alone."""
        mask = "&".join(f"updateMask.fieldPaths={k}" for k in doc)
        return self._request(
            "PATCH", f"{self._base()}/{collection}/{doc_id}?{mask}",
            _fields(doc)) is not None

    def query(self, collection: str, where: Optional[tuple] = None,
              limit: int = 20) -> list:
        """Run a structured query; returns decoded documents with their ids."""
        query = {"from": [{"collectionId": collection}], "limit": limit}
        if where:
            field, op, value = where
            query["where"] = {"fieldFilter": {
                "field": {"fieldPath": field}, "op": op, "value": _encode(value)}}
        result = self._request("POST", f"{self._base()}:runQuery",
                               {"structuredQuery": query})
        if not result:
            return []
        docs = []
        for row in result:
            doc = row.get("document")
            if not doc:
                continue
            fields = {k: _decode(v) for k, v in (doc.get("fields") or {}).items()}
            fields["_id"] = doc.get("name", "").rsplit("/", 1)[-1]
            docs.append(fields)
        return docs

    # ---- the CloudSync interface --------------------------------------------
    def push_watering_event(self, doc: dict) -> None:
        self.create("water_history", doc)

    def push_log(self, doc: dict) -> None:
        self.create("system_logs", doc)

    def push_health(self, doc: dict) -> None:
        self.set("device_state", "current", doc)

    # ---- live state ---------------------------------------------------------
    def push_state(self) -> bool:
        """Mirror the hub's current status into device_state/current.

        This is the document the app reads when it is off the home network,
        so it carries the same shape the LAN /api/status returns — the app
        should not have to think about which source it came from.
        """
        try:
            snap = self._snapshot()
        except Exception as e:
            self._log("CLOUD", f"Could not build the cloud snapshot: {e}",
                      is_error=True)
            return False
        snap["updated_at"] = datetime.now(timezone.utc)
        ok = self.set("device_state", "current", snap)
        if ok:
            self._pushed_state += 1
        return ok

    # ---- outbox -------------------------------------------------------------
    def drain_outbox(self, batch: int = 40) -> int:
        """Push everything SQLite has recorded but not yet mirrored.

        The `synced` flag is the whole mechanism: rows are marked only after
        Firestore accepts them, so an outage just means a longer queue, and
        a restart mid-sync repeats at most one document.
        """
        sent = 0
        for row_id, doc in self._store.unsynced_waterings(batch):
            if not self.create("water_history", doc):
                return sent
            self._store.mark_watering_synced(row_id)
            sent += 1
        for row_id, doc in self._store.unsynced_logs(batch):
            if not self.create("system_logs", doc):
                return sent
            self._store.mark_log_synced(row_id)
            sent += 1
        self._pushed_docs += sent
        return sent

    # ---- commands -----------------------------------------------------------
    def poll_commands(self) -> int:
        """Execute anything the app queued while it was away.

        Each command is its own document with a status field, so it is
        executed once and the result is visible to whoever sent it. That is
        the difference from the previous system's single override document,
        where a dropped write and a repeated one looked identical.
        """
        if not self._on_command:
            return 0
        try:
            pending = self.query("commands", ("status", "EQUAL", "pending"), limit=10)
        except Exception as e:
            self._last_error = f"commands: {e}"
            return 0

        ran = 0
        now = datetime.now(timezone.utc)
        for cmd in pending:
            doc_id = cmd.get("_id")
            if not doc_id:
                continue
            requested = cmd.get("requested_at")
            age = None
            if isinstance(requested, str):
                try:
                    age = (now - datetime.fromisoformat(
                        requested.replace("Z", "+00:00"))).total_seconds()
                except ValueError:
                    age = None
            if age is not None and age > COMMAND_MAX_AGE_S:
                self.update("commands", doc_id, {
                    "status": "expired", "executed_at": now,
                    "result": f"ignored: queued {int(age / 60)} minutes ago"})
                self._log("CLOUD", "Ignored a remote command that had gone stale"
                                   f" ({int(age / 60)} minutes old)")
                continue

            action = str(cmd.get("action", "")).lower()
            try:
                accepted, message = self._on_command(action, cmd)
            except Exception as e:
                accepted, message = False, f"failed: {e}"
            self.update("commands", doc_id, {
                "status": "done" if accepted else "rejected",
                "executed_at": now, "result": message})
            self._log("CLOUD", f"Remote command '{action}': {message}",
                      is_error=not accepted)
            ran += 1
        self._commands_run += ran
        return ran

    # ---- background loop ----------------------------------------------------
    def nudge(self):
        """Ask the loop to run its next pass immediately.

        Called when something worth mirroring just happened — a watering
        started or stopped — so the phone across town sees it in a second
        rather than at the next scheduled push.
        """
        self._wake.set()

    def start(self):
        if self._started or not self.configured:
            return
        self._started = True
        threading.Thread(target=self._loop, name="cloud-sync", daemon=True).start()
        # The project id is deliberately not logged: the system log is on
        # screen in the dashboard and in the app, and there is no reason to
        # put an account identifier where a screenshot will pick it up.
        self._log("CLOUD", "Firestore sync starting")

    def _loop(self):
        state_due = 0.0
        interval = 10
        while True:
            try:
                interval = max(5, int(self._cfg.cloud_command_poll_s))
                # Commands are the latency-sensitive half: someone is holding
                # a phone waiting for the valve to open.
                self.poll_commands()

                now = time.time()
                # Push state more often while something is happening, so a
                # remote watching a watering sees the countdown move.
                period = (5 if self._is_busy()
                          else max(10, int(self._cfg.cloud_sync_interval_s)))
                if now >= state_due:
                    self.push_state()
                    state_due = now + period

                self.drain_outbox()
            except Exception as e:
                # This thread must outlive every possible failure below it.
                self._last_error = f"loop: {e}"
                try:
                    self._log("CLOUD", f"Sync pass failed: {e}", is_error=True)
                except Exception:
                    pass
            self._wake.wait(timeout=interval)
            self._wake.clear()

    def _is_busy(self) -> bool:
        try:
            return bool(self._snapshot().get("status", {}).get(
                "watering_state") in ("valve_opening", "watering"))
        except Exception:
            return False
