import Foundation

struct RemoteCredentials: Codable, Equatable, Sendable {
  var projectID: String
  var apiKey: String
  var refreshToken: String
  var email: String
  var displayName: String?

  var isComplete: Bool {
    !projectID.isEmpty && !apiKey.isEmpty && !refreshToken.isEmpty
  }
}

struct RemoteProjectConfiguration: Sendable {
  var projectID: String
  var apiKey: String

  var isComplete: Bool { !projectID.isEmpty && !apiKey.isEmpty }

  static var bundled: RemoteProjectConfiguration? {
    guard let projectID = Bundle.main.object(forInfoDictionaryKey: "FirebaseProjectID") as? String,
          let apiKey = Bundle.main.object(forInfoDictionaryKey: "FirebaseAPIKey") as? String else {
      return nil
    }
    let configuration = RemoteProjectConfiguration(projectID: projectID, apiKey: apiKey)
    return configuration.isComplete ? configuration : nil
  }
}

enum RemoteFreshness {
  // The hub normally publishes every 30 seconds. Four missed publishes is a
  // clear enough signal that it should no longer be presented as reachable.
  static let maximumAge: TimeInterval = 120
}
