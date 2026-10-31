"""Wakes the living-room TV dashboard on schedule.

The TV (an LG webOS set running the TV dashboard app) can turn itself off
but cannot turn itself back on: nothing on it runs in standby. The hub is
always on and on the same LAN, so the TV hands it a wake plan — the end of
its quiet hours and its "turn on" times — and the hub carries it out:

1. a Wake-on-LAN magic packet, sent straight to the TV's address (the TV's
   "Turn on via Wi-Fi" setting keeps its Wi-Fi listening in standby);
2. once it is up, LG's local remote-control service (SSAP, websocket on
   port 3000) launches the dashboard app.

The first SSAP connection makes the TV show an "allow" prompt; after OK the
client key is kept in config. The registration manifest (lg_registration.json)
is the one LG's own apps use, via PyWebOSTV (MIT).

Standard library only: a tiny websocket client is enough for SSAP.
"""

import base64
import json
import os
import socket
import struct
import threading
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

MANIFEST_PATH = os.path.join(os.path.dirname(__file__), "lg_registration.json")
CHECK_EVERY_S = 15


# ---- minimal websocket client (text frames, client-side masking) -----------
class _WS:
    def __init__(self, host: str, port: int, timeout: float = 8.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1024)
            if not chunk:
                raise ConnectionError("websocket handshake closed")
            head += chunk
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise ConnectionError("websocket handshake refused")
        self._buf = head.split(b"\r\n\r\n", 1)[1]

    def send(self, obj: dict):
        self._send_frame(0x1, json.dumps(obj).encode())

    def _send_frame(self, opcode: int, data: bytes):
        hdr = bytearray([0x80 | opcode])
        n = len(data)
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr += struct.pack(">H", n)
        else:
            hdr.append(0x80 | 127)
            hdr += struct.pack(">Q", n)
        mask = os.urandom(4)
        self.sock.sendall(bytes(hdr) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _read(self, n: int) -> bytes:
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("websocket closed")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def recv(self, timeout: float) -> dict:
        self.sock.settimeout(timeout)
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            payload = self._read(n)
            if b0 & 0x0F == 0x1:
                return json.loads(payload.decode("utf-8", "replace"))
            if b0 & 0x0F == 0x8:
                raise ConnectionError("websocket closed by TV")
            if b0 & 0x0F == 0x9:          # ping: answer, or the TV hangs up
                self._send_frame(0xA, payload)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class TvWaker:
    def __init__(self, config, log=None):
        self._config = config
        self._log = log or (lambda *a, **k: None)
        self._done = set()          # "YYYY-MM-DD HH:MM" already handled
        self.last_wake = ""
        self.last_error = ""

    def _now(self) -> datetime:
        """Local time in the hub's time zone (the board's clock runs in UTC)."""
        try:
            return datetime.now(ZoneInfo(self._config.timezone))
        except Exception:
            return datetime.now().astimezone()

    # ---- plan -----------------------------------------------------------------
    def set_plan(self, plan: dict) -> dict:
        """plan: {ip, macs: [...], app, wake: [{time: "HH:MM", days: [0-6]}]}.
        Days use 0 = Sunday; empty means every day."""
        clean = {
            "ip": str(plan.get("ip", "")).strip(),
            "macs": [str(m) for m in plan.get("macs", []) if m],
            "app": str(plan.get("app", "com.souvik.dashboard")),
            "wake": [{"time": str(w.get("time", "")), "days": [int(d) for d in w.get("days", [])]}
                     for w in plan.get("wake", []) if w.get("time")],
        }
        self._config.tv_wake_plan = clean
        self._config.save()
        return self.status()

    def status(self) -> dict:
        plan = self._config.tv_wake_plan or {}
        return {"paired": bool(self._config.tv_client_key),
                "wake": plan.get("wake", []), "next": self._next_wake(),
                "last_wake": self.last_wake, "last_error": self.last_error}

    def _next_wake(self) -> str:
        plan = self._config.tv_wake_plan or {}
        now = self._now()
        best = None
        for day_ahead in range(0, 8):
            d = now + timedelta(days=day_ahead)
            wd = (d.weekday() + 1) % 7      # Python Monday=0 -> Sunday=0
            for w in plan.get("wake", []):
                if w["days"] and wd not in w["days"]:
                    continue
                hh, mm = (int(x) for x in w["time"].split(":"))
                t = d.replace(hour=hh, minute=mm, second=0, microsecond=0)
                if t > now and (best is None or t < best):
                    best = t
            if best:
                break
        return best.isoformat(timespec="minutes") if best else ""

    # ---- loop -----------------------------------------------------------------
    def start(self):
        threading.Thread(target=self._loop, name="tv-wake", daemon=True).start()

    def _loop(self):
        while True:
            try:
                self._tick()
            except Exception as e:      # never let a TV problem stop the thread
                self.last_error = str(e)
            time.sleep(CHECK_EVERY_S)

    def _tick(self):
        plan = self._config.tv_wake_plan or {}
        now = self._now()
        stamp = now.strftime("%Y-%m-%d %H:%M")
        wd = (now.weekday() + 1) % 7
        for w in plan.get("wake", []):
            if w["time"] == now.strftime("%H:%M") and (not w["days"] or wd in w["days"]):
                if stamp not in self._done:
                    self._done.add(stamp)
                    threading.Thread(target=self.wake, name="tv-wake-now", daemon=True).start()
        if len(self._done) > 50:
            self._done = {s for s in self._done if s.startswith(now.strftime("%Y-%m-%d"))}

    # ---- actions --------------------------------------------------------------
    def wake(self) -> bool:
        """Wake the TV and open the dashboard. Safe to call when it's already on."""
        plan = self._config.tv_wake_plan or {}
        ip, macs = plan.get("ip"), plan.get("macs", [])
        if not ip or not macs:
            self.last_error = "no wake plan from the TV yet"
            return False
        self._magic(ip, macs)
        self._log("SYSTEM", "TV: wake signal sent")
        # Give it time to come up, then launch the dashboard (retry while it boots).
        for attempt in range(8):
            time.sleep(6 if attempt == 0 else 5)
            try:
                self._ssap(ip, "ssap://system.launcher/launch", {"id": plan.get("app", "com.souvik.dashboard")})
                self.last_wake = self._now().isoformat(timespec="minutes")
                self.last_error = ""
                self._log("SYSTEM", "TV: dashboard opened")
                return True
            except Exception as e:
                self.last_error = str(e)
        self._log("SYSTEM", f"TV: could not open the dashboard ({self.last_error})", is_error=True)
        return False

    def pair(self) -> bool:
        """Register with the TV (shows its allow prompt the first time)."""
        plan = self._config.tv_wake_plan or {}
        if not plan.get("ip"):
            self.last_error = "no wake plan from the TV yet"
            return False
        try:
            ws = self._register(plan["ip"], prompt_wait=90)
            ws.close()
            return True
        except Exception as e:
            self.last_error = str(e)
            return False

    @staticmethod
    def _magic(ip: str, macs: list):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            for mac in macs:
                raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
                if len(raw) != 6:
                    continue
                pkt = b"\xff" * 6 + raw * 16
                for _ in range(3):
                    for port in (9, 7):
                        s.sendto(pkt, (ip, port))   # straight to the TV
                        try:
                            s.sendto(pkt, ("255.255.255.255", port))
                        except OSError:
                            pass
                time.sleep(0.1)
        finally:
            s.close()

    def _register(self, ip: str, prompt_wait: float = 10) -> _WS:
        with open(MANIFEST_PATH) as f:
            payload = json.load(f)
        if self._config.tv_client_key:
            payload["client-key"] = self._config.tv_client_key
        ws = _WS(ip, 3000)
        ws.send({"type": "register", "id": "register_0", "payload": payload})
        deadline = time.time() + prompt_wait
        while time.time() < deadline:
            m = ws.recv(timeout=max(1.0, deadline - time.time()))
            if m.get("id") != "register_0":
                continue
            if m.get("type") == "registered":
                key = (m.get("payload") or {}).get("client-key")
                if key and key != self._config.tv_client_key:
                    self._config.tv_client_key = key
                    self._config.save()
                    self._log("SYSTEM", "TV: the hub is allowed to open the dashboard")
                return ws
            if m.get("type") == "error":
                ws.close()
                raise ConnectionError(m.get("error", "TV refused"))
            # pairingType PROMPT: someone has to press OK on the TV
        ws.close()
        raise TimeoutError("the TV didn't allow the hub (press OK on the TV)")

    def _ssap(self, ip: str, uri: str, payload: dict):
        ws = self._register(ip)
        try:
            ws.send({"type": "request", "id": "req_1", "uri": uri, "payload": payload})
            while True:
                m = ws.recv(timeout=8)
                if m.get("id") == "req_1":
                    if m.get("type") == "error":
                        raise RuntimeError(m.get("error"))
                    return m.get("payload")
        finally:
            ws.close()
