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
            .toolbar(.hidden, for: .navigationBar)
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
    private var rainHold: Bool {
        plan?.reasons.contains { $0.localizedCaseInsensitiveContains("rain") } ?? false
    }

    private var heroSymbol: String {
        guard app.link == .live, let s else { return "antenna.radiowaves.left.and.right.slash" }
        if s.isWatering { return "drop.fill" }
        if plan?.waterNow == true { return "drop.circle" }
        if rainHold { return "cloud.rain.fill" }
        return "leaf.fill"
    }

    private var heroTitle: String {
        guard app.link != .offline else { return "Hub offline" }
        guard let s else { return "Connecting…" }
        if s.isWatering, let left = s.wateringSecondsLeft {
            return String(format: "Watering %d:%02d", left / 60, left % 60)
        }
        guard plan != nil else { return "Idle" }
        if plan?.waterNow == true { return "Watering due" }
        if rainHold { return "Waiting out the rain" }
        return "On schedule"
    }

    private var heroSubtitle: String {
        guard app.link == .live else { return "check the hub connection in Settings" }
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
                     value: s?.soilPct.map { "\(Int($0))%" } ?? "no probe",
                     detail: (s?.soilRaw).flatMap { $0 >= 0 ? "raw \($0)" : nil })
            StatTile(label: "Outside",
                     value: weather?.tempNowC.map { String(format: "%.1f°C", $0) } ?? "–",
                     detail: weather?.humidityNowPct.map { "humidity \(Int($0))%" })
            StatTile(label: "Box",
                     value: s?.boxTemperatureC.map { String(format: "%.1f°C", $0) } ?? "–",
                     detail: s?.fanOn == true ? "fan on" : "fan off",
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
            kv("Cadence interval", plan.map { "\($0.intervalH.formatted()) h" } ?? "–")
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
            if let desc = w.description {
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
            Button("Start watering") { Task { await app.waterNow() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs the pump for the planned duration. The hub enforces its own safety limits.")
        }
    }

    /// The hero action: Liquid Glass with a living water tint — a translucent
    /// animated mesh of greens and aquas drifting over the glass.
    private var waterNowButton: some View {
        Button {
            confirmWater = true
        } label: {
            Label("Water now", systemImage: "drop.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .background {
            // Extra frosting: a material layer under the tint deepens the
            // blur of whatever scrolls behind the glass.
            Capsule().fill(.thinMaterial)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0],
                        [0.5 + 0.22 * Float(sin(t * 0.7)), 0],
                        [1, 0],
                        [0, 0.5 + 0.28 * Float(cos(t * 0.6))],
                        [0.5 + 0.3 * Float(sin(t * 0.8)),
                         0.5 + 0.3 * Float(cos(t * 0.9))],
                        [1, 0.5 - 0.28 * Float(sin(t * 0.5))],
                        [0, 1],
                        [0.5 - 0.22 * Float(cos(t * 0.7)), 1],
                        [1, 1],
                    ],
                    colors: [
                        Color(red: 0.10, green: 0.45, blue: 0.72),
                        Color(red: 0.18, green: 0.65, blue: 0.90),
                        Color(red: 0.08, green: 0.52, blue: 0.68),
                        Color(red: 0.16, green: 0.70, blue: 0.86),
                        Color(red: 0.24, green: 0.74, blue: 0.96),
                        Color(red: 0.06, green: 0.38, blue: 0.60),
                        Color(red: 0.12, green: 0.58, blue: 0.80),
                        Color(red: 0.20, green: 0.78, blue: 0.92),
                        Color(red: 0.09, green: 0.48, blue: 0.70),
                    ])
                    .opacity(0.55)
                    .clipShape(Capsule())
            }
        }
        .glassEffect(.regular, in: .capsule)
        .shadow(color: Color(red: 0.2, green: 0.6, blue: 0.9).opacity(0.35),
                radius: 12, y: 4)
        .disabled(app.link != .live)
        .opacity(app.link == .live ? 1 : 0.55)
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
                    TextField("Ask the garden…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .padding(.leading, 4)
                        .padding(.vertical, 10)
                        .onSubmit(send)
                if app.assistantBusy {
                    Button {
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
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.trailing, 8)
                }
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    app.setAttachment(image)
                }
            }
        }
    }

    private func send() {
        let text = draft
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
        case .connecting: Theme.warn
        case .offline: Theme.err
        }
    }

    private var text: String {
        switch link {
        case .live: "live"
        case .connecting: "connecting"
        case .offline: "offline"
        }
    }
}
