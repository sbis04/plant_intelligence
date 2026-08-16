import Foundation

struct GardenSnapshot: Codable, Equatable, Sendable {
  var updatedAt: Date
  var isLive: Bool
  var isWatering: Bool
  var wateringSecondsLeft: Int?
  var planDurationSeconds: Int?
  var waterNow: Bool
  /// The hub's own verdict: due, rain_hold, already_wet, missed, done,
  /// soil_hold, scheduled. Empty from an older hub, which falls back to
  /// waterNow alone.
  var planStatus: String
  var nextWateringAt: Date?
  var outsideTemperatureC: Double?
  var outsideHumidityPct: Double?
  var soilPct: Double?
  var boxTemperatureC: Double?
  var fanOn: Bool?
  var mcuSeenSecondsAgo: Double?
  var locationName: String?
  var weatherDescription: String?
  var rainChancePct: Double?
  var isRainingNow: Bool

  private init(
    updatedAt: Date,
    isLive: Bool,
    isWatering: Bool,
    wateringSecondsLeft: Int?,
    planDurationSeconds: Int?,
    waterNow: Bool,
    planStatus: String,
    nextWateringAt: Date?,
    outsideTemperatureC: Double?,
    outsideHumidityPct: Double?,
    soilPct: Double?,
    boxTemperatureC: Double?,
    fanOn: Bool?,
    mcuSeenSecondsAgo: Double?,
    locationName: String?,
    weatherDescription: String?,
    rainChancePct: Double?,
    isRainingNow: Bool
  ) {
    self.updatedAt = updatedAt
    self.isLive = isLive
    self.isWatering = isWatering
    self.wateringSecondsLeft = wateringSecondsLeft
    self.planDurationSeconds = planDurationSeconds
    self.waterNow = waterNow
    self.planStatus = planStatus
    self.nextWateringAt = nextWateringAt
    self.outsideTemperatureC = outsideTemperatureC
    self.outsideHumidityPct = outsideHumidityPct
    self.soilPct = soilPct
    self.boxTemperatureC = boxTemperatureC
    self.fanOn = fanOn
    self.mcuSeenSecondsAgo = mcuSeenSecondsAgo
    self.locationName = locationName
    self.weatherDescription = weatherDescription
    self.rainChancePct = rainChancePct
    self.isRainingNow = isRainingNow
  }

  init(response: StatusResponse, isLive: Bool = true) {
    let status = response.status
    let plan = response.plan
    let weather = response.weather

    updatedAt = Date()
    self.isLive = isLive
    isWatering = status.isWatering
    wateringSecondsLeft = status.wateringSecondsLeft
    planDurationSeconds = plan?.durationS
    waterNow = plan?.waterNow == true
    planStatus = plan?.status ?? ""
    nextWateringAt = plan?.nextWaterDate
    outsideTemperatureC = weather?.tempNowC
    outsideHumidityPct = weather?.humidityNowPct
    soilPct = status.soilPct
    boxTemperatureC = status.boxTemperatureC
    fanOn = status.fanOn
    mcuSeenSecondsAgo = status.mcuSeenSecondsAgo
    locationName = response.location?.name
    weatherDescription = weather?.displayDescription
    rainChancePct = weather?.precipProbMaxNext12h
    isRainingNow = weather?.isRainingNow == true
  }

  static let placeholder = GardenSnapshot(
    updatedAt: Date(),
    isLive: true,
    isWatering: false,
    wateringSecondsLeft: nil,
    planDurationSeconds: 240,
    waterNow: false,
    planStatus: "rain_hold",
    nextWateringAt: Calendar.current.date(byAdding: .day, value: 2, to: Date()),
    outsideTemperatureC: 29.9,
    outsideHumidityPct: 82,
    soilPct: nil,
    boxTemperatureC: nil,
    fanOn: false,
    mcuSeenSecondsAgo: 2,
    locationName: "Kolkata",
    weatherDescription: "Thunderstorms with rain",
    rainChancePct: 97,
    isRainingNow: true
  )

