import Foundation

/// Firestore client for when the hub is out of reach.
///
/// This talks to Firestore's REST API over `URLSession` rather than through
/// the Firebase SDK. The app needs four calls — read a document, run two
/// queries, write a command — and the SDK would bring a large binary
/// dependency and an Xcode project change for that. The REST surface is
/// stable and the auth flow is two endpoints.
///
/// The important design point is that the hub mirrors its `/api/status`
/// response verbatim into `device_state/current`. Firestore's typed encoding
/// is unwrapped back into ordinary JSON here, so the same `StatusResponse`
/// decodes from either source and nothing above this layer has to know which
/// path the data arrived by.
actor CloudClient {
    enum CloudError: LocalizedError {
        case notConfigured
        case auth(String)
        case http(Int, String)
        case noDocument
        case commandTimedOut
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Remote access is not set up yet."
            case .auth(let m): "Could not sign in: \(m)"
            case .http(let code, _): "The cloud returned an error (\(code))."
            case .noDocument: "The hub has not reported in yet."
            case .commandTimedOut: "The hub did not pick that up in time."
            case .rejected(let m): m
            }
        }
    }

    private var credentials: RemoteCredentials
    private var idToken = ""
    private var refreshToken: String
    private var tokenExpires = Date.distantPast

    init(credentials: RemoteCredentials) {
        self.credentials = credentials
        refreshToken = credentials.refreshToken
    }

    private var documents: String {
        "https://firestore.googleapis.com/v1/projects/\(credentials.projectID)"
        + "/databases/(default)/documents"
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        // Cellular is the whole point of this path.
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: cfg)
    }()

    // MARK: - Auth

    private func token() async throws -> String {
        if !idToken.isEmpty, Date() < tokenExpires { return idToken }
        guard credentials.isComplete else { throw CloudError.notConfigured }

        guard !refreshToken.isEmpty else { throw CloudError.notConfigured }
        return try await refresh()
    }

    private func refresh() async throws -> String {
        var req = URLRequest(url: URL(string:
            "https://securetoken.googleapis.com/v1/token?key=\(credentials.apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = "grant_type=refresh_token&refresh_token=\(refreshToken)"
            .data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = body["id_token"] as? String else {
            refreshToken = ""
            throw CloudError.auth("the session expired")
        }
        idToken = token
        refreshToken = body["refresh_token"] as? String ?? refreshToken
        credentials.refreshToken = refreshToken
        RemoteAccess.save(credentials)
        let ttl = Double(body["expires_in"] as? String ?? "3600") ?? 3600
        tokenExpires = Date().addingTimeInterval(ttl - 300)
        return token
    }

    // MARK: - Transport

    @discardableResult
    private func send(_ method: String, _ url: String,
                      body: [String: Any]? = nil) async throws -> Any {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            // Force a fresh sign-in on the next call rather than looping here.
            idToken = ""
            tokenExpires = .distantPast
        }
        guard (200..<300).contains(code) else {
            throw CloudError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Decode a Firestore query response into documents, newest first as the
    /// query ordered them.
    private func rows(_ raw: Any) -> [[String: Any]] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard let doc = entry["document"] as? [String: Any],
                  let fields = doc["fields"] as? [String: Any] else { return nil }
            var decoded = Firestore.decode(fields: fields)
            if let name = doc["name"] as? String {
                decoded["_id"] = name.split(separator: "/").last.map(String.init) ?? ""
            }
            return decoded
        }
    }

    private func query(_ collection: String, orderBy field: String,
                       limit: Int) async throws -> [[String: Any]] {
        let raw = try await send("POST", "\(documents):runQuery", body: [
            "structuredQuery": [
                "from": [["collectionId": collection]],
                "orderBy": [["field": ["fieldPath": field], "direction": "DESCENDING"]],
                "limit": limit,
            ],
        ])
        return rows(raw)
    }

    /// Re-encode a decoded Firestore document as JSON and run it through the
    /// app's existing model decoder, so cloud and LAN produce identical types.
    private func model<T: Decodable>(_ dict: [String: Any], as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Reads

    func statusWithAge() async throws -> (status: StatusResponse, age: TimeInterval) {
        let raw = try await send("GET", "\(documents)/device_state/current")
        guard let doc = raw as? [String: Any],
              let fields = doc["fields"] as? [String: Any] else {
            throw CloudError.noDocument
        }
        let decoded = Firestore.decode(fields: fields)
        guard let updated = decoded["updated_at"] as? String,
              let date = ISO8601.parse(updated) else {
            throw CloudError.noDocument
        }
        return (try model(decoded, as: StatusResponse.self),
                max(0, Date().timeIntervalSince(date)))
    }

    func status() async throws -> StatusResponse {
        try await statusWithAge().status
    }

    /// How long ago the hub last refreshed the mirror. A stale document means
    /// the hub is down or offline, which is a different problem from the
    /// phone being away — and the app should say so rather than showing
    /// yesterday's reading as if it were current.
    func stateAge() async throws -> TimeInterval {
        try await statusWithAge().age
    }

    func history(limit: Int = 30) async throws -> [WateringEvent] {
        try await query("water_history", orderBy: "water_started_at", limit: limit)
            .compactMap { try? model($0, as: WateringEvent.self) }
    }

    func logs(limit: Int = 50) async throws -> [LogEntry] {
        try await query("system_logs", orderBy: "timestamp", limit: limit)
            .compactMap { try? model($0, as: LogEntry.self) }
    }

    // MARK: - Commands

    /// Queue a command and wait for the hub to report what it did.
    ///
    /// The wait matters: tapping "Water now" from the other side of the
    /// country should say whether the valve actually opened, not just that
    /// the request was filed. The hub polls every ten seconds, so this
    /// usually settles well inside the timeout.
    @discardableResult
    func send(action: String, durationS: Int? = nil,
              waitFor timeout: TimeInterval = 25) async throws -> String {
        var fields: [String: Any] = [
            "action": Firestore.encode(action),
            "status": Firestore.encode("pending"),
            "requested_at": Firestore.encode(Date()),
            "source": Firestore.encode("ios"),
        ]
        if let durationS { fields["duration_s"] = Firestore.encode(durationS) }

        let created = try await send("POST", "\(documents)/commands",
                                     body: ["fields": fields])
        guard let doc = created as? [String: Any],
              let name = doc["name"] as? String else {
            throw CloudError.commandTimedOut
        }
        let url = "https://firestore.googleapis.com/v1/\(name)"

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            let polled = try? await send("GET", url)
            guard let doc = polled as? [String: Any],
                  let polledFields = doc["fields"] as? [String: Any] else { continue }
            let decoded = Firestore.decode(fields: polledFields)
            let status = decoded["status"] as? String ?? "pending"
            if status == "pending" { continue }
            let result = decoded["result"] as? String ?? status
            if status == "done" { return result }
            throw CloudError.rejected(result)
        }
        throw CloudError.commandTimedOut
    }

    func water(durationS: Int? = nil) async throws -> String {
        try await send(action: "water", durationS: durationS)
    }

    func stop() async throws -> String {
        try await send(action: "stop")
    }

    /// Ask the hub to recompute and re-publish, then read the fresh document.
    func refreshRemote() async throws -> StatusResponse {
        _ = try? await send(action: "refresh", waitFor: 15)
        return try await status()
    }
}

