"""RTSP camera snapshots.

The garden camera (a Tapo C520WS on the same LAN) exposes an RTSP stream
once a camera account is created in the Tapo app. Frames are grabbed via
the App Lab camera peripheral (OpenCV underneath), on demand: connect,
capture one frame, disconnect — outdoor cameras allow only a few
concurrent RTSP sessions, so holding one open would starve the Tapo app's
own live view.

Snapshots are cached briefly so a dashboard and a phone polling together
don't hammer the camera.
"""

import threading
import time
from typing import Optional

from arduino.app_peripherals.camera import Camera
from arduino.app_utils.image import compress_to_jpeg

MIN_INTERVAL_S = 3.0        # serve the cached frame if newer than this. Clients
                            # pace themselves (60 s ambient, ~5 s with the viewer
                            # open); this only coalesces concurrent viewers.
CAPTURE_RES = (1280, 720)   # plenty for diagnosis; 2K would slow the LAN


class CameraService:
    def __init__(self, config):
        self._config = config           # live reference; creds may be set later
        self._lock = threading.Lock()
        self._cached: Optional[bytes] = None
        self._cached_at = 0.0
        self.last_error: Optional[str] = None

    @property
    def configured(self) -> bool:
        return bool(self._config.camera_rtsp_url)

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
