import ActivityKit
import Foundation

/// Drives the lock-screen watering card.
///
/// Two paths lead to the same card:
///  - the app sees watering begin while it's running and starts it locally
///  - the hub pushes a start using the push-to-start token, which works even
///    if the app was never opened (a failsafe watering at 3am, say)
///
/// Either way the card counts itself down from an absolute end time, so it
/// stays correct without a stream of updates. The activity's own push token
/// goes back to the hub so it can end the card the moment watering stops.
///
/// Only the activity's `id` is held on the main actor — `Activity`'s methods
/// are nonisolated, so the object itself is looked up again inside each task
/// rather than being sent across the boundary.
@MainActor
enum LiveActivityManager {
  private static var currentID: String?
  private static var tokenTask: Task<Void, Never>?
  private static var startTokenTask: Task<Void, Never>?

  static var isSupported: Bool {
    ActivityAuthorizationInfo().areActivitiesEnabled
  }

  /// True if a card is on screen — including one left behind by a crash or
  /// a restart, which is why this asks the system rather than our own state.
  static var hasActive: Bool {
    !Activity<WateringAttributes>.activities.filter { $0.activityState == .active }
      .isEmpty
  }

  private nonisolated static func find(_ id: String) -> Activity<WateringAttributes>? {
    Activity<WateringAttributes>.activities.first { $0.id == id }
  }

  /// Every card currently on screen, newest first.
  ///
  /// Plural on purpose. Two paths raise these cards and they can both fire
  /// for one watering, so anything that assumes a single card is wrong the
  /// moment a remote start and a local start land together.
  private nonisolated static var liveCards: [Activity<WateringAttributes>] {
    Activity<WateringAttributes>.activities
      .filter { $0.activityState == .active }
      .sorted { startedAt($0) > startedAt($1) }
  }

  private nonisolated static func startedAt(
    _ activity: Activity<WateringAttributes>
  ) -> Double {
    let state = activity.content.state
    return state.endsAtEpoch - Double(state.totalSeconds)
  }

  /// A card raised in the last few seconds may belong to a watering our
  /// status poll has not caught up with yet. Retiring it would shoot down
  /// the card we were just asked to show.
  private nonisolated static func isTooFresh(
    _ activity: Activity<WateringAttributes>
  ) -> Bool {
    let state = activity.content.state
    return !state.finished
      && Date().timeIntervalSince1970 - startedAt(activity) < 25
  }

  private static func retire(_ id: String) {
    push(
      state: .init(
        endsAtEpoch: Date().timeIntervalSince1970, totalSeconds: 0,
        trigger: "", finished: true, note: ""),
      to: id, ending: true)
  }

  /// Collapse duplicates down to one card.
  ///
  /// Called while watering is in progress, because the two starts can race:
  /// the hub's push-to-start card may not be in `activities` yet when the
  /// local start checks, so the check alone cannot prevent a second card —
  /// it can only be cleaned up once both exist.
  static func reconcile(client: HubClient?) {
    let cards = liveCards
    guard cards.count > 1, let keep = cards.first else { return }
    if currentID != keep.id {
      currentID = keep.id
      observeUpdateToken(id: keep.id, with: client)
    }
    for extra in cards.dropFirst() {
      NSLog("[LiveActivity] retiring duplicate \(extra.id)")
      retire(extra.id)
    }
  }

  /// Hand the hub a push-to-start token so it can raise the card unprompted.
  static func registerPushToStart(with client: HubClient?) {
    startTokenTask?.cancel()
    startTokenTask = Task.detached {
      for await data in Activity<WateringAttributes>.pushToStartTokenUpdates {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        await PendingPushTokens.shared.submit(
          value: hex, kind: "activity-start", client: client)
      }
    }
    // Adopt a card the hub may have raised while the app was closed.
    if currentID == nil, let live = Activity<WateringAttributes>.activities.first {
      currentID = live.id
      observeUpdateToken(id: live.id, with: client)
    }
  }

  static func start(
    endsAt: Date, totalSeconds: Int, trigger: String, note: String,
    location: String, client: HubClient?
  ) {
    guard isSupported else { return }
    let state = WateringAttributes.ContentState(
      endsAtEpoch: endsAt.timeIntervalSince1970,
      totalSeconds: totalSeconds,
      trigger: trigger,
      finished: false,
      note: note)

    // Adopt whatever card is already on screen, whoever raised it. This
    // used to match only an id this launch remembered, so a card the hub
    // pushed was invisible to it and a second one was requested — two
    // cards for one watering, and only one of them with a push token the
    // hub could use to end it.
    let cards = liveCards
    if let keep = cards.first(where: { $0.id == currentID }) ?? cards.first {
      currentID = keep.id
      observeUpdateToken(id: keep.id, with: client)
      push(state: state, to: keep.id, ending: false)
      for extra in cards where extra.id != keep.id { retire(extra.id) }
      return
    }
    let place = location.split(separator: ",", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let attributes = WateringAttributes(
      locationName: place.flatMap { $0.isEmpty ? nil : $0 } ?? "Location")
    let content = ActivityContent(
      state: state, staleDate: endsAt.addingTimeInterval(120))
    do {
      // Ask for a push token so the hub can end the card remotely. Without
      // a push profile (simulator, or an unsigned build) that throws — the
      // card is still worth showing, just locally driven.
      let activity: Activity<WateringAttributes>
      do {
        activity = try Activity.request(
          attributes: attributes, content: content, pushType: .token)
        observeUpdateToken(id: activity.id, with: client)
      } catch {
        activity = try Activity.request(
          attributes: attributes, content: content, pushType: nil)
      }
      currentID = activity.id
      NSLog("[LiveActivity] started \(activity.id)")
    } catch {
      currentID = nil
      NSLog("[LiveActivity] request failed: \(error)")
    }
  }

  static func update(endsAt: Date, totalSeconds: Int, trigger: String, note: String) {
    guard let id = currentID else { return }
    push(
      state: .init(
        endsAtEpoch: endsAt.timeIntervalSince1970,
        totalSeconds: totalSeconds,
        trigger: trigger,
        finished: false,
        note: note),
      to: id, ending: false)
  }

  static func end() {
    // Every card, not just the one we remember. Ending a single card while
    // a duplicate stayed up is exactly how a card "never clears".
    var cards = liveCards
    if let newest = cards.first, isTooFresh(newest) {
      // The hub pushed this a beat ago and our poll has not caught up.
      // Leave it — but anything older is still a duplicate worth clearing.
      cards.removeFirst()
      for card in cards { retire(card.id) }
      return
    }
    guard !cards.isEmpty || currentID != nil else { return }
    if let id = currentID, !cards.contains(where: { $0.id == id }), find(id) != nil {
      retire(id)   // remembered but no longer reported active; end it anyway
    }
    currentID = nil
    tokenTask?.cancel()
    for card in cards { retire(card.id) }
  }

  private static func push(
    state: WateringAttributes.ContentState, to id: String, ending: Bool
  ) {
    Task.detached {
      guard let activity = find(id) else { return }
      let content = ActivityContent(
        state: state,
        staleDate: ending ? nil : state.endsAt.addingTimeInterval(120))
      if ending {
        await activity.end(content, dismissalPolicy: .immediate)
      } else {
        await activity.update(content)
      }
    }
  }

  private static func observeUpdateToken(id: String, with client: HubClient?) {
    tokenTask?.cancel()
    tokenTask = Task.detached {
      guard let activity = find(id) else { return }
      for await data in activity.pushTokenUpdates {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        await PendingPushTokens.shared.submit(
          value: hex, kind: "activity-update", client: client)
      }
    }
  }
}
