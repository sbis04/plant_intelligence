import Foundation

actor PendingPushTokens {
    static let shared = PendingPushTokens()

    private struct Token: Codable, Hashable {
        var value: String
        var kind: String
    }

    private let defaultsKey = "pendingPushTokens"
    private var tokens: Set<Token>

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode(Set<Token>.self, from: data) {
            tokens = stored
        } else {
            tokens = []
        }
    }

    func submit(value: String, kind: String, client: HubClient?) async {
        tokens.insert(Token(value: value, kind: kind))
        persist()
        if let client { await flush(with: client) }
    }

    func flush(with client: HubClient) async {
        var delivered: Set<Token> = []
        for token in tokens {
            guard let response = try? await client.registerPush(
                token: token.value, kind: token.kind),
                response.accepted != false, response.error == nil else { continue }
            delivered.insert(token)
        }
        tokens.subtract(delivered)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
