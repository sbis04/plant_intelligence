import SwiftUI
import UIKit

/// The app lives in portrait; only the full-screen camera viewer is allowed
/// to rotate, by flipping this gate while it's presented.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var allowLandscape = false

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        Self.allowLandscape ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
    }
}

@main
struct PlantIntelligenceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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
