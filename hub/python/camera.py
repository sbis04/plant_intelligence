"""RTSP camera snapshots and live streaming.

The garden camera (a Tapo C520WS on the same LAN) exposes an RTSP stream
once a camera account is created in the Tapo app. Frames are grabbed via
the App Lab camera peripheral (OpenCV underneath) in two modes:

- snapshot: connect, capture one frame, disconnect — outdoor cameras allow
  only a few concurrent RTSP sessions, so ambient polling must not hold
  one open.
- stream: one persistent session on the light substream (stream2), used by
  the full-screen viewers for a real live feed. Capped so concurrent
  viewers can't exhaust the camera's session limit.

Snapshots are cached briefly so a dashboard and a phone polling together
don't hammer the camera.
"""

import threading
import time
from typing import Optional

from arduino.app_peripherals.camera import Camera
from arduino.app_utils.image import compress_to_jpeg

MIN_INTERVAL_S = 3.0        # serve the cached frame if newer than this. Clients
                            # pace themselves (60 s ambient); this only
                            # coalesces concurrent viewers.
CAPTURE_RES = (1280, 720)   # plenty for diagnosis; 2K would slow the LAN
MAX_STREAMS = 2             # Tapo allows few RTSP sessions; leave one spare
                            # for the Tapo app's own live view
STREAM_STALE_S = 30.0       # a slot silent this long is a dead client whose
                            # generator hasn't been reaped yet — don't let it
                            # block new viewers


class CameraService:
    def __init__(self, config):
        self._config = config           # live reference; creds may be set later
        self._lock = threading.Lock()
        self._cached: Optional[bytes] = None
        self._cached_at = 0.0
        self._stream_slots: dict = {}   # token -> last-yield time
        self.last_error: Optional[str] = None

    @property
    def configured(self) -> bool:
        return bool(self._config.camera_rtsp_url)

    def _live_streams(self) -> int:
        now = time.time()
        return sum(1 for t in self._stream_slots.values()
                   if now - t < STREAM_STALE_S)

    @property
    def can_stream(self) -> bool:
        return self.configured and self._live_streams() < MAX_STREAMS

    def snapshot(self) -> Optional[bytes]:
        """Return a JPEG frame, or None (see last_error)."""
        if not self.configured:
            self.last_error = "camera not configured"
            return None
        with self._lock:
            if self._cached and time.time() - self._cached_at < MIN_INTERVAL_S:
                return self._cached
            cam = None
            try:
                kwargs = {}
                if self._config.camera_username:
                    kwargs["username"] = self._config.camera_username
                    kwargs["password"] = self._config.camera_password
                cam = Camera(self._config.camera_rtsp_url,
                             resolution=CAPTURE_RES, **kwargs)
                cam.start()
                frame = cam.capture()
                jpeg = compress_to_jpeg(frame=frame, quality=85)
                if jpeg is None:
                    self.last_error = "frame captured but JPEG encode failed"
                    return None
                self._cached = jpeg.tobytes()
                self._cached_at = time.time()
                self.last_error = None
                return self._cached
            except Exception as e:
                self.last_error = str(e)
                return None
            finally:
                if cam is not None:
                    try:
                        cam.stop()
                    except Exception:
                        pass

    def stream(self):
        """Yield JPEG frames over one persistent RTSP session.

        Uses the camera's light substream (stream2) — full 2K would soak
        the LAN and the SoC for a phone-sized live view. Ends silently when
        the client disconnects (GeneratorExit) or the session cap is hit.
        """
        if not self.configured:
            self.last_error = "camera not configured"
            return
        token = object()
        with self._lock:
            if self._live_streams() >= MAX_STREAMS:
                self.last_error = "too many live viewers"
                return
            self._stream_slots[token] = time.time()
        cam = None
        try:
            kwargs = {}
            if self._config.camera_username:
                kwargs["username"] = self._config.camera_username
                kwargs["password"] = self._config.camera_password
            url = self._config.camera_rtsp_url.replace("stream1", "stream2")
            cam = Camera(url, **kwargs)
            cam.start()
            while True:
                frame = cam.capture()   # blocks until the next frame — the
                jpeg = compress_to_jpeg(frame=frame, quality=80)  # source paces us
                if jpeg is None:
                    continue
                data = jpeg.tobytes()
                with self._lock:        # keep ambient snapshots warm for free
                    self._cached = data
                    self._cached_at = time.time()
                    self._stream_slots[token] = self._cached_at
                yield data
        except Exception as e:
            self.last_error = str(e)
        finally:
            with self._lock:
                self._stream_slots.pop(token, None)
            if cam is not None:
                try:
                    cam.stop()
                except Exception:
                    pass
