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

  @Test("an empty query keeps every tab and lists no settings")
  func emptyQueryKeepsEveryTab() {
    let matches = Tab.search("  ")
    #expect(matches.map(\.tab) == Tab.allCases)
    #expect(matches.allSatisfy { $0.entries.isEmpty })
  }

  @Test("a setting title matches across tabs, in tab order")
  func titleMatchesAcrossTabs() {
    let matches = Tab.search("word wrap")
    #expect(matches.map(\.tab) == [.editor, .shortcuts])
    #expect(titles(matches, in: .editor).first == "Word Wrap")
    #expect(titles(matches, in: .shortcuts).contains("Toggle Word Wrap"))
  }

  @Test("a typo still finds the setting")
  func typoFindsSetting() {
    let matches = Tab.search("syntx")
    #expect(titles(matches, in: .editor).contains("Enable Syntax Highlighting"))
  }

  @Test("a description-only hit finds the setting")
  func descriptionHitFindsSetting() {
    let matches = Tab.search("keychain")
    #expect(titles(matches, in: .data) == ["Saved credentials"])
  }

  @Test("a tab name match shows the tab without listing its settings")
  func tabNameMatchListsNoSettings() {
    let matches = Tab.search("appearance")
    #expect(matches.contains { $0.tab == .appearance })
    #expect(titles(matches, in: .appearance).isEmpty)
  }

  @Test("keywords may split between the tab name and a setting")
  func keywordsSplitBetweenTabAndSetting() {
    let matches = Tab.search("results font")
    #expect(titles(matches, in: .results).first == "Font Size")
  }

  @Test("a title hit ranks above a description hit")
  func titleRanksAboveDescription() {
    let matches = Tab.search("touch")
    #expect(titles(matches, in: .security).first == "Use Touch ID")
  }

  @Test("nothing matches gibberish")
  func gibberishMatchesNothing() {
    #expect(Tab.search("zzqxj").isEmpty)
  }
}
