"""Local HTTP + WebSocket API, served by the web_ui Brick.

This is the surface the mobile app talks to over the LAN, and it also backs
the built-in dashboard in assets/. REST for request/response, a WebSocket
"telemetry" event for live updates.

The Brick wraps handlers in FastAPI, which builds the request contract from
each function's signature — so handlers take exactly the parameters they
expect (typed, with defaults for optional ones) and nothing else. Optional
values arrive as query parameters: POST /api/water?duration_s=120.

Endpoints:
  GET  /api/status    → live sensors, watering state, current plan, weather
  GET  /api/history   → recent watering events
  GET  /api/logs      → recent system log entries
  GET  /api/config    → active configuration
  POST /api/water     → start a manual watering (?duration_s=, optional)
  POST /api/stop      → stop watering now
  POST /api/location  → set coordinates (?latitude=&longitude=), e.g. phone GPS
"""

from typing import Optional

from fastapi import Request


def _location(ctx) -> dict:
    return {
        "name": ctx.config.location_name,
        "source": ctx.config.location_source,
        "latitude": ctx.config.latitude,
        "longitude": ctx.config.longitude,
    }


def register(ui, ctx):
    """Wire endpoints onto the WebUI brick. `ctx` is the AppContext from main."""

    def status():
        snap = ctx.hardware.snapshot()
        snap["soil_pct"] = ctx.config.soil_raw_to_pct(snap.get("soil_raw", -1))
        return {
            "status": snap,
            "plan": ctx.current_plan.to_dict() if ctx.current_plan else None,
            "weather": ctx.current_weather.to_dict() if ctx.current_weather else None,
            "location": _location(ctx),
            "assistant": {
                "cloud_configured": bool(ctx.config.cloud_llm_api_key),
                "last_backend": ctx.assistant.last_backend if ctx.assistant else None,
            },
            "push": {
                "configured": bool(ctx.push and ctx.push.configured),
                "devices": ctx.store.push_token_counts().get("alert", 0),
            },
        }

    def history():
        return {"history": ctx.store.recent_history(30)}

    def logs():
        return {"logs": ctx.store.recent_logs(50)}

    def get_config():
        from dataclasses import asdict
        cfg = asdict(ctx.config)
        # Never hand secrets back out over the LAN — report presence only.
        for secret in ("camera_password", "cloud_llm_api_key", "apns_key_p8"):
            cfg[secret] = bool(cfg.get(secret))
        return {"config": cfg}

    def water(duration_s: Optional[int] = None):
        duration = duration_s if duration_s else ctx.config.base_duration_s
        duration = max(ctx.config.min_duration_s,
                       min(ctx.config.max_duration_s, duration))
        ok = ctx.request_manual_watering(duration)
        return {"accepted": ok, "duration_s": duration}

    def stop():
        ctx.hardware.stop_watering()
        ctx.store.log("OVERRIDE", "Manual stop requested via API")
        return {"accepted": True}

    def set_location(latitude: Optional[float] = None,
                     longitude: Optional[float] = None,
                     place: Optional[str] = None,
                     source: str = "manual", name: str = ""):
        """Set the garden's location.

        Two forms: coordinates (?latitude=&longitude= — e.g. the mobile app
        sending phone GPS, source=device) or a place name (?place=Siliguri —
        geocoded server-side, source=manual). Persisted to config, so it
        survives reboots; auto-detection never overrides it.
        """
        import location as loc_mod
        if place:
            resolved = loc_mod.geocode(place)
            if not resolved:
                return {"accepted": False, "error": f"could not find '{place}'"}
            latitude, longitude, name = resolved
        if latitude is None or longitude is None:
            return {"accepted": False,
                    "error": "provide place or latitude+longitude"}
        if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
            return {"accepted": False, "error": "coordinates out of range"}
        ctx.set_location(latitude, longitude, source=source, name=name)
        return {"accepted": True, "latitude": latitude, "longitude": longitude,
                "name": name}

    ui.expose_api("GET", "/api/status", status)
    ui.expose_api("GET", "/api/history", history)
    ui.expose_api("GET", "/api/logs", logs)
    def system():
        import system_stats
        return {"system": system_stats.snapshot()}

    ui.expose_api("GET", "/api/config", get_config)
    def camera_snapshot():
        from fastapi.responses import Response
        if not ctx.camera or not ctx.camera.configured:
            return {"available": False, "error": "camera not configured"}
        jpeg = ctx.camera.snapshot()
        if jpeg is None:
            return {"available": False, "error": ctx.camera.last_error}
        return Response(content=jpeg, media_type="image/jpeg",
                        headers={"Cache-Control": "no-store"})

    def camera_stream(raw: int = 0):
        """Live feed over one persistent RTSP session. Default is MJPEG
        (multipart/x-mixed-replace), which browsers render natively in an
        <img>. raw=1 sends bare concatenated JPEGs instead — URLSession
        special-cases multipart/x-mixed-replace in a way that deadlocks its
        streaming API, so the iOS viewer scans JPEG markers off the raw
        byte stream."""
        from fastapi.responses import Response, StreamingResponse
        if not ctx.camera or not ctx.camera.configured:
            return {"available": False, "error": "camera not configured"}
        if not ctx.camera.can_stream:
            # Explicit 503 so clients fall back to snapshot polling instead
            # of hanging on an empty 200.
            return Response(content="too many live viewers", status_code=503)

        frames = ctx.camera.stream()

        def bare():
            try:
                yield from frames
            finally:
                frames.close()   # disconnect the RTSP session promptly

        def mjpeg():
            try:
                for jpg in frames:
                    yield (b"--frame\r\n"
                           b"Content-Type: image/jpeg\r\n"
                           b"Content-Length: " + str(len(jpg)).encode()
                           + b"\r\n\r\n" + jpg + b"\r\n")
            finally:
                frames.close()

        if raw:
            return StreamingResponse(
                bare(), media_type="application/octet-stream",
                headers={"Cache-Control": "no-store"})
        return StreamingResponse(
            mjpeg(),
            media_type="multipart/x-mixed-replace; boundary=frame",
            headers={"Cache-Control": "no-store"})

    # ---- live video (HLS proxied from the on-board go2rtc relay) -----------
    # Only port 7000 leaves the container, so the playlist and segments are
    # relayed through FastAPI. Relative URLs inside the playlists resolve
    # against these paths, which mirror go2rtc's own layout.
    def _relay(path: str):
        from fastapi.responses import Response
        if not ctx.relay:
            return Response(content="relay not available", status_code=503)
        try:
            data, ctype = ctx.relay.fetch(path)
        except Exception as e:
            return Response(content=str(e), status_code=503)
        return Response(content=data, media_type=ctype,
                        headers={"Cache-Control": "no-store"})

    def camera_live():
        return _relay("stream.m3u8?src=garden&mp4")

    def camera_hls_playlist(id: str):
        return _relay(f"hls/playlist.m3u8?id={id}")

    def camera_hls_init(id: str):
        return _relay(f"hls/init.mp4?id={id}")

    def camera_hls_segment(id: str, n: int):
        return _relay(f"hls/segment.m4s?id={id}&n={n}")

    # ---- push notifications -------------------------------------------------
    def push_register(token: str, kind: str = "alert"):
        """The app registers its APNs tokens here: an alert token, a
        push-to-start token for live activities, and (while a watering card
        is on screen) that activity's update token."""
        if kind not in ("alert", "activity-start", "activity-update"):
            return {"accepted": False, "error": "unknown token kind"}
        ctx.store.push_token_save(token.strip(), kind)
        return {"accepted": True}

    async def push_config(request: Request, key_id: str = "", team_id: str = "",
                          bundle_id: str = "", sandbox: int = 1):
        """Install the APNs auth key. POST the .p8 file contents as the body;
        it is written only to hub/data/config.json on the board."""
        key = (await request.body()).decode("utf-8", "replace").strip()
        ctx.config.apns_key_p8 = key
        if key_id:
            ctx.config.apns_key_id = key_id.strip()
        if team_id:
            ctx.config.apns_team_id = team_id.strip()
        if bundle_id:
            ctx.config.apns_bundle_id = bundle_id.strip()
        ctx.config.apns_use_sandbox = bool(sandbox)
        ctx.config.save()
        ctx.store.log("SYSTEM", "Push notifications configured" if key
                      else "Push notifications disabled")
        return {"accepted": True, "configured": bool(ctx.push and ctx.push.configured)}

    def push_test():
        if not ctx.push or not ctx.push.configured:
            return {"sent": 0, "error": "push not configured"}
        sent = ctx.push.notify("Plant Intelligence",
                               "Push notifications are working.")
        return {"sent": sent, "error": ctx.push.last_error}

    def assistant_config(api_key: str = "", model: str = ""):
        """Set (or clear, with an empty api_key) the cloud model for the
        assistant. The key is persisted only on the board."""
        ctx.config.cloud_llm_api_key = api_key.strip()
        if model.strip():
            ctx.config.cloud_llm_model = model.strip()
        ctx.config.save()
        ctx.store.log("SYSTEM",
                      f"Assistant cloud model set ({ctx.config.cloud_llm_model})"
                      if ctx.config.cloud_llm_api_key else
                      "Assistant cloud model removed — on-device only")
        return {"accepted": True}

    def camera_config(rtsp_url: str, username: str = "", password: str = ""):
        ctx.config.camera_rtsp_url = rtsp_url.strip()
        ctx.config.camera_username = username
        ctx.config.camera_password = password
        ctx.config.save()
        ctx.store.log("SYSTEM", "Camera configured" if rtsp_url else "Camera removed")
        return {"accepted": True}

    ui.expose_api("GET", "/api/system", system)
    ui.expose_api("GET", "/api/camera/snapshot", camera_snapshot)
    ui.expose_api("GET", "/api/camera/stream", camera_stream)
    ui.expose_api("GET", "/api/camera/live.m3u8", camera_live)
    ui.expose_api("GET", "/api/camera/hls/playlist.m3u8", camera_hls_playlist)
    ui.expose_api("GET", "/api/camera/hls/init.mp4", camera_hls_init)
    ui.expose_api("GET", "/api/camera/hls/segment.m4s", camera_hls_segment)
    ui.expose_api("POST", "/api/camera/config", camera_config)
    ui.expose_api("POST", "/api/assistant/config", assistant_config)
    ui.expose_api("POST", "/api/push/register", push_register)
    ui.expose_api("POST", "/api/push/config", push_config)
    ui.expose_api("POST", "/api/push/test", push_test)
    ui.expose_api("POST", "/api/water", water)
    ui.expose_api("POST", "/api/stop", stop)
    def _resolve_thread(thread_id: int) -> int:
        """Existing thread id, or a fresh thread when 0/stale."""
        if thread_id and ctx.store.thread_exists(thread_id):
            return thread_id
        return ctx.store.thread_create()

    # Photos the user attaches to a question: uploaded first, saved (shrunk)
    # under hub/data/attachments so threads can re-render them, referenced
    # by id in the next chat call.
    import os as _os
    from config import CONFIG_DIR as _CONFIG_DIR
    ATTACH_DIR = _os.path.join(_CONFIG_DIR, "attachments")

    def _attach_path(token: str):
        if not token or not token.isalnum():   # no path tricks
            return None
        return _os.path.join(ATTACH_DIR, f"{token}.jpg")

    async def chat_attach(request: Request):
        import uuid
        data = await request.body()
        if not data:
            return {"id": None, "error": "empty body"}
        if len(data) > 10_000_000:
            return {"id": None, "error": "image too large"}
        if ctx.assistant:
            data = ctx.assistant._shrink(data)
        token = uuid.uuid4().hex[:12]
        _os.makedirs(ATTACH_DIR, exist_ok=True)
        with open(_attach_path(token), "wb") as f:
            f.write(data)
        return {"id": token, "error": None}

    def chat_attachment(id: str):
        from fastapi.responses import Response
        path = _attach_path(id)
        if not path or not _os.path.exists(path):
            return Response(content="not found", status_code=404)
        with open(path, "rb") as f:
            return Response(content=f.read(), media_type="image/jpeg",
                            headers={"Cache-Control": "max-age=86400"})

    def chat(message: str, thread_id: int = 0):
        """Ask the assistant (blocking). Clients should use a generous
        timeout — the on-device fallback takes a while on a 1B model."""
        if not ctx.assistant:
            return {"reply": None, "error": "assistant not available"}
        tid = _resolve_thread(thread_id)
        try:
            reply = ctx.assistant.ask(message, tid)
            return {"reply": reply, "thread_id": tid, "error": None}
        except Exception as e:  # model still loading, runner down, etc.
            return {"reply": None, "thread_id": tid, "error": str(e)}

    def chat_stream(message: str, thread_id: int = 0, attachment_id: str = ""):
        """Streamed variant: chunked plain text as the model generates.
        The thread id (existing or newly created) is returned in the
        X-Thread-Id header, available before the body starts."""
        from fastapi.responses import StreamingResponse
        tid = _resolve_thread(thread_id)
        attachment = None
        path = _attach_path(attachment_id) if attachment_id else None
        if path and _os.path.exists(path):
            with open(path, "rb") as f:
                attachment = f.read()

        def gen():
            if not ctx.assistant:
                yield "The assistant isn't available on this hub."
                return
            try:
                yield from ctx.assistant.ask_stream(
                    message, tid, attachment=attachment,
                    attachment_ref=attachment_id if attachment else "")
            except Exception as e:
                yield f"\n[assistant error: {e}]"

        return StreamingResponse(gen(), media_type="text/plain; charset=utf-8",
                                 headers={"X-Thread-Id": str(tid)})

    def chat_threads():
        return {"threads": ctx.store.thread_list()}

    def chat_thread(id: int):
        if not ctx.store.thread_exists(id):
            return {"messages": None, "error": "no such thread"}
        return {"messages": ctx.store.thread_messages(id), "error": None}

    def chat_thread_new():
        return {"id": ctx.store.thread_create()}

    def chat_thread_delete(id: int):
        for token in ctx.store.thread_delete(id):
            path = _attach_path(token)
            if path and _os.path.exists(path):
                try:
                    _os.remove(path)
                except OSError:
                    pass
        return {"accepted": True}

    ui.expose_api("POST", "/api/location", set_location)
    ui.expose_api("POST", "/api/chat", chat)
    ui.expose_api("POST", "/api/chat/stream", chat_stream)
    ui.expose_api("POST", "/api/chat/attach", chat_attach)
    ui.expose_api("GET", "/api/chat/attachment", chat_attachment)
    ui.expose_api("GET", "/api/chat/threads", chat_threads)
    ui.expose_api("GET", "/api/chat/thread", chat_thread)
    ui.expose_api("POST", "/api/chat/thread/new", chat_thread_new)
    ui.expose_api("POST", "/api/chat/thread/delete", chat_thread_delete)

    # WebSocket commands (the dashboard uses these; the app may too)
    ui.on_message("water", lambda _client, _data=None: water())
    ui.on_message("stop", lambda _client, _data=None: stop())


def push_telemetry(ui, ctx):
    """Push a live snapshot to connected dashboard/app clients."""
    snap = ctx.hardware.snapshot()
    snap["soil_pct"] = ctx.config.soil_raw_to_pct(snap.get("soil_raw", -1))
    ui.send_message("telemetry", {
        "status": snap,
        "plan": ctx.current_plan.to_dict() if ctx.current_plan else None,
        "weather": ctx.current_weather.to_dict() if ctx.current_weather else None,
        "location": _location(ctx),
    })
