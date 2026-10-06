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
}
