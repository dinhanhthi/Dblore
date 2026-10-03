// SidebarEntityFilterScoreTests.swift
// Ranked fuzzy scores stay ordered, and a miss scores nil.

import Foundation
import Testing

@testable import Dblore

@Suite("Sidebar entity filter score")
struct SidebarEntityFilterScoreTests {
  @Test("a worse tier never outranks a better one")
  func worseTierNeverOutranksBetter() throws {
    let scores = try [
      SidebarEntityFilter.score("users", in: "users"),
      SidebarEntityFilter.score("use", in: "users"),
      SidebarEntityFilter.score("id", in: "user_id"),
      SidebarEntityFilter.score("ser", in: "users"),
      SidebarEntityFilter.score("usr", in: "users"),
      SidebarEntityFilter.score("uzers", in: "users"),
    ].map { try #require($0) }

    #expect(scores == scores.sorted(by: >))
    #expect(Set(scores).count == scores.count)

    #expect(SidebarEntityFilter.score("Users", in: "USERS") == scores[0])
    #expect(SidebarEntityFilter.score("id", in: "id_column") == scores[1])
    #expect(SidebarEntityFilter.score("ID", in: "user.id") == scores[2])
    #expect(SidebarEntityFilter.score("id", in: "user id") == scores[2])
    #expect(SidebarEntityFilter.score("id", in: "col2id") == scores[2])
    #expect(SidebarEntityFilter.score("id", in: "valid_id") == scores[2])
    #expect(SidebarEntityFilter.score("id", in: "valid") == scores[3])
    #expect(SidebarEntityFilter.score("USR", in: "Users") == scores[4])
    let stretched = "u" + String(repeating: "_", count: 12) + "sid"
    #expect(SidebarEntityFilter.score("usid", in: stretched) == scores[4])
    #expect(SidebarEntityFilter.score("usres", in: "users") == scores[5])
    #expect(SidebarEntityFilter.score("users", in: "usrs") == scores[5])
    #expect(SidebarEntityFilter.score("usersx", in: "users") == scores[5])
    #expect(SidebarEntityFilter.score("abcd", in: "abce") == scores[5])
  }

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

  @Test("an empty query matches everything, same as matchesAll")
  func emptyQueryMatchesLikeMatchesAll() {
    #expect(SidebarEntityFilter.keywords(in: "") == [])
    #expect(SidebarEntityFilter.keywords(in: " \n\t ") == [])
    #expect(SidebarEntityFilter.matchesAll("users", keywords: []))
    #expect(SidebarEntityFilter.matchesAll("", keywords: []))
    #expect(SidebarEntityFilter.score("", in: "users") != nil)
    #expect(SidebarEntityFilter.score("", in: "") != nil)
    #expect(SidebarEntityFilter.matchesAll("users", keywords: [""]))
    #expect(SidebarEntityFilter.matchesAll("", keywords: [""]))
  }
}
