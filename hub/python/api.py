"""Local HTTP + WebSocket API, served by the web_ui Brick.

This is the surface the mobile app talks to over the LAN, and it also backs
the built-in dashboard in assets/. REST for request/response, a WebSocket
"telemetry" event for live updates.

Endpoints:
  GET  /api/status    → live sensors, watering state, current plan, weather
  GET  /api/history   → recent watering events (Firestore-shaped documents)
  GET  /api/logs      → recent system log entries
  GET  /api/config    → active configuration
  POST /api/water     → start a manual watering (default duration)
  POST /api/stop      → stop watering now

Handlers take *args/**kwargs so they keep working whether or not the Brick
passes request details positionally.
"""


def register(ui, ctx):
    """Wire endpoints onto the WebUI brick. `ctx` is the AppContext from main."""

    def status(*_a, **_k):
        snap = ctx.hardware.snapshot()
        cfg = ctx.config
        snap["soil_pct"] = cfg.soil_raw_to_pct(snap.get("soil_raw", -1))
        return {
            "status": snap,
            "plan": ctx.current_plan.to_dict() if ctx.current_plan else None,
            "weather": ctx.current_weather.to_dict() if ctx.current_weather else None,
        }

    def history(*_a, **_k):
        return {"history": ctx.store.recent_history(30)}

    def logs(*_a, **_k):
        return {"logs": ctx.store.recent_logs(50)}

    def get_config(*_a, **_k):
        from dataclasses import asdict
        return {"config": asdict(ctx.config)}

    def water(*args, **kwargs):
        duration_s = ctx.config.base_duration_s
        # Accept a duration if the transport handed us one, any shape.
        for candidate in list(args) + [kwargs]:
            if isinstance(candidate, dict) and "duration_s" in candidate:
                try:
                    duration_s = int(candidate["duration_s"])
                except (TypeError, ValueError):
                    pass
        duration_s = max(ctx.config.min_duration_s,
                         min(ctx.config.max_duration_s, duration_s))
        ok = ctx.request_manual_watering(duration_s)
        return {"accepted": ok, "duration_s": duration_s}

    def stop(*_a, **_k):
        ctx.hardware.stop_watering()
        ctx.store.log("OVERRIDE", "Manual stop requested via API")
        return {"accepted": True}

    def set_location(*args, **kwargs):
        """Precise fix from a client — e.g. the mobile app sending phone GPS."""
        payload = kwargs
        for candidate in args:
            if isinstance(candidate, dict):
                payload = {**candidate, **payload}
        try:
            lat, lon = float(payload["latitude"]), float(payload["longitude"])
        except (KeyError, TypeError, ValueError):
            return {"accepted": False, "error": "latitude and longitude required"}
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            return {"accepted": False, "error": "coordinates out of range"}
        ctx.set_location(lat, lon,
                         source=str(payload.get("source", "device")),
                         name=str(payload.get("name", "")))
        return {"accepted": True, "latitude": lat, "longitude": lon}

    ui.expose_api("GET", "/api/status", status)
    ui.expose_api("GET", "/api/history", history)
    ui.expose_api("GET", "/api/logs", logs)
    ui.expose_api("GET", "/api/config", get_config)
    ui.expose_api("POST", "/api/water", water)
    ui.expose_api("POST", "/api/stop", stop)
    ui.expose_api("POST", "/api/location", set_location)

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
    })
