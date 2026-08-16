import Foundation
import UIKit
import UserNotifications

/// Watering notifications are pushed by the hub over APNs, and only ever by
/// the hub. It is the one party that knows whether water actually ran.
///
/// This used to also schedule a local pair in advance, predicted from the
/// published plan, on the theory that they would arrive even with the board
/// unreachable. They did, and that was the problem: a scheduled local
/// notification can only be cancelled while the app is running. When the
/// plan changed with the app closed (rain forecast, or the camera seeing the
/// roof already wet) the stale pair fired anyway and announced a watering
/// that never happened. A notification that says "your garden is being
/// watered" is a claim about the world, and the phone is not in a position
/// to make it.
///
/// `cancelPlanned()` survives only to clear the pairs older builds queued on
/// devices that still have them pending.
@MainActor
final class NotificationManager: NSObject {
  static let shared = NotificationManager()

  private let center = UNUserNotificationCenter.current()

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

  /// Drop any predicted pair an older build queued on this device. Without
  /// this they stay pending in iOS and keep firing after the update.
  func cancelPlanned() {
    center.removePendingNotificationRequests(
      withIdentifiers: [ID.plannedStart, ID.plannedEnd])
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
