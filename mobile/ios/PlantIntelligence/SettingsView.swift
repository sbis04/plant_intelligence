import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var address = ""
    @State private var testResult: String?
    @State private var scheduleMode = "adaptive"
    @State private var scheduleBusy = false
    @State private var scheduleResult: String?
    @State private var confirmRestart = false
    @State private var restartBusy = false
    @State private var restartResult: String?
    @State private var place = ""
    @State private var locationResult: String?
    @State private var apiKey = ""
    @State private var assistantResult: String?
    @State private var pushResult: String?
    @State private var notificationsAllowed = false
    @State private var liveActivitiesOn = false
    @State private var remotePairingResult: String?
    @State private var remotePairingBusy = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        Text("Settings")
                            .font(.largeTitle.weight(.bold))
                        Spacer()
                    }
                    .padding(.top, 8)

                    PanelCard(title: "Hub connection") {
                        TextField("192.168.68.64:7000", text: $address)
                            .textFieldStyle(.plain)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(Theme.bg, in: .rect(cornerRadius: 10))
                        HStack {
                            Button("Save & test") {
                                Haptics.impact(.light)
                                app.hubAddress = address
                                Task {
                                    await app.refreshStatus()
                                    testResult = app.link == .live
                                        ? "Connected ✓" : "Could not reach the hub"
                                    Haptics.notification(app.link == .live ? .success : .error)
                                }
                            }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.accent)
                            if let testResult {
                                Text(testResult)
                                    .font(.caption)
                                    .foregroundStyle(
                                        testResult.hasSuffix("✓") ? Theme.accent : Theme.err)
                            }
                        }
                    }

                    PanelCard(title: "Watering schedule") {
                        Picker("Schedule", selection: $scheduleMode) {
                            Text("Adaptive").tag("adaptive")
                            Text("Fixed · 7 AM & 5 PM").tag("fixed")
                        }
                        .pickerStyle(.segmented)
                        .disabled(scheduleBusy || !app.isConnected)
                        .onChange(of: scheduleMode) { _, mode in
                            guard mode != app.scheduleMode else { return }
                            Haptics.impact(.light)
                            scheduleBusy = true
                            Task {
                                let error = await app.setScheduleMode(mode)
                                scheduleBusy = false
                                if let error {
                                    scheduleResult = error
                                    scheduleMode = app.scheduleMode
                                    Haptics.notification(.error)
                                } else {
                                    scheduleResult = nil
                                    Haptics.notification(.success)
                                }
                            }
                        }
                        .onAppear { scheduleMode = app.scheduleMode }
                        .onChange(of: app.scheduleMode) { _, mode in
                            if !scheduleBusy { scheduleMode = mode }
                        }
                        if let scheduleResult {
                            Text(scheduleResult)
                                .font(.caption)
                                .foregroundStyle(Theme.err)
                        }
                        Text(scheduleMode == "fixed"
                             ? "Waters for 5 minutes at 7 AM and 5 PM every day. Soil moisture, the forecast and the camera are not consulted."
                             : "Soil moisture, the forecast and the camera decide when and how long to water.")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }

                    PanelCard(title: "Hub") {
                        Button(role: .destructive) {
                            confirmRestart = true
                        } label: {
                            Label(restartBusy ? "Restarting…" : "Restart hub",
                                  systemImage: "arrow.clockwise.circle")
                        }
                        .buttonStyle(.glass)
                        .disabled(restartBusy || !app.isConnected)
                        .confirmationDialog(
                            "Restart the hub?", isPresented: $confirmRestart,
                            titleVisibility: .visible
                        ) {
                            Button("Restart", role: .destructive) {
                                restartBusy = true
                                Task {
                                    let result = await app.restartHub()
                                    restartBusy = false
                                    restartResult = result.message
                                    Haptics.notification(result.accepted ? .success : .error)
                                }
                            }
                        } message: {
                            Text("The hub will be offline for about two minutes. Watering in progress is never interrupted — the hub refuses while the pump is running.")
                        }
                        if let restartResult {
                            Text(restartResult)
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                        }
                        Text("For when something is stuck. Restarts the whole hub app, including the microcontroller firmware, the same way the automatic watchdog does.")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }

                    PanelCard(title: "Location") {
                        if app.link != .live {
                            Label("Changes require the home Wi-Fi.", systemImage: "wifi")
                                .font(.caption)
                                .foregroundStyle(Theme.warn)
                        }
                        if let loc = app.status?.location {
                            kv("Current", loc.name?.isEmpty == false ? loc.name! : "unknown")
                            kv("Source", sourceLabel(loc.source))
                        }
                        TextField("Place name, e.g. Kolkata", text: $place)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(Theme.bg, in: .rect(cornerRadius: 10))
                        HStack {
                            Button("Set location") {
                                Haptics.impact(.light)
                                Task {
                                    guard let client = app.client else {
                                        Haptics.notification(.error)
                                        return
                                    }
                                    let res = try? await client.setLocation(place: place)
                                    locationResult = res?.accepted == true
                                        ? "Set to \(res?.name ?? place) ✓"
                                        : (res?.error ?? "failed")
                                    if res?.accepted == true { place = "" }
                                    await app.refreshStatus()
                                    Haptics.notification(
                                        res?.accepted == true ? .success : .error)
                                }
                            }
                            .buttonStyle(.glass)
                            .disabled(place.trimmingCharacters(in: .whitespaces).isEmpty)
                            .disabled(app.link != .live)
                            if let locationResult {
                                Text(locationResult)
                                    .font(.caption)
                                    .foregroundStyle(
                                        locationResult.hasSuffix("✓") ? Theme.accent : Theme.err)
                            }
                        }
                        Text("A manually set location is remembered across hub reboots and never overwritten by auto-detection.")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }

                    PanelCard(title: "Assistant") {
                        if app.link != .live {
                            Label("Configuration requires the home Wi-Fi.", systemImage: "wifi")
                                .font(.caption)
                                .foregroundStyle(Theme.warn)
                        }
                        let info = app.status?.assistant
                        kv("Mode", info?.cloudConfigured == true
                            ? "cloud when online, on-device offline"
                            : "on-device only")
                        if let backend = info?.lastBackend, info?.cloudConfigured == true {
                            kv("Last answer from", backend == "cloud" ? "Gemini Flash" : "UNO Q")
                        }
                        SecureField("Gemini API key", text: $apiKey)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(Theme.bg, in: .rect(cornerRadius: 10))
                        HStack {
                            Button("Save key") {
                                Haptics.impact(.light)
                                Task {
                                    guard let client = app.client else {
                                        Haptics.notification(.error)
                                        return
                                    }
                                    let res = try? await client.setAssistantConfig(apiKey: apiKey)
                                    assistantResult = res?.accepted == true ? "Saved ✓" : "failed"
                                    if res?.accepted == true { apiKey = "" }
                                    await app.refreshStatus()
                                    Haptics.notification(
                                        res?.accepted == true ? .success : .error)
                                }
                            }
                            .buttonStyle(.glass)
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                            .disabled(app.link != .live)
                            if app.status?.assistant?.cloudConfigured == true {
                                Button("Remove") {
                                    Haptics.impact(.medium, intensity: 0.8)
                                    Task {
                                        guard let client = app.client else {
                                            Haptics.notification(.error)
                                            return
                                        }
                                        let res = try? await client.setAssistantConfig(apiKey: "")
                                        assistantResult = res?.accepted == true
                                            ? "Removed — on-device only" : "failed"
                                        await app.refreshStatus()
                                        Haptics.notification(
                                            res?.accepted == true ? .success : .error)
                                    }
                                }
                                .buttonStyle(.glass)
                                .tint(Theme.err)
                                .disabled(app.link != .live)
                            }
                            if let assistantResult {
                                Text(assistantResult)
                                    .font(.caption)
                                    .foregroundStyle(
                                        assistantResult.hasSuffix("✓") ? Theme.accent : Theme.textMuted)
                            }
                        }
                        Text("With a key set, questions go to Gemini Flash whenever the internet is reachable and fall back to the on-device model when it isn't. The key is stored only on the hub, never in the app. Free keys: aistudio.google.com")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }

                    PanelCard(title: "Notifications") {
                        let push = app.status?.push
                        kv("On this phone",
                           notificationsAllowed ? "Allowed" : "Not allowed")
                        kv("Watering alerts",
                           push?.configured == true
                               ? "Pushed by the hub" : "Scheduled on this phone")
                        if push?.configured == true, let n = push?.devices {
                            kv("Registered devices", "\(n)")
                        }
                        kv("Live Activity", liveActivitiesOn ? "Enabled" : "Off")
                        HStack {
                            Button("Test") {
                                Task {
                                    guard let client = app.client else { return }
                                    let sent = (try? await client.pushTest())?.sent ?? 0
                                    if sent > 0 {
                                        pushResult = "Sent to \(sent) device\(sent == 1 ? "" : "s") ✓"
                                    } else {
                                        NotificationManager.shared.notifyNow(
                                            title: "Plant Intelligence",
                                            body: "Local notifications are working.")
                                        pushResult = "Sent locally ✓"
                                    }
                                    Haptics.notification(.success)
                                }
                            }
                            .buttonStyle(.glass)
                            if let pushResult {
                                Text(pushResult)
                                    .font(.caption)
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        Text(push?.configured == true
                             ? "The hub pushes the moment watering starts or stops — including a failsafe run while you're away. A live countdown appears on the lock screen."
                             : "Planned waterings are scheduled on this phone and work offline. For alerts on manual or failsafe runs, install an APNs key on the hub (see the README).")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }

                    PanelCard(title: "Away from home") {
                        kv("Status", app.isPairedForRemote
                                     ? (app.link == .remote ? "In use now" : "Paired")
                                     : "Not paired")
                        if app.link == .remote, let age = app.remoteAgeSeconds {
                            kv("Hub last reported", age < 90
                               ? "just now"
                               : "\(Int(age / 60)) min ago")
                        }
                        if app.isPairedForRemote {
                            if let account = app.remoteAccountName, !account.isEmpty {
                                kv("Account", account)
                            }
                            Button("Forget remote access") {
                                app.forgetRemoteAccess()
                                Haptics.notification(.success)
                            }
                            .buttonStyle(.glass)
                        } else {
                            Button {
                                Haptics.impact(.light)
                                remotePairingBusy = true
                                Task {
                                    let error = await app.pairRemoteAccess()
                                    remotePairingBusy = false
                                    if let error {
                                        remotePairingResult = error
                                        Haptics.notification(.error)
                                    } else {
                                        remotePairingResult = "Paired ✓"
                                        Haptics.notification(.success)
                                    }
                                }
                            } label: {
                                Label(remotePairingBusy ? "Signing in…" : "Sign in with Google",
                                      systemImage: "person.crop.circle.badge.checkmark")
                            }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.accent)
                            .disabled(remotePairingBusy)
                            if let remotePairingResult {
                                Text(remotePairingResult)
                                    .font(.caption)
                                    .foregroundStyle(remotePairingResult.hasSuffix("✓")
                                                     ? Theme.accent : Theme.err)
                            }
                        }
                        Text(app.isPairedForRemote
                             ? "When the hub isn't reachable on Wi-Fi, the app reads the garden from the cloud and queues watering commands there. The hub picks them up within about ten seconds. Notifications arrive either way."
                             : "Sign in with an approved Google account. Firestore permits access only when that account’s Firebase UID is on the garden allowlist.")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }

                    PanelCard(title: "About") {
                        kv("System", "Plant Intelligence")
                        kv("Hub", "Arduino UNO Q")
                        kv("Real-time control", "STM32U585 · Zephyr")
                        kv("Intelligence", "Linux · on-device LLM")
                        Text("The microcontroller owns watering safety — including a failsafe that waters the garden even if every other layer is down.")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 80)
            }
            .background(GardenBackground())
            .topEdgeFade()
            .onAppear { address = app.hubAddress }
            .task {
                notificationsAllowed = await NotificationManager.shared.currentlyAllowed()
                liveActivitiesOn = LiveActivityManager.isSupported
            }
        }
    }

    private func sourceLabel(_ source: String?) -> String {
        switch source {
        case "ip": "auto-detected"
        case "manual": "set manually"
        case "device": "from this device"
        default: source ?? "–"
        }
    }
}
