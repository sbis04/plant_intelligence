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

  // assistant badge reflects the actual backend
  const ai = data.assistant || {};
  assistantBackend = ai.cloud_configured
    ? (ai.last_backend === "local" ? "local" : "cloud") : "local";
  $("assistant-chip").textContent = ai.cloud_configured
    ? (ai.last_backend === "local" ? "cloud · offline fallback" : "Gemini Flash")
    : "on-device LLM";

  // header — click to edit
  $("location").textContent = loc.name || "set location";

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

// ---- assistant ------------------------------------------------------------
const chatBox = $("chat-messages");
let chatBusy = false;
let assistantBackend = "local";
let currentThread = 0;   // 0 = the hub creates a thread on the first message

const EMPTY_HTML = '<p class="chat-empty">Ask anything about your garden — ' +
  'grounded in live access to all system data.</p>';

async function loadThreads(selectLatest = false) {
  try {
    const res = await fetch("/api/chat/threads");
    const { threads } = await res.json();
    const sel = $("thread-select");
    sel.innerHTML = "";
    for (const t of threads) {
      const o = document.createElement("option");
      o.value = t.id;
      o.textContent = t.title || `Conversation ${t.id}`;
      sel.appendChild(o);
    }
    if (selectLatest) currentThread = threads.length ? threads[0].id : 0;
    if (currentThread) sel.value = String(currentThread);
    return threads;
  } catch { return []; }
}

async function openThread(id) {
  currentThread = id;
  chatBox.innerHTML = EMPTY_HTML;
  $("chat-suggest").style.display = "";
  if (!id) return;
  try {
    const res = await fetch(`/api/chat/thread?id=${id}`);
    const { messages } = await res.json();
    if (messages && messages.length) {
      chatBox.innerHTML = "";
      for (const m of messages) {
        addMsg(m.content, m.role === "user" ? "user" : "bot",
               m.attachment ? `/api/chat/attachment?id=${m.attachment}` : null);
      }
      $("chat-suggest").style.display = "none";
    }
  } catch { /* keep empty state */ }
}

$("thread-select").addEventListener("change", (e) =>
  openThread(Number(e.target.value)));
$("thread-new").addEventListener("click", () => {
  currentThread = 0;
  $("thread-select").value = "";
  chatBox.innerHTML = EMPTY_HTML;
  $("chat-suggest").style.display = "";
});
$("thread-delete").addEventListener("click", async () => {
  if (!currentThread) return;
  await fetch(`/api/chat/thread/delete?id=${currentThread}`, { method: "POST" });
  const threads = await loadThreads(true);
  openThread(threads.length ? threads[0].id : 0);
});

// resume the most recent conversation on page load
loadThreads(true).then(() => { if (currentThread) openThread(currentThread); });

function addMsg(text, cls, imgURL = null) {
  const empty = chatBox.querySelector(".chat-empty");
  if (empty) empty.remove();
  const div = document.createElement("div");
  div.className = `msg ${cls}`;
  if (imgURL) {
    const img = document.createElement("img");
    img.src = imgURL;
    img.alt = "Attached photo";
    div.appendChild(img);
    const span = document.createElement("span");
    span.textContent = text;
    div.appendChild(span);
  } else {
    div.textContent = text;
  }
  chatBox.appendChild(div);
  chatBox.scrollTop = chatBox.scrollHeight;
  return div;
}

