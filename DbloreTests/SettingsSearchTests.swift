// SettingsSearchTests.swift
// The settings sidebar search finds tabs by name and settings by title or description.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Settings search")
struct SettingsSearchTests {
  private typealias Tab = SettingsModal.SettingsTab

  private func titles(_ matches: [SettingsSearchMatch], in tab: Tab) -> [String] {
    matches.first { $0.tab == tab }?.entries.map(\.title) ?? []
  }

  @Test("a setting title matches across tabs, in tab order")
  func titleMatchesAcrossTabs() {
    let matches = Tab.search("word wrap")
    #expect(matches.map(\.tab) == [.editor, .shortcuts])
    #expect(titles(matches, in: .editor).first == "Word Wrap")
    #expect(titles(matches, in: .shortcuts).contains("Toggle Word Wrap"))
  }

}
