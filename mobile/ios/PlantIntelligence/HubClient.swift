import Foundation

/// Thin async client for the hub's local API.
struct HubClient: Sendable {
    var baseURL: URL

    init?(address: String) {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.hasPrefix("http") { s = "http://\(s)" }
        guard let url = URL(string: s) else { return nil }
        baseURL = url
    }

    private func session(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        return URLSession(configuration: cfg)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type,
                                   timeout: TimeInterval = 8) async throws -> T {
        let (data, _) = try await session(timeout: timeout)
            .data(from: baseURL.appending(path: path))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, query: [String: String] = [:],
                                    as type: T.Type,
                                    timeout: TimeInterval = 15) async throws -> T {
        var comps = URLComponents(url: baseURL.appending(path: path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        let (data, _) = try await session(timeout: timeout).data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Endpoints

    func status() async throws -> StatusResponse {
        try await get("/api/status", as: StatusResponse.self)
    }

    func history() async throws -> [WateringEvent] {
        try await get("/api/history", as: HistoryResponse.self).history
    }

    func logs() async throws -> [LogEntry] {
        try await get("/api/logs", as: LogsResponse.self).logs
    }

    func water(durationS: Int? = nil) async throws -> SimpleResponse {
        var q: [String: String] = [:]
        if let durationS { q["duration_s"] = String(durationS) }
        return try await post("/api/water", query: q, as: SimpleResponse.self)
    }

    func stop() async throws -> SimpleResponse {
        try await post("/api/stop", as: SimpleResponse.self)
    }

    func setLocation(place: String) async throws -> SimpleResponse {
        try await post("/api/location", query: ["place": place], as: SimpleResponse.self)
    }

    func setLocation(latitude: Double, longitude: Double, name: String) async throws -> SimpleResponse {
        try await post("/api/location",
                       query: ["latitude": String(latitude),
                               "longitude": String(longitude),
                               "source": "device",
                               "name": name],
                       as: SimpleResponse.self)
    }

    /// On-device LLM: generation on the UNO Q takes a while — long timeout.
    func chat(message: String) async throws -> ChatResponse {
        try await post("/api/chat", query: ["message": message],
                       as: ChatResponse.self, timeout: 300)
    }

    func chatReset() async throws {
        _ = try await post("/api/chat/reset", as: SimpleResponse.self)
    }
}