async function askAssistant(question) {
  if (chatBusy || !question.trim()) return;
  chatBusy = true;
  $("chat-send").disabled = true;
  $("chat-suggest").style.display = "none";

  // upload the attached photo first; it rides along by id
  let attachId = "";
  if (attachFile) {
    try {
      const up = await fetch("/api/chat/attach", { method: "POST", body: attachFile });
      attachId = (await up.json()).id || "";
    } catch { /* send without it */ }
    clearAttachment();
  }
  addMsg(question, "user",
         attachId ? `/api/chat/attachment?id=${attachId}` : null);
  const pending = addMsg("thinking…", "bot thinking");
  // Honest waiting: show elapsed time plus which backend is actually
  // answering (the status poll keeps assistantBackend current even while
  // a reply is being generated).
  const started = Date.now();
  const ticker = setInterval(() => {
    if (!pending.classList.contains("thinking")) return;
    const s = Math.round((Date.now() - started) / 1000);
    const via = assistantBackend === "local" ? " · on-device" : "";
    pending.textContent = `thinking… ${s}s${via}` +
      (assistantBackend === "local" && s > 75
        ? " (first answer after a restart takes the longest)" : "");
  }, 1000);
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 300000);
    const res = await fetch(
      `/api/chat/stream?message=${encodeURIComponent(question)}` +
      `&thread_id=${currentThread}&attachment_id=${attachId}`,
      { method: "POST", signal: ctrl.signal });
    const tid = Number(res.headers.get("X-Thread-Id") || 0);
    if (tid) currentThread = tid;
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let text = "";
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      text += decoder.decode(value, { stream: true });
      pending.classList.remove("thinking");
      pending.textContent = text;
      chatBox.scrollTop = chatBox.scrollHeight;
    }
    clearTimeout(timer);
    if (!text.trim()) {
      pending.classList.add("error");
      pending.textContent = "no reply";
    }
  } catch {
    pending.classList.remove("thinking");
    pending.classList.add("error");
    pending.textContent = "assistant unreachable";
  }
  clearInterval(ticker);
  chatBusy = false;
  $("chat-send").disabled = false;
  loadThreads();   // pick up the auto-title / recency reorder
}

$("chat-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const q = $("chat-input").value;
  $("chat-input").value = "";
  $("chat-input").style.height = "auto";
  askAssistant(q);
});

// ---- photo attachments ------------------------------------------------------
let attachFile = null;

$("chat-attach").addEventListener("click", () => $("attach-input").click());
$("attach-input").addEventListener("change", () => {
  const f = $("attach-input").files[0];
  if (!f) return;
  attachFile = f;
  $("attach-img").src = URL.createObjectURL(f);
  $("attach-preview").hidden = false;
});
$("attach-remove").addEventListener("click", clearAttachment);

function clearAttachment() {
  attachFile = null;
  $("attach-input").value = "";
  const img = $("attach-img");
  if (img.src) URL.revokeObjectURL(img.src);
  img.removeAttribute("src");
  $("attach-preview").hidden = true;
}

// Enter sends, Shift+Enter makes a newline; the box grows with the text.
$("chat-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    $("chat-form").requestSubmit();
  }
});
$("chat-input").addEventListener("input", () => {
  const t = $("chat-input");
  t.style.height = "auto";
  t.style.height = `${Math.min(t.scrollHeight, 120)}px`;
  t.style.overflowY = t.scrollHeight > 120 ? "auto" : "hidden";
});

document.querySelectorAll(".chip-btn").forEach((b) =>
  b.addEventListener("click", () => askAssistant(b.textContent)));

const panel = $("assistant-panel");
$("assistant-open").addEventListener("click", () => panel.classList.add("open"));
$("assistant-close").addEventListener("click", () => panel.classList.remove("open"));

// resizable drawer: drag the left edge; width persisted
const savedW = localStorage.getItem("assistantWidth");
if (savedW) panel.style.setProperty("--panel-w", `${savedW}px`);
$("panel-resize").addEventListener("pointerdown", (e) => {
  e.preventDefault();
  panel.classList.add("resizing");
  const onMove = (ev) => {
    const w = Math.min(640, Math.max(300, window.innerWidth - ev.clientX));
    panel.style.setProperty("--panel-w", `${w}px`);
  };
  const onUp = (ev) => {
    panel.classList.remove("resizing");
    const w = Math.min(640, Math.max(300, window.innerWidth - ev.clientX));
    localStorage.setItem("assistantWidth", String(Math.round(w)));
    window.removeEventListener("pointermove", onMove);
    window.removeEventListener("pointerup", onUp);
  };
  window.addEventListener("pointermove", onMove);
  window.addEventListener("pointerup", onUp);
});

// ---- device stats footer ----------------------------------------------------
const GB = 1024 ** 3;
async function refreshSystem() {
  try {
    const res = await fetch("/api/system");
    const { system } = await res.json();
    if (!system || system.error) return;
    $("dev-cpu").textContent = `CPU ${system.cpu_percent}%`;
    $("dev-cpu").classList.toggle("hot", system.cpu_percent >= 85);
    const t = system.soc_temperature_c;
    $("dev-temp").textContent = t != null ? `SOC ${t.toFixed(1)}°C` : "SOC –";
    $("dev-temp").classList.toggle("hot", t != null && t >= 75);
    const m = system.memory;
    $("dev-ram").textContent =
      `RAM ${(m.used_bytes / GB).toFixed(2)}/${(m.total_bytes / GB).toFixed(2)}GB`;
    const s = system.storage;
    $("dev-disk").textContent =
      `DISK ${(s.root_used_bytes / GB).toFixed(1)}/${(s.root_total_bytes / GB).toFixed(1)}GB`;
  } catch { /* footer keeps last values */ }
}

