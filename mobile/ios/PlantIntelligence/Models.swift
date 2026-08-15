import Foundation

// Mirrors of the hub's API payloads (hub/python/api.py).

struct StatusResponse: Codable {
    var status: DeviceStatus
    var plan: Plan?
    var weather: Weather?
    var location: HubLocation?
    var assistant: AssistantInfo?
    var push: PushInfo?
}

struct PushInfo: Codable {
    var configured: Bool?
    var devices: Int?
}

struct PushTestResponse: Codable {
    var sent: Int?
    var error: String?
}

struct AssistantInfo: Codable {
    var cloudConfigured: Bool?
    var lastBackend: String?

    enum CodingKeys: String, CodingKey {
        case cloudConfigured = "cloud_configured"
        case lastBackend = "last_backend"
    }
}

struct ChatThread: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    var updatedAt: String
    var snippet: String?

    enum CodingKeys: String, CodingKey {
        case id, title, snippet
        case updatedAt = "updated_at"
    }

    var displayTitle: String { title.isEmpty ? "Conversation \(id)" : title }
}

struct ThreadsResponse: Codable {
    var threads: [ChatThread]
}

struct StoredMessage: Codable {
    var role: String
    var content: String
    var createdAt: String
    var attachment: String?

    enum CodingKeys: String, CodingKey {
        case role, content, attachment
        case createdAt = "created_at"
    }
}

struct ThreadMessagesResponse: Codable {
    var messages: [StoredMessage]?
    var error: String?
}

struct DeviceStatus: Codable {
    var boxTemperatureC: Double?
    var boxHumidityPct: Double?
    var fanOn: Bool?
    var soilRaw: Int?
    var soilPct: Double?
    var wateringState: String?
    var wateringSecondsLeft: Int?
    var mcuSeenSecondsAgo: Double?

    enum CodingKeys: String, CodingKey {
        case boxTemperatureC = "box_temperature_c"
        case boxHumidityPct = "box_humidity_pct"
        case fanOn = "fan_on"
        case soilRaw = "soil_raw"
        case soilPct = "soil_pct"
        case wateringState = "watering_state"
        case wateringSecondsLeft = "watering_seconds_left"
        case mcuSeenSecondsAgo = "mcu_seen_seconds_ago"
    }

    var isWatering: Bool { wateringState == "watering" || wateringState == "valve_opening" }
}

struct Plan: Codable {
    var waterNow: Bool
    var durationS: Int
    var nextWaterAt: String?
    var intervalH: Double
    var reasons: [String]
    /// "fixed" while there's no soil probe — the clock decides, not the
    /// cadence maths. Absent on older hubs, hence optional.
    var mode: String?
    var schedule: String?

    enum CodingKeys: String, CodingKey {
        case waterNow = "water_now"
        case durationS = "duration_s"
        case nextWaterAt = "next_water_at"
        case intervalH = "interval_h"
        case reasons, mode, schedule
    }

    /// Fixed slots aren't a computed cadence — don't present them as one.
    var isFixed: Bool { mode == "fixed" && !(schedule ?? "").isEmpty }

    var nextWaterDate: Date? {
        guard let s = nextWaterAt else { return nil }
        return ISO8601.parse(s)
    }
}

struct Weather: Codable {
    var category: String?
    var description: String?
    var tempNowC: Double?
    var humidityNowPct: Double?
    var tempMaxNext12h: Double?
    var precipProbMaxNext12h: Double?
    var isRainingNow: Bool?

    enum CodingKeys: String, CodingKey {
        case category, description
        case tempNowC = "temp_now_c"
        case humidityNowPct = "humidity_now_pct"
        case tempMaxNext12h = "temp_max_next12h"
        case precipProbMaxNext12h = "precip_prob_max_next12h"
        case isRainingNow = "is_raining_now"
    }

    /// The forecast provider's descriptions can be long, technical sentences.
    /// Prefer a short dashboard headline derived from its stable category.
    var displayDescription: String? {
        switch category?.uppercased() {
        case "THUNDERSTORM":
            isRainingNow == true ? "Thunderstorms with rain" : "Thunderstorms possible"
        case "RAINY", "RAIN":
            "Rain"
        case "DRIZZLE":
            "Light rain"
        case "SHOWERS":
            "Rain showers"
        case "SUNNY":
            "Sunny"
        case "CLEAR":
            "Clear skies"
        case "PARTLY_CLOUDY", "PARTLY CLOUDY":
            "Partly cloudy"
        case "CLOUDY", "OVERCAST":
            "Cloudy"
        case "FOG", "MIST":
            "Low visibility"
        case "SNOW", "SNOWY":
            "Snow"
        default:
            description
        }
    }
}

struct HubLocation: Codable {
    var name: String?
    var source: String?
    var latitude: Double?
    var longitude: Double?
}

struct WateringEvent: Codable, Identifiable, Hashable {
    var waterStartedAt: String
    var waterEndedAt: String?
    var trigger: String
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case waterStartedAt = "water_started_at"
        case waterEndedAt = "water_ended_at"
        case trigger, reason
    }

    var id: String { waterStartedAt }
    var startDate: Date? { ISO8601.parse(waterStartedAt) }
    var endDate: Date? { waterEndedAt.flatMap { ISO8601.parse($0) } }
    var minutes: Int? {
        guard let s = startDate, let e = endDate else { return nil }
        return max(1, Int(e.timeIntervalSince(s) / 60))
    }
}

struct LogEntry: Codable, Identifiable, Hashable {
    var timestamp: String
    var eventType: String
    var message: String
    var isError: Bool

    enum CodingKeys: String, CodingKey {
        case timestamp
        case eventType = "event_type"
        case message
        case isError = "is_error"
    }

    var id: String { timestamp + message }
    var date: Date? { ISO8601.parse(timestamp) }
}

struct HistoryResponse: Codable { var history: [WateringEvent] }
struct LogsResponse: Codable { var logs: [LogEntry] }
struct ChatResponse: Codable { var reply: String?; var error: String? }
struct SimpleResponse: Codable { var accepted: Bool?; var error: String?; var name: String? }

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var attachmentURL: URL?
}

/// The hub emits both fractional and whole-second ISO timestamps.
enum ISO8601 {
    static func parse(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return d
        }
        return try? Date(s, strategy: Date.ISO8601FormatStyle())
    }
}
