import SwiftUI

struct GardenView: View {
    @Environment(AppState.self) private var app
    @State private var confirmWater = false

    private var s: DeviceStatus? { app.status?.status }
    private var plan: Plan? { app.status?.plan }
    private var weather: Weather? { app.status?.weather }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    tiles
                    planCard
                    if let w = weather { weatherCard(w) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
            }
            .background(GardenBackground())
            .navigationTitle("Garden")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    LinkBadge(link: app.link)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .refreshable {
                await app.refreshStatus()
                await app.refreshActivity()
            }
        }
    }

    // MARK: hero

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Theme.line, lineWidth: 10)
                    .frame(width: 150, height: 150)
                Circle()
                    .trim(from: 0, to: heroProgress)
                    .stroke(Theme.accent,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: heroProgress)
                VStack(spacing: 2) {
                    Image(systemName: heroSymbol)
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse, isActive: s?.isWatering == true)
                    Text(heroTitle)
                        .font(.headline)
                    Text(heroSubtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            if let loc = app.status?.location, let name = loc.name, !name.isEmpty {
                Label(name, systemImage: "location.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var heroProgress: CGFloat {
        guard let s else { return 0 }
        if s.isWatering, let left = s.wateringSecondsLeft, let plan,
           plan.durationS > 0 {
            return CGFloat(left) / CGFloat(plan.durationS)
        }
        return app.link == .live ? 1 : 0
    }

    private var heroSymbol: String {
        guard let s else { return "leaf" }
        return s.isWatering ? "drop.fill" : "leaf.fill"
    }

    private var heroTitle: String {
        guard let s else { return "Connecting…" }
        if s.isWatering, let left = s.wateringSecondsLeft {
            return String(format: "%d:%02d", left / 60, left % 60)
        }
        return "Healthy"
    }

    private var heroSubtitle: String {
        guard let s else { return "" }
        if s.isWatering { return "watering" }
        if let next = plan?.nextWaterDate {
            return "next " + next.formatted(.relative(presentation: .named))
        }
        return plan?.waterNow == true ? "watering due" : "idle"
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
                    Button {
                        confirmWater = true
                    } label: {
                        Label("Water now", systemImage: "drop.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(app.link != .live)
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
}

struct LinkBadge: View {
    let link: AppState.Link

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption2.weight(.medium))
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
