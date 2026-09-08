import Foundation
import GoogleSignIn
import UIKit

@MainActor
enum GoogleRemoteAuth {
    enum AuthError: LocalizedError {
        case missingClientID
        case missingPresenter
        case missingGoogleToken
        case firebase(String)

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                "Google sign-in has not been configured for this build."
            case .missingPresenter:
                "The sign-in screen could not be presented."
            case .missingGoogleToken:
                "Google did not return a sign-in token."
            case .firebase(let message):
                "Firebase sign-in failed: \(message)"
            }
        }
    }

    static func signIn(configuration: RemoteProjectConfiguration) async throws
        -> RemoteCredentials {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.isEmpty, !clientID.hasPrefix("$(") else {
            throw AuthError.missingClientID
        }
        guard let presenter = presentingViewController() else {
            throw AuthError.missingPresenter
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let googleIDToken = result.user.idToken?.tokenString else {
            throw AuthError.missingGoogleToken
        }
        return try await exchange(
            googleIDToken: googleIDToken,
            configuration: configuration)
    }

    static func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    private static func exchange(
        googleIDToken: String,
        configuration: RemoteProjectConfiguration
    ) async throws -> RemoteCredentials {
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "id_token", value: googleIDToken),
            URLQueryItem(name: "providerId", value: "google.com"),
        ]
        let postBody = bodyComponents.percentEncodedQuery ?? ""
        let endpoint = "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp"
            + "?key=\(configuration.apiKey)"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "postBody": postBody,
            "requestUri": "http://localhost",
            "returnIdpCredential": true,
            "returnSecureToken": true,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let refreshToken = decoded?["refreshToken"] as? String,
              !refreshToken.isEmpty else {
            let message = (decoded?["error"] as? [String: Any])?["message"] as? String
            throw AuthError.firebase(message ?? "unknown reason")
        }

        return RemoteCredentials(
            projectID: configuration.projectID,
            apiKey: configuration.apiKey,
            refreshToken: refreshToken,
            email: decoded?["email"] as? String ?? "",
            displayName: decoded?["displayName"] as? String)
    }

    private static func presentingViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
