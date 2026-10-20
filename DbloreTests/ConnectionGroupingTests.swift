// ConnectionGroupingTests.swift
// Grouping of saved connections by group name

import Foundation
import Testing

@testable import Dblore

@Suite("Connection grouping")
@MainActor
struct ConnectionGroupingTests {

  private func entry(_ name: String, group: String?) -> ConnectionHistoryEntry {
    ConnectionHistoryEntry(config: ConnectionConfig(host: name, name: name, groupName: group))
  }

  @Test("Groups sort by name case-insensitively, ungrouped last, input order kept within a group")
  func groupedOrder() {
    let entries = [
      entry("a", group: nil),
      entry("b", group: "staging"),
      entry("c", group: "Prod"),
      entry("d", group: "analytics"),
      entry("e", group: "staging"),
      entry("f", group: nil),
      entry("g", group: "Prod"),
    ]

    let groups = ConnectionAppearance.grouped(entries)

    #expect(groups.map(\.name) == ["analytics", "Prod", "staging", nil])
    #expect(
      groups.map { $0.entries.map(\.config.name) } == [
        ["d"], ["c", "g"], ["b", "e"], ["a", "f"],
      ])
  }

  @Test("No entries give no groups; only ungrouped entries give one nil group")
  func groupedEdges() {
    #expect(ConnectionAppearance.grouped([]).isEmpty)
    let groups = ConnectionAppearance.grouped([entry("a", group: nil), entry("b", group: nil)])
    #expect(groups.map(\.name) == [nil])
    #expect(groups.first?.entries.map(\.config.name) == ["a", "b"])
  }
}
