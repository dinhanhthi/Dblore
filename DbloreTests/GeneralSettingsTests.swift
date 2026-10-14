// GeneralSettingsTests.swift
// General settings: opening windows as native tabs (default off), the type of tab
// created by default (default notebook), launch behavior (default welcome) and
// confirming Cmd+Q (default off) persist, reset, and tolerate unknown stored values.

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

  @Test("Chosen values persist and reload")
  func persists() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.openWindowsAsTabs = true
      settings.defaultNewTabType = .markdownFile
      settings.launchBehavior = .restoreLastSession
      #expect(suite.string(forKey: Self.launchKey) == "restoreLastSession")
      let reloaded = AppSettings(defaults: suite)
      #expect(reloaded.openWindowsAsTabs == true)
      #expect(reloaded.defaultNewTabType == .markdownFile)
      #expect(reloaded.launchBehavior == .restoreLastSession)
    }
  }

  @Test("Confirm before quitting is off by default, persists and resets")
  func confirmBeforeQuit() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      #expect(settings.confirmBeforeQuit == false)
      settings.confirmBeforeQuit = true
      #expect(AppSettings(defaults: suite).confirmBeforeQuit == true)
      settings.resetToDefaults()
      #expect(AppSettings(defaults: suite).confirmBeforeQuit == false)
    }
  }

  // MARK: - Long-query notifications

  private static let notifyKey = "app.settings.notifyLongQueries"
  private static let thresholdKey = "app.settings.longQueryThresholdSeconds"
  private static let inactiveKey = "app.settings.notifyOnlyWhenInactive"

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
