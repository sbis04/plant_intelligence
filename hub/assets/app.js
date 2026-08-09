// Dashboard client. Polls the REST API — no dependency on the WebSocket
// client library, so it works in any browser on the LAN.

const $ = (id) => document.getElementById(id);

const STATE_LABELS = {
  idle: "Idle",
  valve_opening: "Starting…",
  watering: "Watering",
  closing: "Finishing…",
};

const fmtC = (v) => (v != null ? `${Number(v).toFixed(1)}°C` : "–");
const fmtPct = (v) => (v != null ? `${Math.round(v)}%` : "–");

async function refreshStatus() {
  try {
    const res = await fetch("/api/status");
    render(await res.json());
    $("conn").textContent = "live";
    $("conn").classList.add("ok");
  } catch {
    $("conn").textContent = "offline";
    $("conn").classList.remove("ok");
  }
}

function render(data) {
  const s = data.status || {};
  const w = data.weather || {};
  const loc = data.location || {};

  // header
  const srcLabel = { ip: "auto-located", manual: "set manually", device: "from device" };
  $("location").textContent =
    (loc.name ? `${loc.name} · ${srcLabel[loc.source] || loc.source}` : "location unknown") + " ✎";

  // tiles
  $("soil").textContent = s.soil_pct != null ? fmtPct(s.soil_pct) : "no probe";
  $("soil-raw").textContent = s.soil_raw >= 0 ? `raw ${s.soil_raw}` : "not installed";

  $("outside").textContent = fmtC(w.temp_now_c);
  $("outside-detail").textContent =
    w.humidity_now_pct != null ? `humidity ${fmtPct(w.humidity_now_pct)}` : "–";

  $("box").textContent = fmtC(s.box_temperature_c);
  $("fan").textContent = s.fan_on ? "fan on" : "fan off";
  $("fan").classList.toggle("on", !!s.fan_on);

  const state = STATE_LABELS[s.watering_state] || "–";
  const left = s.watering_seconds_left;
  $("wstate").textContent =
    state + (left > 0 ? ` ${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}` : "");
  $("wstate").classList.toggle("active", s.watering_state === "watering");
  $("mcu-link").textContent =
    s.mcu_seen_seconds_ago != null ? `mcu ${s.mcu_seen_seconds_ago}s ago` : "mcu –";

  // plan card
  const plan = data.plan;
  if (plan) {
    $("next").textContent = plan.water_now
      ? "due now"
      : plan.next_water_at
        ? new Date(plan.next_water_at).toLocaleString([], {
            weekday: "short", hour: "2-digit", minute: "2-digit",
          })
        : "–";
    const ul = $("reasons");
    ul.innerHTML = "";
    (plan.reasons || []).forEach((r) => {
      const li = document.createElement("li");
      li.textContent = r;
      ul.appendChild(li);
    });
    $("plan-duration").textContent = `${Math.round(plan.duration_s / 60)} min`;
    $("plan-interval").textContent = `${plan.interval_h} h`;
  }

  // environment card
  $("env-cond").textContent = w.description || w.category || "–";
  $("env-temp").textContent = fmtC(w.temp_now_c);
  $("env-hum").textContent = fmtPct(w.humidity_now_pct);
  $("env-max").textContent = fmtC(w.temp_max_next12h);
  $("env-rain").textContent =
    fmtPct(w.precip_prob_max_next12h) + (w.is_raining_now ? " · raining" : "");
  $("env-box-temp").textContent = fmtC(s.box_temperature_c);
  $("env-box-hum").textContent = fmtPct(s.box_humidity_pct);
  $("env-fan").textContent = s.fan_on ? "on" : "off";
  $("env-fan").classList.toggle("on", !!s.fan_on);
}

async function refreshHistory() {
  try {
    const res = await fetch("/api/history");
    const { history } = await res.json();
    const tbody = $("history").querySelector("tbody");
    tbody.innerHTML = "";
    (history || []).slice(0, 8).forEach((h) => {
      const tr = document.createElement("tr");
      const started = new Date(h.water_started_at);
      const mins = h.water_ended_at
        ? Math.max(1, Math.round((new Date(h.water_ended_at) - started) / 60000))
        : null;
      tr.innerHTML =
        `<td class="time">${started.toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}</td>` +
        `<td>${mins != null ? mins + " min" : "running"}</td>` +
        `<td class="trigger">${h.trigger}</td>`;
      tbody.appendChild(tr);
    });
  } catch { /* keep last rendering */ }
}

async function refreshLog() {
  try {
    const res = await fetch("/api/logs");
    const { logs } = await res.json();
    const tbody = $("log").querySelector("tbody");
    tbody.innerHTML = "";
    (logs || []).slice(0, 10).forEach((l) => {
      const tr = document.createElement("tr");
      const t = new Date(l.timestamp);
      tr.innerHTML =
        `<td class="time">${t.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</td>` +
        `<td class="${l.is_error ? "err" : ""}">${l.message}</td>` +
        `<td class="trigger">${l.event_type}</td>`;
      tbody.appendChild(tr);
    });
  } catch { /* keep last rendering */ }
}

$("location").addEventListener("click", async () => {
  const input = prompt("Garden location — place name, or \"lat, lon\":");
  if (!input) return;
  const coords = input.match(/^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$/);
  const params = coords
    ? `latitude=${coords[1]}&longitude=${coords[2]}&source=manual&name=${encodeURIComponent(input.trim())}`
    : `place=${encodeURIComponent(input.trim())}`;
  const res = await fetch(`/api/location?${params}`, { method: "POST" });
  const out = await res.json();
  if (!out.accepted) alert(out.error || "could not set location");
  refreshStatus();
});

$("water-btn").addEventListener("click", async () => {
  await fetch("/api/water", { method: "POST" });
  refreshStatus();
  refreshHistory();
});

$("stop-btn").addEventListener("click", async () => {
  await fetch("/api/stop", { method: "POST" });
  refreshStatus();
  refreshHistory();
});

refreshStatus();
refreshHistory();
refreshLog();
setInterval(refreshStatus, 3000);
setInterval(refreshHistory, 30000);
setInterval(refreshLog, 15000);
