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

  @Test("The tree nests paths by level, sorted per level, ungrouped last; a flat name stays flat")
  func treeNesting() throws {
    let entries = [
      entry("a", group: "QA B12 / Prod / EU"),
      entry("b", group: nil),
      entry("c", group: "staging"),
      entry("d", group: "QA B12 / Dev"),
      entry("e", group: "QA B12"),
      entry("f", group: "QA B12 / Prod / EU"),
      entry("g", group: "qa b12 / x/y/z"),
    ]

    let tree = ConnectionAppearance.tree(entries)

    #expect(tree.groups.map(\.name) == ["QA B12", "qa b12", "staging"])
    #expect(tree.ungrouped.map(\.config.name) == ["b"])
    try #require(tree.groups.count == 3)
    let qa = tree.groups[0]
    #expect(qa.path == "QA B12" && qa.depth == 0)
    #expect(qa.entries.map(\.config.name) == ["e"])
    #expect(qa.children.map(\.name) == ["Dev", "Prod"])
    let prod = try #require(qa.children.last)
    #expect(prod.entries.isEmpty)
    let eu = try #require(prod.children.first)
    #expect(eu.path == "QA B12 / Prod / EU" && eu.depth == 2)
    #expect(eu.entries.map(\.config.name) == ["a", "f"])
    // A fourth level was merged into the third: never deeper than three
    #expect(tree.groups[1].children.map(\.name) == ["x"])
    #expect(tree.groups[1].children.first?.children.map(\.path) == ["qa b12 / x / y z"])
    #expect(tree.groups[1].children.first?.children.first?.children.isEmpty == true)
    // A flat name is a leaf group
    #expect(tree.groups[2].children.isEmpty)
    #expect(tree.groups[2].entries.map(\.config.name) == ["c"])
    // Pre-order; a collapsed group stays listed and hides its subgroups
    #expect(
      ConnectionAppearance.flattened(tree.groups).map(\.path) == [
        "QA B12", "QA B12 / Dev", "QA B12 / Prod", "QA B12 / Prod / EU", "qa b12", "qa b12 / x",
        "qa b12 / x / y z", "staging",
      ])
    #expect(
      ConnectionAppearance.flattened(tree.groups, collapsed: ["QA B12", "qa b12 / x"]).map(\.path)
        == ["QA B12", "qa b12", "qa b12 / x", "staging"])
  }
}
