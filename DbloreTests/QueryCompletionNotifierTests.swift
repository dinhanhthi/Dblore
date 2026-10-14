// QueryCompletionNotifierTests.swift
// Long-query notifications: when to post, what the text says (never SQL, data or server error
// text), and that the notifier posts one replaceable notification per tab only when authorized.

import Foundation
import Testing

@testable import Dblore

/// Records posted requests; authorization status is fixed per instance.
private actor RecordingNotificationCenter: QueryNotificationCenter {
  private let status: QueryNotificationAuthorization
  private(set) var requests: [QueryNotificationRequest] = []
  private(set) var authorizationRequests = 0

  init(status: QueryNotificationAuthorization) { self.status = status }

  func requestAuthorization() async -> Bool {
    authorizationRequests += 1
    return status == .granted
  }

  func authorizationStatus() async -> QueryNotificationAuthorization { status }

  func add(_ request: QueryNotificationRequest) async { requests.append(request) }
}

@Suite("Query completion notifier")
struct QueryCompletionNotifierTests {
  @Test(
    "shouldNotify truth table",
    arguments: [
      // (elapsed, appActive, enabled, onlyWhenInactive, expected)
      (5.0, false, true, true, false),  // below threshold
      (10.0, false, true, true, true),  // exactly at threshold, inactive
      (12.0, true, true, true, false),  // active, only-when-inactive on
      (12.0, true, true, false, true),  // active, only-when-inactive off
      (12.0, false, true, false, true),  // inactive, only-when-inactive off
      (12.0, false, false, true, false),  // disabled
    ])
  func shouldNotify(
    elapsed: TimeInterval, appActive: Bool, enabled: Bool, onlyWhenInactive: Bool, expected: Bool
  ) {
    let result = QueryCompletionNotifier.shouldNotify(
      elapsed: elapsed, threshold: 10, appActive: appActive, enabled: enabled,
      onlyWhenInactive: onlyWhenInactive)
    #expect(result == expected)
  }

  @Test("content never carries SQL, data values or server error text")
  func contentHasNoSensitiveText() {
    // The outcome type has no payload for SQL, values or error text, so none can leak; the only
    // free text is the tab name, which the user chose.
    let sql = "SELECT secret_column FROM users WHERE email = 'a@b.c'"
    for outcome: QueryCompletionOutcome in [.rows(42), .affected(3), .failed, .cancelled] {
      let content = QueryCompletionNotifier.makeContent(
        tabName: "Users", elapsed: 15, outcome: outcome)
      for text in [content.title, content.body] {
        #expect(!text.contains(sql))
        #expect(!text.contains("secret_column"))
        #expect(!text.contains("a@b.c"))
        #expect(!text.lowercased().contains("error"))
      }
    }
  }

  @Test("notifier posts once with an identifier tied to the tab")
  @MainActor
  func postsWhenAuthorized() async {
    let center = RecordingNotificationCenter(status: .granted)
    let notifier = QueryCompletionNotifier(center: center)
    let tabID = UUID()
    await notifier.notifyIfNeeded(
      tabID: tabID, tabName: "Orders", elapsed: 20, outcome: .rows(3),
      settings: QueryNotificationSettings(
        enabled: true, thresholdSeconds: 10, onlyWhenInactive: true),
      appActive: false)
    let requests = await center.requests
    #expect(requests.count == 1)
    #expect(requests.first?.identifier == QueryCompletionNotifier.identifier(for: tabID))
    #expect(requests.first?.identifier.contains(tabID.uuidString) == true)
    #expect(requests.first?.userInfo["tabID"] == tabID.uuidString)
    #expect(requests.first?.body == "Orders · 20.0 s · 3 rows")
    #expect(await center.authorizationRequests == 0)
  }

  @Test(
    "notifier posts nothing when unauthorized or below threshold",
    arguments: [
      QueryNotificationAuthorization.denied, .notDetermined,
    ])
  @MainActor
  func postsNothingWhenUnauthorized(status: QueryNotificationAuthorization) async {
    let center = RecordingNotificationCenter(status: status)
    let notifier = QueryCompletionNotifier(center: center)
    let settings = QueryNotificationSettings(
      enabled: true, thresholdSeconds: 10, onlyWhenInactive: true)
    await notifier.notifyIfNeeded(
      tabID: UUID(), tabName: "T", elapsed: 20, outcome: .failed, settings: settings,
      appActive: false)
    #expect(await center.requests.isEmpty)
    // Never prompts from the run path; prompting happens when the setting is enabled.
    #expect(await center.authorizationRequests == 0)
  }
}
