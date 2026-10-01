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

  @Test("Defaults are the small system result face and a 12pt editor, and are not stored")
  func defaults() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      #expect(settings.resultFontSize == AppSettings.defaultResultFontSize)
      #expect(settings.resultFontSize == NSFont.smallSystemFontSize)
      #expect(settings.editorFontSize == 12)
      #expect(suite.object(forKey: Self.resultKey) == nil)
      #expect(suite.object(forKey: Self.editorKey) == nil)
    }
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

  @Test("Sizes outside 9...24 clamp, including a stored value")
  func clamps() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.resultFontSize = 4
      settings.editorFontSize = 100
      #expect(settings.resultFontSize == 9)
      #expect(settings.editorFontSize == 24)
      #expect(suite.object(forKey: Self.resultKey) as? Double == 9)
      #expect(suite.object(forKey: Self.editorKey) as? Double == 24)

      suite.set(2.2, forKey: Self.resultKey)
      suite.set(40, forKey: Self.editorKey)
      let reloaded = AppSettings(defaults: suite)
      #expect(reloaded.resultFontSize == 9)
      #expect(reloaded.editorFontSize == 24)
      #expect(suite.object(forKey: Self.resultKey) as? Double == 9)
      #expect(suite.object(forKey: Self.editorKey) as? Double == 24)
    }
  }

  @Test("Reset restores both font sizes")
  func reset() throws {
    try withIsolatedDefaults { suite in
      let settings = AppSettings(defaults: suite)
      settings.resultFontSize = 20
      settings.editorFontSize = 20
      settings.resetToDefaults()
      #expect(settings.resultFontSize == AppSettings.defaultResultFontSize)
      #expect(settings.editorFontSize == AppSettings.defaultEditorFontSize)
    }
  }

  @Test("Result row height stays 26pt at the default size and scales otherwise")
  func rowHeight() {
    #expect(ResultGridView.rowHeight(fontSize: AppSettings.defaultResultFontSize) == 26)
    #expect(ResultGridView.rowHeight == 26)
    let larger = AppSettings.defaultResultFontSize + 4
    #expect(
      ResultGridView.rowHeight(fontSize: larger)
        > ResultGridView.rowHeight(fontSize: AppSettings.defaultResultFontSize))
    #expect(AppSettings.resultRowNumberFontSize(for: AppSettings.defaultResultFontSize) == 10)
    #expect(AppSettings.editorGutterFontSize(for: AppSettings.defaultEditorFontSize) == 11)
    #expect(AppSettings.editorGutterFontSize(for: 13) == 12)
    #expect(AppSettings.editorGutterFontSize(for: 9) == 9)
  }

  @Test("The first recorded font size does not ask for a reload; a later one does")
  func noteFontSizeReloadsOnlyAfterAChange() {
    let coordinator = ResultGridCoordinator()
    let table = NSTableView()
    #expect(coordinator.noteFontSize(AppSettings.defaultResultFontSize, tableView: table) == false)
    #expect(coordinator.noteFontSize(AppSettings.defaultResultFontSize, tableView: table) == false)
    #expect(coordinator.noteFontSize(18, tableView: table) == true)
    #expect(table.rowHeight == ResultGridView.rowHeight(fontSize: 18))
  }

  @Test("Syntax highlighting uses the default editor face until the setting changes")
  func highlighterFont() {
    #expect(SQLSyntaxHighlighter.Palette().font.pointSize == AppSettings.defaultEditorFontSize)
  }
}
