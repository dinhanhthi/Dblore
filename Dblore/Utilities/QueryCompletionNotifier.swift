// QueryCompletionNotifier.swift
// Posts a local notification when a long query finishes. The text carries only the tab name,
// the duration and a row count or "failed": never SQL, data values or server error text.
// One notification per tab (stable identifier), so a newer one replaces the older one.

import Foundation
import UserNotifications

nonisolated enum QueryNotificationAuthorization: Sendable, Equatable {
  case granted
  case denied
  case notDetermined
}

nonisolated struct QueryNotificationRequest: Sendable, Equatable {
  let identifier: String
  let title: String
  let body: String
  let userInfo: [String: String]
}

/// How a run ended. No payload beyond counts, so SQL, values and error text cannot leak.
nonisolated enum QueryCompletionOutcome: Sendable, Equatable {
  case rows(Int)
  case affected(Int)
  case failed
  case cancelled
}

/// Snapshot of the notification settings at the time a run finishes.
nonisolated struct QueryNotificationSettings: Sendable, Equatable {
  let enabled: Bool
  let thresholdSeconds: TimeInterval
  let onlyWhenInactive: Bool
}

nonisolated protocol QueryNotificationCenter: Sendable {
  func requestAuthorization() async -> Bool
  func authorizationStatus() async -> QueryNotificationAuthorization
  func add(_ request: QueryNotificationRequest) async
}

/// `UNUserNotificationCenter` wrapper. Local notifications need no extra entitlement.
nonisolated struct SystemQueryNotificationCenter: QueryNotificationCenter {
  func requestAuthorization() async -> Bool {
    let center = UNUserNotificationCenter.current()
    return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
  }

  func authorizationStatus() async -> QueryNotificationAuthorization {
    switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
    case .authorized, .provisional: .granted
    case .notDetermined: .notDetermined
    default: .denied
    }
  }

  func add(_ request: QueryNotificationRequest) async {
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.userInfo = request.userInfo
    content.sound = .default
    let unRequest = UNNotificationRequest(
      identifier: request.identifier, content: content, trigger: nil)
    try? await UNUserNotificationCenter.current().add(unRequest)
  }
}

@MainActor
final class QueryCompletionNotifier {
  /// `userInfo` key holding the tab's UUID string, for click routing.
  nonisolated static let tabIDKey = "tabID"

  private let center: any QueryNotificationCenter

  init(center: any QueryNotificationCenter = SystemQueryNotificationCenter()) {
    self.center = center
  }

  /// Asks the system for permission; call when the user enables the setting.
  func requestAuthorization() async -> Bool {
    await center.requestAuthorization()
  }

  /// Posts a notification when the run qualifies and permission is already granted. Never prompts.
  /// `appActive` comes from the caller (normally `NSApplication.shared.isActive`).
  func notifyIfNeeded(
    tabID: UUID, tabName: String, elapsed: TimeInterval, outcome: QueryCompletionOutcome,
    settings: QueryNotificationSettings, appActive: Bool
  ) async {
    guard
      Self.shouldNotify(
        elapsed: elapsed, threshold: settings.thresholdSeconds, appActive: appActive,
        enabled: settings.enabled, onlyWhenInactive: settings.onlyWhenInactive)
    else { return }
    guard await center.authorizationStatus() == .granted else { return }
    let content = Self.makeContent(tabName: tabName, elapsed: elapsed, outcome: outcome)
    await center.add(
      QueryNotificationRequest(
        identifier: Self.identifier(for: tabID), title: content.title, body: content.body,
        userInfo: [Self.tabIDKey: tabID.uuidString]))
  }

  nonisolated static func shouldNotify(
    elapsed: TimeInterval, threshold: TimeInterval, appActive: Bool, enabled: Bool,
    onlyWhenInactive: Bool
  ) -> Bool {
    enabled && elapsed >= threshold && (!onlyWhenInactive || !appActive)
  }

  nonisolated static func identifier(for tabID: UUID) -> String {
    "query-complete-\(tabID.uuidString)"
  }

  nonisolated static func makeContent(
    tabName: String, elapsed: TimeInterval, outcome: QueryCompletionOutcome
  ) -> (title: String, body: String) {
    let title: String
    let detail: String
    switch outcome {
    case .rows(let count):
      title = "Query finished"
      detail = count == 1 ? "1 row" : "\(formatCount(count)) rows"
    case .affected(let count):
      title = "Query finished"
      detail = count == 1 ? "1 row affected" : "\(formatCount(count)) rows affected"
    case .failed:
      title = "Query failed"
      detail = "failed"
    case .cancelled:
      title = "Query cancelled"
      detail = "cancelled"
    }
    return (title, "\(tabName) · \(formatDuration(elapsed)) · \(detail)")
  }

  /// "12.4 s" under a minute, then "2 m 5 s", then "1 h 2 m" (zero trailing units dropped).
  nonisolated static func formatDuration(_ elapsed: TimeInterval) -> String {
    let tenths = (max(elapsed, 0) * 10).rounded()
    if tenths < 600 {
      return String(format: "%.1f s", locale: posixLocale, tenths / 10)
    }
    let total = Int(elapsed.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
      return minutes > 0 ? "\(hours) h \(minutes) m" : "\(hours) h"
    }
    return seconds > 0 ? "\(minutes) m \(seconds) s" : "\(minutes) m"
  }

  private nonisolated static let posixLocale = Locale(identifier: "en_US_POSIX")

  /// Grouped with "," to match the English notification text.
  private nonisolated static func formatCount(_ count: Int) -> String {
    count.formatted(.number.locale(Locale(identifier: "en_US")))
  }
}
