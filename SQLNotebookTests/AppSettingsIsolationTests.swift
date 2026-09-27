// AppSettingsIsolationTests.swift
// The test run never reads or writes the user's real app settings: `AppSettings` uses the
// injected UserDefaults, and `AppSettings.shared` under XCTest is backed by a test suite.

import Foundation
import Testing

@testable import SQLNotebook

@Suite("AppSettings isolation")
@MainActor
struct AppSettingsIsolationTests {
  private static let simpleModeKey = "app.settings.editorSimpleMode"

  @Test("AppSettings(defaults:) reads and writes only the given suite")
  func injectedSuiteOnly() throws {
    let name = "AppSettingsIsolationTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    suite.set(true, forKey: Self.simpleModeKey)
    let standardBefore = UserDefaults.standard.object(forKey: Self.simpleModeKey) as? Bool

    let settings = AppSettings(defaults: suite)
    #expect(settings.editorSimpleMode == true)
    settings.editorSimpleMode = false

    #expect(suite.object(forKey: Self.simpleModeKey) as? Bool == false)
    #expect(UserDefaults.standard.object(forKey: Self.simpleModeKey) as? Bool == standardBefore)
  }

  @Test("Shared settings under XCTest are not backed by UserDefaults.standard")
  func sharedUsesTestSuite() {
    #expect(SessionManager.isRunningAsTestHost)
    #expect(AppSettings.sharedDefaults !== UserDefaults.standard)
  }

  @Test("Commit inline edits immediately: off by default, persisted, reset to off")
  func inlineEditAutoCommitSetting() throws {
    let name = "AppSettingsIsolationTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }

    let settings = AppSettings(defaults: suite)
    #expect(settings.inlineEditAutoCommit == false)
    settings.inlineEditAutoCommit = true
    #expect(AppSettings(defaults: suite).inlineEditAutoCommit == true)
    settings.resetToDefaults()
    #expect(AppSettings(defaults: suite).inlineEditAutoCommit == false)
  }
}
