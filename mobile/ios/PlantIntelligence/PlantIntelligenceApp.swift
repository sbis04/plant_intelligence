import SwiftUI

@main
struct PlantIntelligenceApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var selection =
        UserDefaults.standard.integer(forKey: "launchTab")   // dev/testing hook

    var body: some View {
        TabView(selection: $selection) {
            Tab("Plants", systemImage: "leaf.fill", value: 0) {
                GardenView()
            }
            Tab("Assistant", systemImage: "sparkles", value: 1) {
                AssistantView()
            }
            Tab("Activity", systemImage: "clock.arrow.circlepath", value: 2) {
                ActivityView()
            }
            Tab("Settings", systemImage: "gearshape", value: 3) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .task {
            app.startPolling()
            if UserDefaults.standard.bool(forKey: "autoAsk") {
                await app.ask("Why aren't you watering right now?")
            }
        }
    }
}
