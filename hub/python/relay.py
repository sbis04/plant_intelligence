"""Camera live-stream relay.

The Tapo app gets buttery 2K video because it plays the camera's H.264
stream directly — no transcoding. This module gives our clients the same
thing: go2rtc (a single static binary, kept in hub/data/bin) repackages the
camera's RTSP into fMP4 HLS without re-encoding, so the board spends ~no
CPU and the phone/browser hardware-decodes full quality at native fps.

Only port 7000 is exposed from the app container, so api.py proxies the
playlist and segments through FastAPI rather than exposing go2rtc itself.
"""

import os
import stat
import subprocess
import threading
import urllib.request
from urllib.parse import quote

from config import CONFIG_DIR

BIN_DIR = os.path.join(CONFIG_DIR, "bin")
BIN_PATH = os.path.join(BIN_DIR, "go2rtc")
YAML_PATH = os.path.join(CONFIG_DIR, "go2rtc.yaml")
DOWNLOAD_URL = ("https://github.com/AlexxIT/go2rtc/releases/latest/"
                "download/go2rtc_linux_arm64")
API = "http://127.0.0.1:1984/api"


class CameraRelay:
    def __init__(self, config, log=None):
        self._config = config
        self._log = log or (lambda *a: None)
        self._proc = None
        self._lock = threading.Lock()

    # ---- lifecycle ----------------------------------------------------------
    def start_async(self):
        """Provision + launch in the background; never blocks boot."""
        threading.Thread(target=self._start, daemon=True).start()

    def _start(self):
        if not self._config.camera_rtsp_url and not self._config.extra_cameras:
            return
        try:
            self._ensure_binary()
            self._write_config()
            with self._lock:
                self._spawn()
            self._log("SYSTEM", "Camera live relay started")
        except Exception as e:
            self._log("SYSTEM", f"Camera live relay unavailable: {e}")

    def _ensure_binary(self):
        if os.path.exists(BIN_PATH):
            return
        os.makedirs(BIN_DIR, exist_ok=True)
        tmp = BIN_PATH + ".part"
        with urllib.request.urlopen(DOWNLOAD_URL, timeout=120) as r, \
                open(tmp, "wb") as f:
            while True:
                chunk = r.read(1 << 16)
                if not chunk:
                    break
                f.write(chunk)
        os.chmod(tmp, os.stat(tmp).st_mode | stat.S_IEXEC)
        os.replace(tmp, BIN_PATH)

    @staticmethod
    def _with_creds(url: str, username: str, password: str) -> str:
        if not username:
            return url
        return url.replace(
            "rtsp://",
            f"rtsp://{quote(username, safe='')}:{quote(password, safe='')}@", 1)

    def _write_config(self):
        streams = []
        if self._config.camera_rtsp_url:
            streams.append(("garden", self._with_creds(
                self._config.camera_rtsp_url, self._config.camera_username,
                self._config.camera_password)))
        for cam in self._config.extra_cameras:
            if cam.get("id") and cam.get("rtsp_url"):
                streams.append((cam["id"], self._with_creds(
                    cam["rtsp_url"], cam.get("username", ""),
                    cam.get("password", ""))))
        with open(YAML_PATH, "w") as f:
            f.write("api:\n  listen: 127.0.0.1:1984\n"
                    "rtsp:\n  listen: \"\"\n"
                    "webrtc:\n  listen: \"\"\n"
                    "streams:\n"
                    + "".join(f"  {sid}: {url}\n" for sid, url in streams))

    def reload_async(self):
        """Cameras changed: rewrite the stream list and restart the relay."""
        def run():
            try:
                self._ensure_binary()
                self._write_config()
                with self._lock:
                    if self._alive():
                        self._proc.terminate()
                        try:
                            self._proc.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            self._proc.kill()
                    self._spawn()
                self._log("SYSTEM", "Camera live relay restarted")
            except Exception as e:
                self._log("SYSTEM", f"Camera live relay unavailable: {e}")
        threading.Thread(target=run, daemon=True).start()

    def _spawn(self):
        self._proc = subprocess.Popen(
            [BIN_PATH, "-config", YAML_PATH],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    # ---- proxy --------------------------------------------------------------
    def fetch(self, path: str):
        """GET a go2rtc API path; returns (bytes, content_type).
        Restarts a dead relay once before giving up."""
        if not self._alive():
            with self._lock:
                if not self._alive() and os.path.exists(BIN_PATH):
                    self._spawn()
        with urllib.request.urlopen(f"{API}/{path}", timeout=15) as r:
            return r.read(), r.headers.get("Content-Type",
                                           "application/octet-stream")
