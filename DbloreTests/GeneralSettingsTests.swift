// GeneralSettingsTests.swift
// General settings: opening windows as native tabs (default off), the type of tab
// created by default (default notebook), and launch behavior (default welcome)
// persist, reset, and tolerate unknown stored values.

import Foundation
import Testing

@testable import Dblore

@Suite("General settings")
@MainActor
struct GeneralSettingsTests {
  private static let tabsKey = "app.settings.openWindowsAsTabs"
  private static let typeKey = "app.settings.defaultNewTabType"
  private static let launchKey = "app.settings.launchBehavior"

  private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let name = "GeneralSettingsTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    try body(suite)
  }

  @Test("Defaults are windows not as tabs, notebook as new tab type, and welcome at launch")
  func defaults() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      #expect(settings.openWindowsAsTabs == false)
      #expect(settings.defaultNewTabType == .notebook)
      #expect(settings.launchBehavior == .welcome)
      #expect(LaunchBehavior.welcome.title == "Show Welcome screen")
      #expect(LaunchBehavior.restoreLastSession.title == "Restore last sessions")
    }
  }

  @Test("Chosen values persist and reload")
  func persists() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.openWindowsAsTabs = true
      settings.defaultNewTabType = .sqlFile
      settings.launchBehavior = .restoreLastSession
      #expect(suite.string(forKey: Self.launchKey) == "restoreLastSession")
      let reloaded = AppSettings(defaults: suite)
      #expect(reloaded.openWindowsAsTabs == true)
      #expect(reloaded.defaultNewTabType == .sqlFile)
      #expect(reloaded.launchBehavior == .restoreLastSession)
    }
  }

  @Test("Choosing Welcome removes the saved launch snapshot; Restore keeps it")
  func welcomeClearsSnapshot() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      suite.set(Data("snapshot".utf8), forKey: LaunchSessionStore.key)
      settings.launchBehavior = .restoreLastSession
      #expect(suite.data(forKey: LaunchSessionStore.key) != nil)
      settings.launchBehavior = .welcome
      #expect(suite.data(forKey: LaunchSessionStore.key) == nil)
    }
  }

  @Test("resetToDefaults removes the saved launch snapshot")
  func resetClearsSnapshot() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      suite.set(Data("snapshot".utf8), forKey: LaunchSessionStore.key)
      settings.resetToDefaults()
      #expect(suite.data(forKey: LaunchSessionStore.key) == nil)
    }
  }

  @Test("resetToDefaults restores windows, new tab type, and welcome at launch")
  func resets() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.openWindowsAsTabs = true
      settings.defaultNewTabType = .sqlFile
      settings.launchBehavior = .restoreLastSession
      settings.resetToDefaults()
      #expect(settings.openWindowsAsTabs == false)
      #expect(settings.defaultNewTabType == .notebook)
      #expect(settings.launchBehavior == .welcome)
    }
  }

  @Test("An unknown stored type falls back to notebook")
  func unknownTypeFallsBack() throws {
    try withIsolatedDefaults { suite in
      suite.set("bogus", forKey: Self.typeKey)
      let settings = AppSettings(defaults: suite)
      #expect(settings.defaultNewTabType == .notebook)
    }
  }

  @Test("An unknown stored launch behavior falls back to welcome")
  func unknownLaunchBehaviorFallsBack() throws {
    try withIsolatedDefaults { suite in
      suite.set("bogus", forKey: Self.launchKey)
      let settings = AppSettings(defaults: suite)
      #expect(settings.launchBehavior == .welcome)
    }
  }

  // MARK: - Long-query notifications

  private static let notifyKey = "app.settings.notifyLongQueries"
  private static let thresholdKey = "app.settings.longQueryThresholdSeconds"
  private static let inactiveKey = "app.settings.notifyOnlyWhenInactive"

  @Test("Long-query notifications default to off, 10 seconds, only when inactive")
  func notificationDefaults() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      #expect(settings.notifyLongQueries == false)
      #expect(settings.longQueryThresholdSeconds == 10)
      #expect(settings.notifyOnlyWhenInactive == true)
    }
  }

  @Test("Long-query notification settings persist and reload")
  func notificationPersists() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.notifyLongQueries = true
      settings.longQueryThresholdSeconds = 45
      settings.notifyOnlyWhenInactive = false
      #expect(suite.bool(forKey: Self.notifyKey) == true)
      #expect(suite.double(forKey: Self.thresholdKey) == 45)
      #expect(suite.object(forKey: Self.inactiveKey) as? Bool == false)
      let reloaded = AppSettings(defaults: suite)
      #expect(reloaded.notifyLongQueries == true)
      #expect(reloaded.longQueryThresholdSeconds == 45)
      #expect(reloaded.notifyOnlyWhenInactive == false)
    }
  }

  @Test("The threshold is clamped to 1...3600 seconds when set and when loaded")
  func thresholdClamps() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.longQueryThresholdSeconds = 0
      #expect(settings.longQueryThresholdSeconds == 1)
      #expect(suite.double(forKey: Self.thresholdKey) == 1)
      settings.longQueryThresholdSeconds = 99_999
      #expect(settings.longQueryThresholdSeconds == 3600)
      suite.set(-5.0, forKey: Self.thresholdKey)
      #expect(AppSettings(defaults: suite).longQueryThresholdSeconds == 1)
      suite.set(Double.nan, forKey: Self.thresholdKey)
      #expect(AppSettings(defaults: suite).longQueryThresholdSeconds == 10)
    }
  }

  @Test("resetToDefaults restores the long-query notification settings")
  func notificationResets() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.notifyLongQueries = true
      settings.longQueryThresholdSeconds = 120
      settings.notifyOnlyWhenInactive = false
      settings.resetToDefaults()
      #expect(settings.notifyLongQueries == false)
      #expect(settings.longQueryThresholdSeconds == 10)
      #expect(settings.notifyOnlyWhenInactive == true)
      let reloaded = AppSettings(defaults: suite)
      #expect(reloaded.notifyLongQueries == false)
      #expect(reloaded.longQueryThresholdSeconds == 10)
      #expect(reloaded.notifyOnlyWhenInactive == true)
    }
  }

  @Test("The notification snapshot reflects the current values")
  func notificationSnapshot() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      #expect(
        settings.queryNotificationSettings
          == QueryNotificationSettings(enabled: false, thresholdSeconds: 10, onlyWhenInactive: true)
      )
      settings.notifyLongQueries = true
      settings.longQueryThresholdSeconds = 30
      settings.notifyOnlyWhenInactive = false
      #expect(
        settings.queryNotificationSettings
          == QueryNotificationSettings(enabled: true, thresholdSeconds: 30, onlyWhenInactive: false)
      )
    }
  }

  @Test("Enabling notifications keeps them on when permission is granted")
  func enableGranted() async throws {
    let name = "GeneralSettingsTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: suite)
    var asked = 0
    let granted = await settings.enableLongQueryNotifications {
      asked += 1
      return true
    }
    #expect(granted)
    #expect(asked == 1)
    #expect(settings.notifyLongQueries == true)
  }

  @Test("Enabling notifications reverts to off when permission is denied")
  func enableDenied() async throws {
    let name = "GeneralSettingsTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: suite)
    let granted = await settings.enableLongQueryNotifications { false }
    #expect(!granted)
    #expect(settings.notifyLongQueries == false)
    #expect(suite.bool(forKey: Self.notifyKey) == false)
  }
}
