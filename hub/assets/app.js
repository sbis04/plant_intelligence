// Dashboard client. Polls the REST API — no dependency on the WebSocket
// client library, so it works in any browser on the LAN.

const $ = (id) => document.getElementById(id);

const STATE_LABELS = {
  idle: "Idle",
  valve_opening: "Starting…",
  watering: "Watering",
  closing: "Finishing…",
};

async function refreshStatus() {
  try {
    const res = await fetch("/api/status");
    const data = await res.json();
    render(data);
    $("conn").textContent = "live";
    $("conn").classList.add("ok");
  } catch {
    $("conn").textContent = "offline";
    $("conn").classList.remove("ok");
  }
}

function render(data) {
  const s = data.status || {};
  $("soil").textContent = s.soil_pct != null ? `${Math.round(s.soil_pct)}%` : "no probe";
  $("temp").textContent = s.temperature_c != null ? `${s.temperature_c.toFixed(1)}°C` : "–";
  $("hum").textContent = s.humidity_pct != null ? `${Math.round(s.humidity_pct)}%` : "–";

  const state = STATE_LABELS[s.watering_state] || "–";
  const left = s.watering_seconds_left;
  $("wstate").textContent = state + (left > 0 ? ` ${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}` : "");
  $("wstate").classList.toggle("active", s.watering_state === "watering");

  const plan = data.plan;
  if (plan) {
    $("next").textContent = plan.water_now
      ? "due now"
      : plan.next_water_at
        ? new Date(plan.next_water_at).toLocaleString([], { weekday: "short", hour: "2-digit", minute: "2-digit" })
        : "–";
    const ul = $("reasons");
    ul.innerHTML = "";
    (plan.reasons || []).forEach((r) => {
      const li = document.createElement("li");
      li.textContent = r;
      ul.appendChild(li);
    });
  }

  const w = data.weather;
  $("weather").textContent = w
    ? `Weather: ${w.description || w.category || "–"}` +
      (w.temp_max_next12h != null ? ` · max ${Math.round(w.temp_max_next12h)}°C` : "") +
      (w.precip_prob_max_next12h != null ? ` · rain ${Math.round(w.precip_prob_max_next12h)}%` : "")
    : "Weather: unavailable";
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
        `<td>${started.toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}</td>` +
        `<td>${mins != null ? mins + " min" : "running"}</td>` +
        `<td class="trigger">${h.trigger}</td>`;
      tbody.appendChild(tr);
    });
  } catch { /* keep last rendering */ }
}

$("water-btn").addEventListener("click", async () => {
  await fetch("/api/water", { method: "POST" });
  refreshStatus();
});

$("stop-btn").addEventListener("click", async () => {
  await fetch("/api/stop", { method: "POST" });
  refreshStatus();
});

refreshStatus();
refreshHistory();
setInterval(refreshStatus, 3000);
setInterval(refreshHistory, 30000);
