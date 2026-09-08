import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var address = ""
    @State private var testResult: String?
    @State private var place = ""
    @State private var locationResult: String?
    @State private var apiKey = ""
    @State private var assistantResult: String?
    @State private var pushResult: String?
    @State private var notificationsAllowed = false
    @State private var liveActivitiesOn = false

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

                    PanelCard(title: "Location") {
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
                            Button("Forget remote access") {
                                app.forgetRemoteAccess()
                                Haptics.notification(.success)
                            }
                            .buttonStyle(.glass)
                        }
                        Text(app.isPairedForRemote
                             ? "When the hub isn't reachable on Wi-Fi, the app reads the garden from the cloud and queues watering commands there. The hub picks them up within about ten seconds. Notifications arrive either way."
                             : "Open the app once on your home Wi-Fi and it will pair itself for use away from home. Nothing to type in.")
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
