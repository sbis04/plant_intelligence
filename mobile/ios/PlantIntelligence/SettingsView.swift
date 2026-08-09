import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var address = ""
    @State private var testResult: String?
    @State private var place = ""
    @State private var locationResult: String?
    @State private var apiKey = ""
    @State private var assistantResult: String?

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
                                app.hubAddress = address
                                Task {
                                    await app.refreshStatus()
                                    testResult = app.link == .live
                                        ? "Connected ✓" : "Could not reach the hub"
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

                    PanelCard(title: "Garden location") {
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
                                Task {
                                    guard let client = app.client else { return }
                                    let res = try? await client.setLocation(place: place)
                                    locationResult = res?.accepted == true
                                        ? "Set to \(res?.name ?? place) ✓"
                                        : (res?.error ?? "failed")
                                    if res?.accepted == true { place = "" }
                                    await app.refreshStatus()
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
                                Task {
                                    guard let client = app.client else { return }
                                    let res = try? await client.setAssistantConfig(apiKey: apiKey)
                                    assistantResult = res?.accepted == true ? "Saved ✓" : "failed"
                                    if res?.accepted == true { apiKey = "" }
                                    await app.refreshStatus()
                                }
                            }
                            .buttonStyle(.glass)
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                            if app.status?.assistant?.cloudConfigured == true {
                                Button("Remove") {
                                    Task {
                                        guard let client = app.client else { return }
                                        _ = try? await client.setAssistantConfig(apiKey: "")
                                        assistantResult = "Removed — on-device only"
                                        await app.refreshStatus()
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
