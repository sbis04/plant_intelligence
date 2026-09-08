import Foundation
import WatchConnectivity

final class WatchCredentialBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchCredentialBridge()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sync(_ credentials: RemoteCredentials) {
        guard WCSession.isSupported(),
              let data = try? JSONEncoder().encode(credentials) else { return }
        do {
            try WCSession.default.updateApplicationContext(["remoteCredentials": data])
        } catch {
            // The latest context is sent automatically when the watch becomes reachable.
        }
    }

    func clear() {
        guard WCSession.isSupported() else { return }
        try? WCSession.default.updateApplicationContext(["remoteCredentialsRemoved": true])
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: (any Error)?) {
        guard activationState == .activated,
              let credentials = RemoteAccess.load() else { return }
        sync(credentials)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
