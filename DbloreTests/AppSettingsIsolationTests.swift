// AppSettingsIsolationTests.swift
// The test run never reads or writes the user's real app settings: `AppSettings` uses the
// injected UserDefaults, and `AppSettings.shared` under XCTest is backed by a test suite.

import Foundation
import Testing

@testable import Dblore

@Suite("AppSettings isolation")
@MainActor
struct AppSettingsIsolationTests {
  private static let simpleModeKey = "app.settings.editorSimpleMode"
  private static let safeModeKey = "app.settings.safeMode"
  private static let commitStyleKey = "app.settings.commitStyle"

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

  @Test("Missing commit style and Safe Mode load as review and write neither key")
  func commitStyleDefaultsToReviewWithoutWriting() throws {
    let name = "AppSettingsIsolationTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }

    let settings = AppSettings(defaults: suite)
    #expect(settings.commitStyle == .review)
    #expect(suite.object(forKey: Self.safeModeKey) == nil)
    #expect(suite.object(forKey: Self.commitStyleKey) == nil)
  }

  @Test("Stored Safe Mode alertRead migrates to confirm without writing commit style")
  func commitStyleMigratesAlertReadWithoutWriting() throws {
    let name = "AppSettingsIsolationTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    suite.set(1, forKey: Self.safeModeKey)

    let settings = AppSettings(defaults: suite)
    #expect(settings.commitStyle == .confirm)
    #expect(suite.integer(forKey: Self.safeModeKey) == 1)
    #expect(suite.object(forKey: Self.commitStyleKey) == nil)
  }

  @Test(
    "Assigning commit style writes the raw string and its legacy safe mode",
    arguments: [
      (CommitStyle.review, 0, SafeMode.silent),
      (CommitStyle.confirm, 1, SafeMode.alertRead),
      (CommitStyle.password, 3, SafeMode.safeRead),
    ]
  )
  func assigningCommitStyleWritesLegacySafeMode(
    style: CommitStyle, safeModeRaw: Int, safeMode: SafeMode
  ) throws {
    let name = "AppSettingsIsolationTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }

    let settings = AppSettings(defaults: suite)
    settings.commitStyle = style

    #expect(settings.commitStyle == style)
    #expect(settings.safeMode == safeMode)
    #expect(suite.string(forKey: Self.commitStyleKey) == style.rawValue)
    #expect(suite.object(forKey: Self.safeModeKey) as? Int == safeModeRaw)
  }

  @Test("resetToDefaults writes review and silent safe mode")
  func resetToDefaultsWritesReviewCommitStyle() throws {
    let name = "AppSettingsIsolationTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }

    let settings = AppSettings(defaults: suite)
    settings.commitStyle = .password
    settings.resetToDefaults()

    #expect(settings.commitStyle == .review)
    #expect(settings.safeMode == .silent)
    #expect(suite.string(forKey: Self.commitStyleKey) == CommitStyle.review.rawValue)
    #expect(suite.object(forKey: Self.safeModeKey) as? Int == 0)
  }

  @Test("resetToDefaults writes review when the style is already review")
  func resetToDefaultsWritesReviewWhenAlreadyReview() throws {
    let name = "AppSettingsIsolationTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }

    let settings = AppSettings(defaults: suite)
    settings.safeMode = .alertRead
    settings.resetToDefaults()

    #expect(settings.commitStyle == .review)
    #expect(settings.safeMode == .silent)
    #expect(suite.string(forKey: Self.commitStyleKey) == CommitStyle.review.rawValue)
    #expect(suite.object(forKey: Self.safeModeKey) as? Int == 0)
  }
}
