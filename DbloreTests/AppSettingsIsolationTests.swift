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
  private static let aiPanelOpenModeKey = "app.settings.aiPanelOpenMode"
  private static let aiBubblePositionKey = "app.settings.aiBubblePosition"

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

  @Test("MCP settings default off, clamp port and row cap, persist and reset")
  func mcpSettings() throws {
    let name = "AppSettingsIsolationTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }

    let settings = AppSettings(defaults: suite)
    #expect(!settings.mcpEnabled)
    #expect(settings.mcpPort == 41730)
    #expect(settings.mcpAllowedConnectionIDs.isEmpty)
    #expect(settings.mcpRowCap == 200)

    let id = UUID()
    settings.mcpEnabled = true
    settings.mcpPort = 80
    #expect(settings.mcpPort == 1024)
    settings.mcpPort = 70_000
    #expect(settings.mcpPort == 65535)
    settings.mcpPort = 50_000
    settings.mcpAllowedConnectionIDs = [id]
    settings.mcpRowCap = 0
    #expect(settings.mcpRowCap == 1)
    settings.mcpRowCap = 5_000
    #expect(settings.mcpRowCap == 1_000)
    settings.mcpRowCap = 300

    let reloaded = AppSettings(defaults: suite)
    #expect(reloaded.mcpEnabled)
    #expect(reloaded.mcpPort == 50_000)
    #expect(reloaded.mcpAllowedConnectionIDs == [id])
    #expect(reloaded.mcpRowCap == 300)

    reloaded.resetToDefaults()
    let reset = AppSettings(defaults: suite)
    #expect(!reset.mcpEnabled)
    #expect(reset.mcpPort == 41730)
    #expect(reset.mcpAllowedConnectionIDs.isEmpty)
    #expect(reset.mcpRowCap == 200)
  }

  @Test("AI sidebar width and bubble card size default, clamp, persist and reset")
  func aiAssistantSizes() throws {
    let name = "AppSettingsIsolationTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }

    let settings = AppSettings(defaults: suite)
    #expect(settings.aiSidebarWidth == ComponentSize.sidebarWidth)
    #expect(settings.aiBubbleCardWidth == nil)
    #expect(settings.aiBubbleCardHeight == nil)

    settings.aiSidebarWidth = 100
    #expect(settings.aiSidebarWidth == ComponentSize.sidebarWidth)
    settings.aiSidebarWidth = 480
    settings.aiBubbleCardWidth = 10
    #expect(settings.aiBubbleCardWidth == Double(AIBubbleLayout.minCardWidth))
    settings.aiBubbleCardWidth = 500
    settings.aiBubbleCardHeight = 10
    #expect(settings.aiBubbleCardHeight == Double(AIBubbleLayout.minCardHeight))
    settings.aiBubbleCardHeight = 700

    let reloaded = AppSettings(defaults: suite)
    #expect(reloaded.aiSidebarWidth == 480)
    #expect(reloaded.aiBubbleCardWidth == 500)
    #expect(reloaded.aiBubbleCardHeight == 700)

    reloaded.aiBubbleCardHeight = nil
    #expect(suite.object(forKey: "app.settings.aiBubbleCardHeight") == nil)

    reloaded.resetToDefaults()
    let reset = AppSettings(defaults: suite)
    #expect(reset.aiSidebarWidth == ComponentSize.sidebarWidth)
    #expect(reset.aiBubbleCardWidth == nil)
    #expect(reset.aiBubbleCardHeight == nil)
  }
}