// MARK: - Firestore's typed value encoding

/// Firestore types every field on the wire. These two functions are the only
/// translation between that and ordinary JSON.
enum Firestore {
    static func encode(_ value: Any) -> [String: Any] {
        switch value {
        case let v as Bool: return ["booleanValue": v]
        case let v as Int: return ["integerValue": String(v)]
        case let v as Double: return ["doubleValue": v]
        case let v as Date:
            return ["timestampValue": v.formatted(.iso8601)]
        case let v as [String: Any]:
            return ["mapValue": ["fields": v.mapValues { encode($0) }]]
        case let v as [Any]:
            return ["arrayValue": ["values": v.map { encode($0) }]]
        default: return ["stringValue": String(describing: value)]
        }
    }

    static func decode(fields: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, raw) in fields {
            if let value = decode(value: raw) { out[key] = value }
        }
        return out
    }

    static func decode(value raw: Any) -> Any? {
        guard let wrapper = raw as? [String: Any],
              let (kind, value) = wrapper.first else { return nil }
        switch kind {
        case "nullValue": return nil
        case "booleanValue": return value as? Bool ?? false
        // Firestore sends 64-bit integers as strings so they survive JSON.
        case "integerValue": return Int(value as? String ?? "") ?? 0
        case "doubleValue": return value as? Double ?? 0
        case "timestampValue", "stringValue": return value as? String ?? ""
        case "mapValue":
            let inner = (value as? [String: Any])?["fields"] as? [String: Any] ?? [:]
            return decode(fields: inner)
        case "arrayValue":
            let values = (value as? [String: Any])?["values"] as? [Any] ?? []
            return values.compactMap { decode(value: $0) }
        default: return nil
        }
    }
}
