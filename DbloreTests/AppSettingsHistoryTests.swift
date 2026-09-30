// AppSettingsHistoryTests.swift
// Query history retention on AppSettings: enabled flag, allowed retention days, and a
// clamped entry cap. Every case uses its own UserDefaults suite.

import Foundation
import Testing

@testable import Dblore

@Suite("AppSettings history retention")
@MainActor
struct AppSettingsHistoryTests {
  private static let enabledKey = "app.settings.historyEnabled"
  private static let retentionKey = "app.settings.historyRetentionDays"
  private static let maxEntriesKey = "app.settings.historyMaxEntries"

  /// A fresh, empty UserDefaults suite, removed when `body` returns
  private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let name = "AppSettingsHistoryTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    try body(suite)
  }

  @Test("History settings default to enabled, 90 days, and 50,000 entries")
  func defaults() throws {
    let standardBefore = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      #expect(settings.historyEnabled == true)
      #expect(settings.historyRetentionDays == 90)
      #expect(settings.historyMaxEntries == 50_000)
      #expect(suite.object(forKey: Self.enabledKey) == nil)
      #expect(suite.object(forKey: Self.retentionKey) == nil)
      #expect(suite.object(forKey: Self.maxEntriesKey) == nil)
    }
    #expect(UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool == standardBefore)
  }

  @Test("Each allowed retention day persists", arguments: [7, 30, 90, 365, 0])
  func allowedRetentionPersists(_ days: Int) throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      // 90 is already the default, so didSet would not run until the value changes
      if days == 90 {
        settings.historyRetentionDays = 7
      }
      settings.historyRetentionDays = days
      #expect(settings.historyRetentionDays == days)
      #expect(suite.object(forKey: Self.retentionKey) as? Int == days)
      #expect(AppSettings(defaults: suite).historyRetentionDays == days)
    }
  }

  @Test("Illegal retention snaps to 90 and a stored illegal value reads as 90")
  func illegalRetentionSnapsTo90() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.historyRetentionDays = 14
      #expect(settings.historyRetentionDays == 90)
      #expect(suite.object(forKey: Self.retentionKey) as? Int == 90)

      suite.set(45, forKey: Self.retentionKey)
      let reread = AppSettings(defaults: suite)
      #expect(reread.historyRetentionDays == 90)
      #expect(suite.object(forKey: Self.retentionKey) as? Int == 90)
    }
  }

  @Test("Max entries clamps below 1,000 and above 500,000")
  func maxEntriesClamps() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.historyMaxEntries = 999
      #expect(settings.historyMaxEntries == 1_000)
      #expect(suite.object(forKey: Self.maxEntriesKey) as? Int == 1_000)

      settings.historyMaxEntries = 500_001
      #expect(settings.historyMaxEntries == 500_000)
      #expect(suite.object(forKey: Self.maxEntriesKey) as? Int == 500_000)

      suite.set(12, forKey: Self.maxEntriesKey)
      #expect(AppSettings(defaults: suite).historyMaxEntries == 1_000)
      suite.set(900_000, forKey: Self.maxEntriesKey)
      #expect(AppSettings(defaults: suite).historyMaxEntries == 500_000)
    }
  }

  @Test("History enabled toggles persist across a new AppSettings")
  func enabledTogglesPersist() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.historyEnabled = false
      #expect(suite.object(forKey: Self.enabledKey) as? Bool == false)
      #expect(AppSettings(defaults: suite).historyEnabled == false)

      settings.historyEnabled = true
      #expect(suite.object(forKey: Self.enabledKey) as? Bool == true)
      #expect(AppSettings(defaults: suite).historyEnabled == true)
    }
  }
}
