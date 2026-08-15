import Foundation

struct GardenSnapshot: Codable, Equatable, Sendable {
  var updatedAt: Date
  var isLive: Bool
  var isWatering: Bool
  var wateringSecondsLeft: Int?
  var planDurationSeconds: Int?
  var waterNow: Bool
  var rainHold: Bool
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
    rainHold: Bool,
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
    self.rainHold = rainHold
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
    rainHold =
      plan?.reasons.contains {
        $0.localizedCaseInsensitiveContains("rain")
      } == true
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
    rainHold: true,
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
    rainHold: false,
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

  var statusTitle: String {
    guard isLive else { return "Hub offline" }
    if isWatering, let wateringSecondsLeft {
      return String(
        format: "Watering %d:%02d",
        wateringSecondsLeft / 60, wateringSecondsLeft % 60)
    }
    if waterNow { return "Watering due" }
    if rainHold { return "Waiting out the rain" }
    return "On schedule"
  }

  var statusSymbol: String {
    guard isLive else { return "antenna.radiowaves.left.and.right.slash" }
    if isWatering { return "drop.fill" }
    if waterNow { return "drop.circle.fill" }
    if rainHold { return "cloud.rain.fill" }
    return "leaf.fill"
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
  static let suiteName = "group.dev.souvik.PlantIntelligence"
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
