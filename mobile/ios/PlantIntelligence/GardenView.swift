import PhotosUI
import SwiftUI

struct GardenView: View {
    @Environment(AppState.self) private var app
    @State private var confirmWater = false
    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @FocusState private var inputFocused: Bool

    private var s: DeviceStatus? { app.status?.status }
    private var plan: Plan? { app.status?.plan }
    private var weather: Weather? { app.status?.weather }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(alignment: .center) {
                        Text("Plants")
                            .font(.largeTitle.weight(.bold))
                        Spacer()
                        LinkBadge(link: app.link)
                    }
                    .padding(.top, 8)
                    hero
                    CameraCard()
                    tiles
                    planCard
                    if let w = weather { weatherCard(w) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
            }
            .background(GardenBackground())
            .topEdgeFade()
            .overlay {
                if app.assistantOpen {
                    AssistantOverlay()
                        .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if app.assistantOpen {
                    promptBar
                } else {
                    actionBar
                }
            }
            .refreshable {
                await app.refreshStatus()
                await app.refreshActivity()
            }
        }
    }

    // MARK: hero

    private var hero: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.16))
                    .frame(width: 64, height: 64)
                if heroProgress > 0 {
                    Circle()
                        .trim(from: 0, to: heroProgress)
                        .stroke(Theme.accent,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(-90))
                        .animation(.snappy, value: heroProgress)
                }
                Image(systemName: heroSymbol)
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, isActive: s?.isWatering == true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(heroTitle)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text(heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                if let loc = app.status?.location, let name = loc.name, !name.isEmpty {
                    Label(name, systemImage: "location.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var heroProgress: CGFloat {
        guard let s, s.isWatering, let left = s.wateringSecondsLeft,
              let plan, plan.durationS > 0 else { return 0 }
        return CGFloat(left) / CGFloat(plan.durationS)
    }

    // The hero states only what the system actually knows: its irrigation
    // status. A "plant health" claim belongs here only once something real
    // (soil probe, photo diagnosis) backs it.
    //
    // The hub decides what state it is in and says so in `plan.status`. This
    // used to be inferred here by looking for the word "rain" anywhere in
    // the reasons prose, which meant the hero read "Waiting out the rain"
    // through an entire monsoon regardless of the actual reason, and stayed
    // silent about wet soil or a garden watered by hand.
    private var status: String {
        plan?.status ?? ""
    }

    /// Still needed for the button's wording and tint: any hold at all.
    private var rainHold: Bool {
        ["rain_hold", "already_wet", "soil_hold"].contains(status)
    }

    private var heroSymbol: String {
        guard app.isConnected, let s else { return "antenna.radiowaves.left.and.right.slash" }
        if s.isWatering { return "drop.fill" }
        switch status {
        case "due": return "drop.circle"
        case "rain_hold": return "cloud.rain.fill"
        case "already_wet": return "humidity.fill"
        case "soil_hold": return "drop.fill"
        case "missed": return "clock.badge.exclamationmark"
        case "done": return "checkmark.circle.fill"
        default: return "leaf.fill"
        }
    }

    private var heroTitle: String {
        guard app.link != .offline else { return "Hub offline" }
        guard let s else { return "Connecting…" }
        if s.isWatering, let left = s.wateringSecondsLeft {
            return String(format: "Watering %d:%02d", left / 60, left % 60)
        }
        guard plan != nil else { return "Idle" }
        switch status {
        case "due": return "Watering due"
        case "rain_hold": return "Waiting out the rain"
        case "already_wet": return "Already watered"
        case "soil_hold": return "Soil still damp"
        case "missed": return "Missed a watering"
        case "done": return "Watered today"
        case "scheduled": return "On schedule"
        default: return plan?.waterNow == true ? "Watering due" : "On schedule"
        }
    }

    /// Says plainly that this is the mirror, and how far behind it is. A
    /// number here is worth more than the word "remote" on its own: half a
    /// minute is fine, twenty minutes means the hub has stopped reporting.
    private var remoteSubtitle: String {
        guard let age = app.remoteAgeSeconds else { return "away from home · via the cloud" }
        if age < 90 { return "away from home · updated just now" }
        let minutes = Int(age / 60)
        if minutes < 60 { return "away from home · updated \(minutes) min ago" }
        return "away from home · the hub last reported \(minutes / 60) h ago"
    }

    private var heroSubtitle: String {
        if let age = app.remoteAgeSeconds, age > RemoteFreshness.maximumAge {
            return remoteSubtitle
        }
        guard app.isConnected else { return "check the hub connection in Settings" }
        if app.link == .remote, s?.isWatering != true {
            return remoteSubtitle
        }
        if s?.isWatering == true { return "stop anytime below" }
        if let next = plan?.nextWaterDate {
            return "Next watering \(next.formatted(.relative(presentation: .named))) · "
                 + next.formatted(date: .omitted, time: .shortened)
        }
        return plan?.waterNow == true ? "starting shortly" : "no watering planned yet"
    }

    // MARK: tiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())],
                  spacing: 10) {
            StatTile(label: "Soil",
                     value: s?.soilPct.map { "\(Int($0))%" } ?? "Not connected",
                     detail: s?.soilPct == nil ? nil
                         : (s?.soilRaw).flatMap { $0 >= 0 ? "raw \($0)" : nil })
            StatTile(label: "Outside",
                     value: weather?.tempNowC.map { String(format: "%.1f°C", $0) } ?? "–",
                     detail: weather?.humidityNowPct.map { "humidity \(Int($0))%" })
            StatTile(label: "Box",
                     value: s?.boxTemperatureC.map { String(format: "%.1f°C", $0) }
                         ?? "Not connected",
                     detail: s?.boxTemperatureC == nil ? nil
                         : (s?.fanOn == true ? "fan on" : "fan off"),
                     active: s?.fanOn == true)
            StatTile(label: "MCU link",
                     value: s?.mcuSeenSecondsAgo.map { String(format: "%.0fs", $0) } ?? "–",
                     detail: "last heartbeat")
        }
    }

    // MARK: plan

    private var planCard: some View {
        PanelCard(title: "Next watering") {
            Text(nextWateringText)
                .font(.title3.weight(.semibold))
            if let reasons = plan?.reasons, !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(reasons, id: \.self) { r in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Theme.accent)
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            Text(r)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }
            Divider().overlay(Theme.line)
            kv("Planned duration",
               plan.map { "\(Int(round(Double($0.durationS) / 60))) min" } ?? "–")
            if let plan, plan.isFixed {
                kv("Schedule", plan.schedule ?? "–")
            } else {
                kv("Cadence interval", plan.map { "\($0.intervalH.formatted()) h" } ?? "–")
            }
        }
    }

    private var nextWateringText: String {
        guard let plan else { return "–" }
        if plan.waterNow { return "Due now" }
        guard let d = plan.nextWaterDate else { return "–" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private func weatherCard(_ w: Weather) -> some View {
        PanelCard(title: "Weather") {
            if let desc = w.displayDescription {
                Text(desc).font(.subheadline)
            }
            HStack(spacing: 14) {
                if let t = w.tempMaxNext12h {
                    Label(String(format: "max %.0f°C", t), systemImage: "thermometer.medium")
                }
                if let p = w.precipProbMaxNext12h {
                    Label("rain \(Int(p))%", systemImage: "cloud.rain")
                        .foregroundStyle(p >= 60 ? Theme.accent : .primary)
                }
                if w.isRainingNow == true {
                    Label("raining", systemImage: "umbrella")
                        .foregroundStyle(Theme.accent)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: actions — the floating Liquid Glass control layer

    private var actionBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if s?.isWatering == true {
                    Button {
                        Haptics.impact(.rigid)
                        Task { await app.stopWatering() }
                    } label: {
                        Label("Stop watering", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.err)
                } else {
                    waterNowButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .confirmationDialog("Water the garden now?", isPresented: $confirmWater,
                            titleVisibility: .visible) {
            Button("Start watering") {
                Haptics.impact(.rigid)
                Task { await app.waterNow() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs the pump for the planned duration. The hub enforces its own safety limits.")
        }
    }

    /// The hero action stays translucent so it belongs to the same floating
    /// control layer as the tab bar. When rain is already doing the work, the
    /// quieter treatment keeps the manual override from competing with the plan.
    private var waterNowButton: some View {
        Button {
            Haptics.impact(.medium, intensity: 0.85)
            confirmWater = true
        } label: {
            Label(rainHold ? "Water anyway" : "Water now", systemImage: "drop.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Theme.accent.opacity(rainHold ? 0.10 : 0.22),
                            Color.cyan.opacity(rainHold ? 0.07 : 0.16),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .glassEffect(.regular, in: .capsule)
        .shadow(color: Theme.accent.opacity(rainHold ? 0.06 : 0.14), radius: 8, y: 3)
        .disabled(!app.isConnected || app.remoteBusy)
        .opacity(app.isConnected && !app.remoteBusy ? 1 : 0.55)
    }

    // Replaces the watering bar while the assistant overlay is open;
    // the send button lives inside the prompt box.
    private var promptBar: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 0) {
                if let image = app.pendingAttachment {
                    HStack(spacing: 8) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 42)
                            .clipShape(.rect(cornerRadius: 8))
                        Button {
                            Haptics.impact(.soft)
                            app.pendingAttachment = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.top, 10)
                    .padding(.leading, 14)
                }
                HStack(spacing: 6) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: "paperclip")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 12)
                    TextField(app.assistantAvailable
                              ? "Ask the garden…" : "Available on home Wi-Fi",
                              text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .padding(.leading, 4)
                        .padding(.vertical, 10)
                        .onSubmit(send)
                if app.assistantBusy {
                    Button {
                        Haptics.impact(.rigid)
                        app.stopAsking()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.err)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(!app.assistantAvailable
                              || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.trailing, 8)
                }
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .disabled(!app.assistantAvailable)
        .opacity(app.assistantAvailable ? 1 : 0.58)
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    app.setAttachment(image)
                    Haptics.notification(.success)
                }
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard app.assistantAvailable, !text.isEmpty else { return }
        Haptics.impact(.soft)
        draft = ""
        inputFocused = false
        Task { await app.ask(text) }
    }
}

struct LinkBadge: View {
    let link: AppState.Link

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var color: Color {
        switch link {
        case .live: Theme.accent
        // Away from home is a working state, not a warning — but it is
        // visibly not the same as being on the LAN.
        case .remote: Theme.accent.opacity(0.65)
        case .connecting: Theme.warn
        case .offline: Theme.err
        }
    }

    private var text: String {
        switch link {
        case .live: "live"
        case .remote: "remote"
        case .connecting: "connecting"
        case .offline: "offline"
        }
    }
}
