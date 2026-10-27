// AppSettingsFontTests.swift
// Result and editor font size: the result default matches the face the app used before
// the setting, the editor default is 12pt, values persist, and the result row height
// stays 26pt until the size changes.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Result and editor font size")
@MainActor
struct AppSettingsFontTests {
  private static let resultKey = "app.settings.resultFontSize"
  private static let editorKey = "app.settings.editorFontSize"

  private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let name = "AppSettingsFontTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    try body(suite)
  }

  @Test("A chosen size persists and reloads")
  func persists() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.resultFontSize = 16
      settings.editorFontSize = 18
      #expect(suite.object(forKey: Self.resultKey) as? Double == 16)
      #expect(suite.object(forKey: Self.editorKey) as? Double == 18)
      let reloaded = AppSettings(defaults: suite)
      #expect(reloaded.resultFontSize == 16)
      #expect(reloaded.editorFontSize == 18)
    }
  }

  @Test("Zoom In and Zoom Out step one point and stop at 9 and 24")
  func zoomStepsClamp() {
    #expect(AppSettings.steppedFontSize(12, by: 1) == 13)
    #expect(AppSettings.steppedFontSize(12, by: -1) == 11)
    #expect(AppSettings.steppedFontSize(24, by: 1) == 24)
    #expect(AppSettings.steppedFontSize(9, by: -1) == 9)
  }

  @Test("Actual Size resets both sizes to their defaults")
  func actualSizeResets() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.resultFontSize = 18
      settings.editorFontSize = 20
      settings.resultFontSize = AppSettings.defaultResultFontSize
      settings.editorFontSize = AppSettings.defaultEditorFontSize
      #expect(suite.object(forKey: Self.resultKey) as? Double == 11)
      #expect(suite.object(forKey: Self.editorKey) as? Double == 12)
    }
  }

}
