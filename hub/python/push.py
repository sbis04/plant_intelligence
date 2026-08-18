"""Apple push notifications, sent straight from the hub.

No Firebase involved: FCM was only ever a wrapper around APNs, and the
board can talk to Apple directly — a JWT signed with the team's .p8 key
and an HTTP/2 POST. Credentials live in hub/data/config.json (gitignored),
never in the repo.

Three payload shapes are used:
  - alert          : ordinary notification ("Watering started")
  - liveactivity   : start / update / end the lock-screen watering card.
                     A push-to-start token lets the hub raise the card even
                     when the app was never opened.
Tokens are registered by the app and stored in SQLite; Apple's 410
"Unregistered" response prunes stale ones automatically.
"""

import json
import threading
import time
from typing import Optional

PROD_HOST = "https://api.push.apple.com"
SANDBOX_HOST = "https://api.sandbox.push.apple.com"
JWT_TTL_S = 45 * 60          # Apple wants a fresh token at least hourly


class PushService:
    def __init__(self, config, store, log=None):
        self._config = config          # live reference; creds may be set later
        self._store = store
        self._log = log or (lambda *a, **k: None)
        self._lock = threading.Lock()
        self._jwt = None
        self._jwt_at = 0.0
        self._client = None
        self.last_error: Optional[str] = None

    # ---- plumbing -----------------------------------------------------------
    @property
    def configured(self) -> bool:
        c = self._config
        return bool(c.apns_key_p8 and c.apns_key_id and c.apns_team_id
                    and c.apns_bundle_id)

    def _host(self) -> str:
        return SANDBOX_HOST if self._config.apns_use_sandbox else PROD_HOST

    def _auth_token(self) -> str:
        """Cached ES256 JWT — signing on every push would be wasteful and
        Apple rate-limits token churn."""
        now = time.time()
        if self._jwt and now - self._jwt_at < JWT_TTL_S:
            return self._jwt
        import jwt as pyjwt
        self._jwt = pyjwt.encode(
            {"iss": self._config.apns_team_id, "iat": int(now)},
            self._config.apns_key_p8,
            algorithm="ES256",
            headers={"kid": self._config.apns_key_id},
        )
        self._jwt_at = now
        return self._jwt

    def _http(self):
        if self._client is None:
            import httpx
            self._client = httpx.Client(http2=True, timeout=10.0)
        return self._client

    def probe(self, token: str, payload: dict, push_type: str,
              topic_suffix: str = "") -> dict:
        """Try both APNs environments and report what each said, without
        deleting anything. `_post` prunes on BadDeviceToken, which destroys
        the evidence when the real fault is a topic or key mismatch rather
        than a dead device."""
        headers = {
            "authorization": f"bearer {self._auth_token()}",
            "apns-topic": self._config.apns_bundle_id + topic_suffix,
            "apns-push-type": push_type,
            "apns-priority": "10",
            "apns-expiration": "0",
        }
        out = {"topic": headers["apns-topic"], "token": token[:12] + "…"}
        for name, host in (("sandbox", SANDBOX_HOST), ("production", PROD_HOST)):
            try:
                r = self._http().post(f"{host}/3/device/{token}",
                                      headers=headers, content=json.dumps(payload))
                try:
                    reason = r.json().get("reason", "")
                except Exception:
                    reason = r.text[:120]
                out[name] = f"{r.status_code} {reason}".strip()
            except Exception as e:
                out[name] = f"{type(e).__name__}: {e}"
        return out

    def _post(self, token: str, payload: dict, push_type: str,
              topic_suffix: str = "", priority: str = "10",
              expiration: int = 0) -> bool:
        """Send to Apple, accepting both development and TestFlight tokens.

        APNs returns ``BadDeviceToken`` when a valid token is sent to the
        wrong environment. Try the other endpoint before treating it as
        stale so direct installs and TestFlight builds can share one hub.
        """
        headers = {
            "authorization": f"bearer {self._auth_token()}",
            "apns-topic": self._config.apns_bundle_id + topic_suffix,
            "apns-push-type": push_type,
            "apns-priority": priority,
            "apns-expiration": str(expiration),
        }
        primary = self._host()
        alternate = PROD_HOST if primary == SANDBOX_HOST else SANDBOX_HOST
        for attempt, host in enumerate((primary, alternate)):
            try:
                r = self._http().post(f"{host}/3/device/{token}",
                                      headers=headers, content=json.dumps(payload))
            except Exception as e:
                self.last_error = f"{type(e).__name__}: {e}"
                return False
            if r.status_code == 200:
                self.last_error = None
                return True
            try:
                reason = r.json().get("reason", "")
            except Exception:
                reason = r.text[:120]
            if attempt == 0 and reason == "BadDeviceToken":
                continue
            self.last_error = f"{r.status_code} {reason}"
            # Only 410/Unregistered means "this app is gone from that
            # device". BadDeviceToken means the token doesn't match this
            # environment or topic, which is a configuration answer, not a
            # dead phone: deleting on it threw away a perfectly good
            # TestFlight token twice before this was understood.
            if r.status_code == 410 or reason == "Unregistered":
                self._store.push_token_delete(token)
                self._log("SYSTEM", "Dropped a token whose app was uninstalled")
            elif reason == "BadDeviceToken":
                self._log("SYSTEM",
                          "APNs rejected a token in both environments "
                          "(check bundle id / key): keeping it for now", True)
            return False
        return False

    # ---- notifications ------------------------------------------------------
    def notify(self, title: str, body: str, category: str = "",
               interruption: str = "active") -> int:
        """Send an alert to every registered device. Returns the number sent."""
        if not self.configured:
            return 0
        payload = {"aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "interruption-level": interruption,
            "relevance-score": 1.0,
        }}
        if category:
            payload["aps"]["category"] = category
        sent = 0
        for token in self._store.push_tokens("alert"):
            if self._post(token, payload, "alert"):
                sent += 1
        return sent

    # ---- live activity ------------------------------------------------------
    LA_SUFFIX = ".push-type.liveactivity"

    def activity_start(self, state: dict, attributes: dict,
                       alert: Optional[dict] = None) -> int:
        """Raise the watering card on the lock screen. Uses push-to-start
        tokens, so this works even if the app has never been opened today."""
        if not self.configured:
            return 0
        aps = {
            "timestamp": int(time.time()),
            "event": "start",
            "attributes-type": "WateringAttributes",
            "attributes": attributes,
            "content-state": state,
        }
        if alert:
            aps["alert"] = alert
        sent = 0
        for token in self._store.push_tokens("activity-start"):
            if self._post(token, {"aps": aps}, "liveactivity",
                          topic_suffix=self.LA_SUFFIX):
                sent += 1
        return sent

    def activity_update(self, state: dict, event: str = "update",
                        dismiss_in_s: int = 0) -> int:
        """Update or end an existing card via its per-activity token."""
        if not self.configured:
            return 0
        aps = {
            "timestamp": int(time.time()),
            "event": event,
            "content-state": state,
        }
        if event == "end" and dismiss_in_s:
            aps["dismissal-date"] = int(time.time()) + dismiss_in_s
        sent = 0
        for token in self._store.push_tokens("activity-update"):
            if self._post(token, {"aps": aps}, "liveactivity",
                          topic_suffix=self.LA_SUFFIX):
                sent += 1
        return sent
