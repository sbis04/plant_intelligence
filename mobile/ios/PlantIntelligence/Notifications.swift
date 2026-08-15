import Foundation
import UIKit
import UserNotifications

/// Notifications come from two places, deliberately:
///
///  - **Scheduled locally** from the plan the hub publishes. These fire even
///    if the board is unreachable or push was never set up, and they cover
///    the ordinary cadence because we already know when it will water.
///  - **Pushed by the hub** over APNs for anything unplanned — a manual run
///    from the dashboard, or the failsafe firing while you're away.
///
/// The two would otherwise double up, so a scheduled one is cancelled the
/// moment the real watering it predicted actually starts.
@MainActor
final class NotificationManager: NSObject {
  static let shared = NotificationManager()

  private let center = UNUserNotificationCenter.current()
  private var scheduledFor: Date?

  private enum ID {
    static let plannedStart = "watering.planned.start"
    static let plannedEnd = "watering.planned.end"
  }

  var isAuthorized = false

  func currentlyAllowed() async -> Bool {
    let settings = await center.notificationSettings()
    return settings.authorizationStatus == .authorized
      || settings.authorizationStatus == .provisional
  }

  func bootstrap() async {
    center.delegate = self
    do {
      isAuthorized = try await center.requestAuthorization(
        options: [.alert, .sound, .badge, .timeSensitive])
    } catch {
      isAuthorized = false
    }
    if isAuthorized {
      UIApplication.shared.registerForRemoteNotifications()
    }
  }

  // MARK: - Locally scheduled, from the hub's plan

  /// Keep the two planned notifications in step with the current plan.
  /// Cheap to call on every status refresh: it no-ops unless the predicted
  /// time actually moved.
  func syncPlanned(nextWateringAt: Date?, durationSeconds: Int?, isWatering: Bool) {
    guard isAuthorized else { return }

    guard let start = nextWateringAt, !isWatering,
      start.timeIntervalSinceNow > 60
    else {
      if scheduledFor != nil { cancelPlanned() }
      return
    }
    guard scheduledFor.map({ abs($0.timeIntervalSince(start)) > 60 }) ?? true else {
      return  // already scheduled for (near enough) this moment
    }
    scheduledFor = start

    let duration = durationSeconds ?? 300
    schedule(
      id: ID.plannedStart, at: start,
      title: "Watering starting",
      body: "Your rooftop garden is being watered for about \(max(1, duration / 60)) min.")
    schedule(
      id: ID.plannedEnd, at: start.addingTimeInterval(TimeInterval(duration)),
      title: "Watering finished",
      body: "The scheduled watering is done.")
  }

  func cancelPlanned() {
    scheduledFor = nil
    center.removePendingNotificationRequests(
      withIdentifiers: [ID.plannedStart, ID.plannedEnd])
  }

  private func schedule(id: String, at date: Date, title: String, body: String) {
    guard date.timeIntervalSinceNow > 5 else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.interruptionLevel = .active
    content.threadIdentifier = "watering"

    let comps = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    let request = UNNotificationRequest(
      identifier: id, content: content,
      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
    center.add(request)
  }

  /// Fire something right now (used when the app itself starts a watering,
  /// so there's feedback even before the hub's push lands).
  func notifyNow(title: String, body: String) {
    guard isAuthorized else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.threadIdentifier = "watering"
    center.add(
      UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil))
  }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
  /// Show banners even with the app open — watering is short, and the whole
  /// point is knowing the moment it happens.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound, .list]
  }
}
