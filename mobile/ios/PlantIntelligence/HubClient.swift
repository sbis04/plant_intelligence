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

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:],
                                   as type: T.Type,
                                   timeout: TimeInterval = 8) async throws -> T {
        var comps = URLComponents(url: baseURL.appending(path: path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let (data, _) = try await session(timeout: timeout).data(from: comps.url!)
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

    /// The timeout is a parameter because the app calls this to decide
    /// whether the hub is reachable at all. While it is already talking to
    /// the hub a slow answer is worth waiting for; while it is on the cloud
    /// path this is just a probe for "am I home yet", and should fail fast.
    func status(timeout: TimeInterval = 8) async throws -> StatusResponse {
        try await get("/api/status", as: StatusResponse.self, timeout: timeout)
    }

    /// Collect the Firestore credentials for remote access. The hub only
    /// answers this for callers on the local network.
    func pairRemoteAccess() async throws -> CloudClient.Credentials {
        struct Pairing: Decodable {
            var project_id: String?
            var api_key: String?
            var email: String?
            var password: String?
            var error: String?
        }
        let response = try await get("/api/cloud/pair", as: Pairing.self)
        return CloudClient.Credentials(
            projectID: response.project_id ?? "",
            apiKey: response.api_key ?? "",
            email: response.email ?? "",
            password: response.password ?? "")
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

    func setAssistantConfig(apiKey: String) async throws -> SimpleResponse {
        try await post("/api/assistant/config", query: ["api_key": apiKey],
                       as: SimpleResponse.self)
    }

    /// Generation can take a while on the on-device fallback — long timeout.
    func chat(message: String, threadId: Int = 0) async throws -> ChatResponse {
        try await post("/api/chat",
                       query: ["message": message, "thread_id": String(threadId)],
                       as: ChatResponse.self, timeout: 300)
    }

    /// Streamed variant: connects, reports the thread id (existing or newly
    /// created by the hub — from the X-Thread-Id header), then yields text
    /// chunks as the model generates them. UTF-8-safe: bytes are buffered
    /// until they decode cleanly, so a multi-byte character split across
    /// chunks never corrupts the text.
    func chatStream(message: String, threadId: Int, attachmentId: String = "")
        async throws -> (threadId: Int, chunks: AsyncThrowingStream<String, Error>) {
        var comps = URLComponents(
            url: baseURL.appending(path: "/api/chat/stream"),
            resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "message", value: message),
                            URLQueryItem(name: "thread_id", value: String(threadId)),
                            URLQueryItem(name: "attachment_id", value: attachmentId)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        let (bytes, response) = try await session(timeout: 300).bytes(for: req)
        let tid = (response as? HTTPURLResponse)
            .flatMap { Int($0.value(forHTTPHeaderField: "X-Thread-Id") ?? "") }
            ?? threadId
        let chunks = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        if let s = String(data: buffer, encoding: .utf8), !s.isEmpty {
                            continuation.yield(s)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if let tail = String(data: buffer, encoding: .utf8), !tail.isEmpty {
                        continuation.yield(tail)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (tid, chunks)
    }

    /// Hand the hub an APNs token so it can push watering alerts and raise
    /// the live activity. `kind`: alert | activity-start | activity-update.
    func registerPush(token: String, kind: String) async throws -> SimpleResponse {
        try await post("/api/push/register",
                       query: ["token": token, "kind": kind],
                       as: SimpleResponse.self)
    }

    func pushTest() async throws -> PushTestResponse {
        try await post("/api/push/test", as: PushTestResponse.self, timeout: 30)
    }

    /// Upload a photo to ride along with the next question.
    func attach(_ jpeg: Data) async throws -> String {
        var req = URLRequest(url: baseURL.appending(path: "/api/chat/attach"))
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = jpeg
        let (data, _) = try await session(timeout: 30).data(for: req)
        struct AttachResponse: Decodable { let id: String? }
        return try JSONDecoder().decode(AttachResponse.self, from: data).id ?? ""
    }

    // MARK: - Assistant threads

    func chatThreads() async throws -> [ChatThread] {
        try await get("/api/chat/threads", as: ThreadsResponse.self).threads
    }

    func threadMessages(id: Int) async throws -> [StoredMessage] {
        try await get("/api/chat/thread", query: ["id": String(id)],
                      as: ThreadMessagesResponse.self).messages ?? []
    }

    func deleteThread(id: Int) async throws -> SimpleResponse {
        try await post("/api/chat/thread/delete", query: ["id": String(id)],
                       as: SimpleResponse.self)
    }
}
