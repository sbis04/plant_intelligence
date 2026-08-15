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

  /// Hand the hub a push-to-start token so it can raise the card unprompted.
  static func registerPushToStart(with client: HubClient?) {
    guard let client else { return }
    startTokenTask?.cancel()
    startTokenTask = Task.detached {
      for await data in Activity<WateringAttributes>.pushToStartTokenUpdates {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        _ = try? await client.registerPush(token: hex, kind: "activity-start")
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

    if let id = currentID, find(id) != nil {
      push(state: state, to: id, ending: false)
      return
    }
    let attributes = WateringAttributes(locationName: location)
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
    // Adopt an orphan (left by a crash or a hub-pushed start) so it can be
    // retired too, not just cards this launch created.
    let orphan = Activity<WateringAttributes>.activities.first {
      $0.activityState == .active
    }
    // A card the hub just pushed can arrive a beat before the status poll
    // catches up to "watering". Leave anything very fresh alone, or we'd
    // shoot down the card we were asked to show.
    if let orphan {
      let state = orphan.content.state
      let startedAt = state.endsAtEpoch - Double(state.totalSeconds)
      if !state.finished, Date().timeIntervalSince1970 - startedAt < 25 {
        return
      }
    }
    let id = currentID ?? orphan?.id
    guard let id else { return }
    currentID = nil
    tokenTask?.cancel()
    push(
      state: .init(
        endsAtEpoch: Date().timeIntervalSince1970,
        totalSeconds: 0,
        trigger: "",
        finished: true,
        note: ""),
      to: id, ending: true)
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
        await activity.end(
          content, dismissalPolicy: .after(.now.addingTimeInterval(90)))
      } else {
        await activity.update(content)
      }
    }
  }

  private static func observeUpdateToken(id: String, with client: HubClient?) {
    guard let client else { return }
    tokenTask?.cancel()
    tokenTask = Task.detached {
      guard let activity = find(id) else { return }
      for await data in activity.pushTokenUpdates {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        _ = try? await client.registerPush(token: hex, kind: "activity-update")
      }
    }
  }
}
