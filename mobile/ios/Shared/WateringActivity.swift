import Foundation

#if os(iOS)
  import ActivityKit

  /// The lock-screen card shown while the garden is being watered.
  ///
  /// The content state carries an absolute end time rather than a countdown,
  /// so the card can tick down on its own with `Text(timerInterval:)` — no
  /// push per second, and it stays right even if an update is missed. Field
  /// names are part of the wire contract with the hub (see push.py).
  struct WateringAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
      var endsAtEpoch: Double
      var totalSeconds: Int
      var trigger: String  // scheduled | manual | failsafe
      var finished: Bool
      var note: String

      var endsAt: Date { Date(timeIntervalSince1970: endsAtEpoch) }

      var triggerLabel: String {
        switch trigger {
        case "manual": "Started by you"
        case "failsafe": "Failsafe watering"
        case "scheduled": "On schedule"
        default: ""
        }
      }
    }

    var locationName: String
  }
#endif
