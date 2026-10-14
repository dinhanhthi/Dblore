// SidebarEntityFilterScoreTests.swift
// Ranked fuzzy scores stay ordered, and a miss scores nil.

import Foundation
import Testing

@testable import Dblore

@Suite("Sidebar entity filter score")
struct SidebarEntityFilterScoreTests {
  @Test("a non-match scores nil exactly when matchesAll rejects that keyword")
  func nonMatchScoresNil() {
    let misses = [("zzzz", "users"), ("ur", "users"), ("abc", "abd"), ("qx", "users")]
    for (keyword, text) in misses {
      #expect(SidebarEntityFilter.score(keyword, in: text) == nil)
      #expect(SidebarEntityFilter.matchesAll(text, keywords: [keyword]) == false)
    }

    let hits = [
      ("users", "users"), ("use", "users"), ("id", "user_id"), ("ser", "users"),
      ("usr", "users"), ("uzers", "users"),
    ]
    for (keyword, text) in hits {
      #expect(SidebarEntityFilter.score(keyword, in: text) != nil)
      #expect(SidebarEntityFilter.matchesAll(text, keywords: [keyword]))
    }
  }
}
