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
        }

    def history():
        return {"history": ctx.store.recent_history(30)}

    def logs():
        return {"logs": ctx.store.recent_logs(50)}

    def get_config():
        from dataclasses import asdict
        cfg = asdict(ctx.config)
        # Never hand secrets back out over the LAN — report presence only.
        for secret in ("camera_password", "cloud_llm_api_key"):
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
    ui.expose_api("POST", "/api/camera/config", camera_config)
    ui.expose_api("POST", "/api/assistant/config", assistant_config)
    ui.expose_api("POST", "/api/water", water)
    ui.expose_api("POST", "/api/stop", stop)
    def chat(message: str):
        """Ask the on-board assistant. Blocking — local generation takes a
        while on a 1B model; clients should use a generous timeout."""
        if not ctx.assistant:
            return {"reply": None, "error": "assistant not available"}
        try:
            reply = ctx.assistant.ask(message)
            return {"reply": reply, "error": None}
        except Exception as e:  # model still loading, runner down, etc.
            return {"reply": None, "error": str(e)}

    def chat_stream(message: str):
        """Streamed variant: chunked plain text as the model generates.
        Consumed by the dashboard (fetch reader) and the iOS app
        (URLSession.bytes)."""
        from fastapi.responses import StreamingResponse

        def gen():
            if not ctx.assistant:
                yield "The assistant isn't available on this hub."
                return
            try:
                yield from ctx.assistant.ask_stream(message)
            except Exception as e:
                yield f"\n[assistant error: {e}]"

        return StreamingResponse(gen(), media_type="text/plain; charset=utf-8")

    def chat_reset():
        if ctx.assistant:
            ctx.assistant.reset()
        return {"accepted": True}

    ui.expose_api("POST", "/api/location", set_location)
    ui.expose_api("POST", "/api/chat", chat)
    ui.expose_api("POST", "/api/chat/stream", chat_stream)
    ui.expose_api("POST", "/api/chat/reset", chat_reset)

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
