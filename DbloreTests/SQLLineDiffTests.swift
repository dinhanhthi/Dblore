// SQLLineDiffTests.swift
// The local line diff: identical texts, inserts, deletes, context lines, hunk splitting and the
// whole-replace fallback for huge inputs

import Foundation
import Testing

@testable import Dblore

@Suite("SQLLineDiff")
struct SQLLineDiffTests {

  private static func text(_ range: ClosedRange<Int>) -> String {
    range.map { "line \($0)" }.joined(separator: "\n")
  }

  @Test func identicalTextsHaveNoHunks() {
    #expect(SQLLineDiff.unified(old: "SELECT 1\nFROM t\n", new: "SELECT 1\nFROM t").isEmpty)
  }

  @Test func middleChangeKeepsContextLines() {
    let old = Self.text(1...9)
    let new = old.replacingOccurrences(of: "line 5", with: "line five")
    #expect(
      SQLLineDiff.unified(old: old, new: new) == [
        .init(
          oldStart: 2, oldCount: 7, newStart: 2, newCount: 7,
          lines: [
            .context("line 2"), .context("line 3"), .context("line 4"), .removed("line 5"),
            .added("line five"), .context("line 6"), .context("line 7"), .context("line 8"),
          ])
      ])
  }

  @Test func pureInsert() {
    #expect(
      SQLLineDiff.unified(old: "a\nc", new: "a\nb\nc") == [
        .init(
          oldStart: 1, oldCount: 2, newStart: 1, newCount: 3,
          lines: [.context("a"), .added("b"), .context("c")])
      ])
  }

  @Test func pureDelete() {
    #expect(
      SQLLineDiff.unified(old: "a\nb\nc", new: "a\nc", context: 0) == [
        .init(oldStart: 2, oldCount: 1, newStart: 1, newCount: 0, lines: [.removed("b")])
      ])
  }

  @Test func emptyOldIsAllAdded() {
    #expect(
      SQLLineDiff.unified(old: "", new: "a\nb") == [
        .init(
          oldStart: 0, oldCount: 0, newStart: 1, newCount: 2, lines: [.added("a"), .added("b")])
      ])
  }

  @Test func emptyNewIsAllRemoved() {
    #expect(
      SQLLineDiff.unified(old: "a", new: "") == [
        .init(oldStart: 1, oldCount: 1, newStart: 0, newCount: 0, lines: [.removed("a")])
      ])
  }

  @Test func farApartChangesSplitIntoTwoHunks() {
    let old = Self.text(1...20)
    let new = old.replacingOccurrences(of: "line 2\n", with: "line two\n")
      .replacingOccurrences(of: "line 18", with: "line eighteen")
    let hunks = SQLLineDiff.unified(old: old, new: new)
    #expect(hunks.count == 2)
    #expect(hunks.map(\.oldStart) == [1, 15])
    #expect(hunks.map(\.newStart) == [1, 15])
  }

  @Test func nearChangesShareOneHunk() {
    let old = Self.text(1...12)
    let new = old.replacingOccurrences(of: "line 3\n", with: "line three\n")
      .replacingOccurrences(of: "line 9\n", with: "line nine\n")
    #expect(SQLLineDiff.unified(old: old, new: new).count == 1)
  }

  @Test func hugeInputFallsBackToWholeReplace() {
    let count = 1_001
    let old = (0..<count).map { "old \($0)" }.joined(separator: "\n")
    let new = (0..<count).map { "new \($0)" }.joined(separator: "\n")
    let hunks = SQLLineDiff.unified(old: "SELECT\n" + old, new: "SELECT\n" + new)
    #expect(hunks.count == 1)
    #expect(hunks.first?.lines.first == .context("SELECT"))
    #expect(
      hunks.first?.lines.dropFirst().prefix(count).allSatisfy { line in
        if case .removed = line { true } else { false }
      } == true)
    #expect(hunks.first?.oldCount == count + 1)
    #expect(hunks.first?.newCount == count + 1)
  }
}
