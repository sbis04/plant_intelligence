import Foundation
import WatchConnectivity
import WidgetKit

final class PhoneCredentialReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneCredentialReceiver()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: (any Error)?) {
        receive(session.receivedApplicationContext)
    }

    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    private func receive(_ context: [String: Any]) {
        if context["remoteCredentialsRemoved"] as? Bool == true {
            RemoteAccess.forget()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        guard let data = context["remoteCredentials"] as? Data,
              let credentials = try? JSONDecoder().decode(RemoteCredentials.self, from: data),
              credentials.isComplete else { return }
        if RemoteAccess.save(credentials) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
