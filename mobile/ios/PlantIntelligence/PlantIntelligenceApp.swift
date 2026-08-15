import SwiftUI
import UIKit

/// The app lives in portrait; only the full-screen camera viewer is allowed
/// to rotate, by flipping this gate while it's presented.
///
/// Also the landing point for the APNs device token, which is handed to the
/// hub so it can push watering alerts without any cloud service in between.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var allowLandscape = false
    /// Set by the app once state exists; the token can arrive before that.
    static var onDeviceToken: ((String) -> Void)?
    private static var pendingToken: String?

    static func claimPendingToken() -> String? {
        defer { pendingToken = nil }
        return pendingToken
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        Self.allowLandscape ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        if let handler = Self.onDeviceToken {
            handler(hex)
        } else {
            Self.pendingToken = hex
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator without a paid push profile, or no network — local
        // notifications still work, so this is not fatal.
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
    @State private var suppressNextTabHaptic = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("Plants", systemImage: "leaf.fill", value: 0) {
                GardenView()
            }
            Tab("Activity", systemImage: "clock.arrow.circlepath", value: 2) {
                ActivityView()
            }
            Tab("Settings", systemImage: "gearshape", value: 3) {
                SettingsView()
            }
            // Not a destination: the search role detaches this item to the
            // right of the tab bar; selecting it toggles the assistant
            // overlay on the Plants tab instead of switching to a tab of
            // its own, and reads as Close while the overlay is up.
            Tab(app.assistantOpen ? "Close" : "Assistant",
                systemImage: app.assistantOpen ? "xmark" : "sparkles",
                value: 1, role: .search) {
                Color.clear
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: selection) {
            if suppressNextTabHaptic {
                suppressNextTabHaptic = false
                return
            }
            Haptics.selection()
            if selection == 1 {
                suppressNextTabHaptic = true
                selection = 0
                withAnimation(.snappy) { app.assistantOpen.toggle() }
            }
        }
        .task {
            app.startPolling()
            AppDelegate.onDeviceToken = { token in
                Task { await app.registerPushToken(token) }
            }
            if let waiting = AppDelegate.claimPendingToken() {
                await app.registerPushToken(waiting)
            }
            // Fire-and-forget: asking for notification permission blocks on
            // the user answering, and nothing else about launch should wait
            // for that.
            Task { await app.setUpNotifications() }
            if UserDefaults.standard.bool(forKey: "demoActivity") {   // dev/testing hook
                LiveActivityManager.start(
                    endsAt: Date().addingTimeInterval(240), totalSeconds: 240,
                    trigger: "scheduled", note: "",
                    location: app.status?.location?.name ?? "Rooftop garden",
                    client: app.client)
            }
            if UserDefaults.standard.bool(forKey: "openAssistant") {   // dev/testing hook
                app.assistantOpen = true
            }
            if UserDefaults.standard.bool(forKey: "autoAsk") {
                await app.ask("Why aren't you watering right now?")
            }
        }
    }
}