  static let offline = GardenSnapshot(
    updatedAt: Date(),
    isLive: false,
    isWatering: false,
    wateringSecondsLeft: nil,
    planDurationSeconds: nil,
    waterNow: false,
    planStatus: "",
    nextWateringAt: nil,
    outsideTemperatureC: nil,
    outsideHumidityPct: nil,
    soilPct: nil,
    boxTemperatureC: nil,
    fanOn: nil,
    mcuSeenSecondsAgo: nil,
    locationName: nil,
    weatherDescription: nil,
    rainChancePct: nil,
    isRainingNow: false
  )

  /// Any reason the hub is holding off, whatever it happens to be. Drives
  /// the "Water anyway" wording rather than the hero text.
  var isHolding: Bool {
    ["rain_hold", "already_wet", "soil_hold"].contains(planStatus)
  }

  var statusTitle: String {
    guard isLive else { return "Hub offline" }
    if isWatering, let wateringSecondsLeft {
      return String(
        format: "Watering %d:%02d",
        wateringSecondsLeft / 60, wateringSecondsLeft % 60)
    }
    switch planStatus {
    case "due": return "Watering due"
    case "rain_hold": return "Waiting out the rain"
    case "already_wet": return "Already watered"
    case "soil_hold": return "Soil still damp"
    case "missed": return "Missed a watering"
    case "done": return "Watered today"
    case "scheduled": return "On schedule"
    default: return waterNow ? "Watering due" : "On schedule"
    }
  }

  var statusSymbol: String {
    guard isLive else { return "antenna.radiowaves.left.and.right.slash" }
    if isWatering { return "drop.fill" }
    switch planStatus {
    case "due": return "drop.circle.fill"
    case "rain_hold": return "cloud.rain.fill"
    case "already_wet": return "humidity.fill"
    case "soil_hold": return "drop.fill"
    case "missed": return "clock.badge.exclamationmark"
    case "done": return "checkmark.circle.fill"
    default: return waterNow ? "drop.circle.fill" : "leaf.fill"
    }
  }

  var nextWateringShort: String {
    guard isLive else { return "Open Plants to reconnect" }
    if waterNow { return "Watering is due now" }
    guard let nextWateringAt else { return "No watering planned yet" }
    return "Next " + nextWateringAt.formatted(.relative(presentation: .named))
  }

  var outsideTemperatureText: String {
    outsideTemperatureC.map { String(format: "%.0f°", $0) } ?? "–"
  }

  var soilText: String {
    soilPct.map { "\(Int($0.rounded()))%" } ?? "No probe"
  }

  var boxTemperatureText: String {
    boxTemperatureC.map { String(format: "%.0f°", $0) } ?? "–"
  }

  var rainText: String {
    if isRainingNow { return "Raining" }
    return rainChancePct.map { "\(Int($0.rounded()))% rain" } ?? "–"
  }

  var wateringProgress: Double {
    guard isWatering,
      let wateringSecondsLeft,
      let planDurationSeconds,
      planDurationSeconds > 0
    else { return 0 }
    return min(max(Double(wateringSecondsLeft) / Double(planDurationSeconds), 0), 1)
  }
}

enum SharedGardenStore {
  static let suiteName = "group.com.souvikbiswas.plants"
  private static let snapshotKey = "gardenSnapshot"
  private static let hubAddressKey = "hubAddress"

  private static var defaults: UserDefaults {
    UserDefaults(suiteName: suiteName) ?? .standard
  }

  static var hubAddress: String {
    get { defaults.string(forKey: hubAddressKey) ?? "plantintelligence.local:7000" }
    set { defaults.set(newValue, forKey: hubAddressKey) }
  }

  static func load() -> GardenSnapshot? {
    guard let data = defaults.data(forKey: snapshotKey) else { return nil }
    return try? JSONDecoder().decode(GardenSnapshot.self, from: data)
  }

  static func save(_ snapshot: GardenSnapshot) {
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    defaults.set(data, forKey: snapshotKey)
  }
}

enum GardenSnapshotService {
  static func fetch() async -> GardenSnapshot {
    guard let client = HubClient(address: SharedGardenStore.hubAddress) else {
      return cachedOfflineSnapshot()
    }
    do {
      let snapshot = GardenSnapshot(response: try await client.status())
      SharedGardenStore.save(snapshot)
      return snapshot
    } catch {
      return cachedOfflineSnapshot()
    }
  }

  private static func cachedOfflineSnapshot() -> GardenSnapshot {
    guard var cached = SharedGardenStore.load() else { return .offline }
    cached.isLive = false
    return cached
  }
}