// ---- garden camera ----------------------------------------------------------
// The card refreshes a snapshot once a minute (each fetch is an RTSP
// round-trip to the camera). The enlarged dialog switches to the MJPEG live
// stream instead; if the stream fails it falls back to 3 s snapshot polling.
let cameraTimer = null;
let cameraFallback = false;

async function refreshCamera() {
  try {
    const res = await fetch(`/api/camera/snapshot?t=${Date.now()}`);
    const type = res.headers.get("content-type") || "";
    if (!type.startsWith("image/")) { $("camera-card").style.display = "none"; return; }
    const blob = await res.blob();
    const img = $("camera-img");
    const old = img.dataset.url;
    img.src = img.dataset.url = URL.createObjectURL(blob);
    if (!$("camera-modal").hidden && cameraFallback) {
      $("camera-modal-img").src = img.src;
    }
    if (old) URL.revokeObjectURL(old);
    $("camera-card").style.display = "";
  } catch { /* keep card hidden/stale */ }
}

function scheduleCamera() {
  clearInterval(cameraTimer);
  const fast = !$("camera-modal").hidden && cameraFallback;
  cameraTimer = setInterval(refreshCamera, fast ? 3000 : 60000);
}

// Preferred live path: HLS relayed from the camera's own H.264 stream —
// full 2K at native fps, no transcoding on the board. Falls back to the
// MJPEG stream, then to snapshot polling.
let hlsPlayer = null;

function startLiveVideo(video) {
  const src = "/api/camera/live.m3u8";
  video.style.display = "none";   // snapshot stays until real frames play
  video.addEventListener("playing", () => { video.style.display = ""; },
                         { once: true });
  if (video.canPlayType("application/vnd.apple.mpegurl")) {   // Safari
    video.onerror = () => fallbackToMjpeg();
    video.src = src;
    video.play().catch(() => {});
    return true;
  }
  if (window.Hls && Hls.isSupported()) {
    hlsPlayer = new Hls();
    hlsPlayer.on(Hls.Events.ERROR, (_e, data) => {
      if (data.fatal) fallbackToMjpeg();
    });
    hlsPlayer.loadSource(src);
    hlsPlayer.attachMedia(video);
    return true;
  }
  return false;
}

function stopLiveVideo() {
  const video = $("camera-modal-video");
  if (hlsPlayer) { hlsPlayer.destroy(); hlsPlayer = null; }
  video.onerror = null;
  video.pause();
  video.removeAttribute("src");
  video.load();
  video.style.display = "none";
}

function fallbackToMjpeg() {
  stopLiveVideo();
  const simg = $("camera-modal-stream");
  simg.style.display = "";
  simg.onerror = () => {                          // stream down → poll snapshots
    simg.onerror = null;
    simg.style.display = "none";
    cameraFallback = true;
    scheduleCamera();
    refreshCamera();
  };
  simg.src = `/api/camera/stream?t=${Date.now()}`;
}

function setCameraModal(open) {
  const mimg = $("camera-modal-img");     // base: last snapshot, shows instantly
  const simg = $("camera-modal-stream");  // MJPEG fallback overlay
  $("camera-modal").hidden = !open;
  if (open) {
    cameraFallback = false;
    mimg.src = $("camera-img").src;
    if (!startLiveVideo($("camera-modal-video"))) fallbackToMjpeg();
  } else {
    stopLiveVideo();
    simg.onerror = null;
    simg.src = "";                                // closes the RTSP session
    simg.style.display = "none";
    mimg.src = "";
    cameraFallback = false;
  }
  scheduleCamera();
}

$("camera-img").addEventListener("click", () => setCameraModal(true));
$("camera-modal-close").addEventListener("click", () => setCameraModal(false));
$("camera-modal").addEventListener("click", (e) => {
  if (e.target === $("camera-modal")) setCameraModal(false);
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("camera-modal").hidden) setCameraModal(false);
});

refreshStatus();
refreshHistory();
refreshLog();
refreshSystem();
refreshCamera();
scheduleCamera();
setInterval(refreshStatus, 3000);
setInterval(refreshHistory, 30000);
setInterval(refreshLog, 15000);
setInterval(refreshSystem, 10000);
