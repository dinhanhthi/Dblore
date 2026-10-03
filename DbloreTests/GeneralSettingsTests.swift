// GeneralSettingsTests.swift
// General settings: opening windows as native tabs (default off) and the type of tab
// created by default (default notebook) persist, reset, and tolerate unknown stored values.

import Foundation
import Testing

@testable import Dblore

@Suite("General settings")
@MainActor
struct GeneralSettingsTests {
  private static let tabsKey = "app.settings.openWindowsAsTabs"
  private static let typeKey = "app.settings.defaultNewTabType"

  private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let name = "GeneralSettingsTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    try body(suite)
  }

  @Test("Defaults are windows not as tabs and notebook as new tab type")
  func defaults() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      #expect(settings.openWindowsAsTabs == false)
      #expect(settings.defaultNewTabType == .notebook)
    }
  }

  @Test("Chosen values persist and reload")
  func persists() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.openWindowsAsTabs = true
      settings.defaultNewTabType = .sqlFile
      let reloaded = AppSettings(defaults: suite)
      #expect(reloaded.openWindowsAsTabs == true)
      #expect(reloaded.defaultNewTabType == .sqlFile)
    }
  }

  @Test("resetToDefaults restores both")
  func resets() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.openWindowsAsTabs = true
      settings.defaultNewTabType = .sqlFile
      settings.resetToDefaults()
      #expect(settings.openWindowsAsTabs == false)
      #expect(settings.defaultNewTabType == .notebook)
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
}
