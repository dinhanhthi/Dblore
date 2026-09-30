// TableHighlightMatcherTests.swift
// The client-side matcher mirrors the filter's WHERE semantics over loaded rows.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Table Highlight Matcher Tests")
struct TableHighlightMatcherTests {
  private let columns = ["name", "age"]
  private let rows: [[CellValue]] = [
    [.string("Alice"), .int(30)],
    [.string("bob"), .int(9)],
    [.string("Carol"), .null],
  ]

  private func cond(
    _ column: String, _ op: FilterOperator, _ value: String = "",
    _ connector: FilterConnector = .and
  ) -> FilterCondition {
    FilterCondition(column: column, op: op, value: value, connector: connector)
  }

  private func match(
    _ conditions: [FilterCondition], dialect: DatabaseType = .postgresql,
    style: HighlightStyle = .cell
  ) -> [Int: Set<Int>] {
    TableHighlight(filter: TableFilter(conditions: conditions), style: style)
      .matches(rows: rows, columns: columns, dialect: dialect.dialect)
  }

  @Test("Equality and inequality, NULL never matches a comparison")
  func equality() {
    #expect(match([cond("name", .equals, "bob")]) == [1: [0]])
    #expect(Set(match([cond("age", .notEquals, "30")]).keys) == [1])
    #expect(match([cond("age", .equals, "30")]) == [0: [1]])
  }

  @Test("Numbers compare numerically, text by string order")
  func ordering() {
    #expect(Set(match([cond("age", .greaterThan, "10")]).keys) == [0])
    #expect(Set(match([cond("age", .lessThanOrEqual, "9")]).keys) == [1])
    #expect(Set(match([cond("age", .lessThan, "30")]).keys) == [1])
    #expect(Set(match([cond("age", .greaterThanOrEqual, "30")]).keys) == [0])
    #expect(Set(match([cond("name", .lessThan, "b")]).keys) == [0, 2])
  }

  @Test("IN splits on commas, null checks")
  func inAndNull() {
    #expect(Set(match([cond("name", .in, "bob, Carol")]).keys) == [1, 2])
    #expect(Set(match([cond("age", .isNull)]).keys) == [2])
    #expect(Set(match([cond("age", .isNotNull)]).keys) == [0, 1])
  }

  @Test("LIKE wildcards, escaping and per-dialect case rules")
  func like() {
    #expect(Set(match([cond("name", .like, "A%")]).keys) == [0])
    #expect(Set(match([cond("name", .like, "a%")]).keys).isEmpty)
    #expect(Set(match([cond("name", .like, "a%")], dialect: .sqlite).keys) == [0])
    #expect(Set(match([cond("name", .ilike, "a%")]).keys) == [0])
    #expect(Set(match([cond("name", .like, "_ob")]).keys) == [1])
    #expect(Set(match([cond("name", .like, "b.b")]).keys).isEmpty)
    #expect(Set(match([cond("name", .notLike, "%o%")]).keys) == [0])
    #expect(Set(match([cond("name", .notIlike, "%O%")]).keys) == [0])
  }

  @Test("AND binds tighter than OR; cell set holds every true condition of a matching row")
  func precedence() {
    // name = Alice OR name = bob AND age = 9  ->  rows 0 and 1
    let result = match([
      cond("name", .equals, "Alice"), cond("name", .equals, "bob", .or),
      cond("age", .equals, "9", .and),
    ])
    #expect(result == [0: [0], 1: [0, 1]])
    // a failed AND-group paints nothing for the row
    #expect(match([cond("name", .equals, "bob"), cond("age", .equals, "1")]).isEmpty)
  }

  @Test("Incomplete conditions and unknown columns are skipped")
  func skipped() {
    #expect(match([cond("name", .equals, "")]).isEmpty)
    #expect(match([cond("nope", .equals, "x")]).isEmpty)
    #expect(match([cond("nope", .equals, "x"), cond("name", .equals, "bob")]) == [1: [0]])
  }

  private func matchTyped(_ cell: CellValue, _ op: FilterOperator, _ value: String) -> Bool {
    TableHighlight(
      filter: TableFilter(conditions: [cond("c", op, value)]), style: .cell
    ).matches(rows: [[cell]], columns: ["c"], dialect: SQLDialect.postgresql).isEmpty == false
  }

  @Test("Dates compare by value: date-only literal by UTC day, full ISO8601 by instant")
  func dates() {
    let date = CellValue.date(Date(timeIntervalSince1970: 1_704_153_600))  // 2024-01-02T00:00:00Z
    #expect(matchTyped(date, .equals, "2024-01-02"))
    #expect(matchTyped(date, .greaterThan, "2024-01-01"))
    #expect(!matchTyped(date, .greaterThan, "2024-01-02"))
    #expect(matchTyped(date, .equals, "2024-01-02T00:00:00Z"))
    #expect(matchTyped(date, .lessThan, "2024-01-02T01:00:00Z"))
  }

  @Test("UUIDs match case-insensitively")
  func uuids() {
    let id = CellValue.string("123E4567-E89B-12D3-A456-426614174000")
    #expect(matchTyped(id, .equals, "123e4567-e89b-12d3-a456-426614174000"))
    #expect(matchTyped(id, .in, "123e4567-e89b-12d3-a456-426614174000"))
  }

  @Test("Booleans accept t/f/true/false/1/0")
  func bools() {
    #expect(matchTyped(.bool(true), .equals, "t"))
    #expect(matchTyped(.bool(true), .equals, "1"))
    #expect(matchTyped(.bool(false), .equals, "F"))
    #expect(matchTyped(.bool(false), .equals, "0"))
    #expect(!matchTyped(.bool(false), .equals, "true"))
  }

  @Test("NaN falls back to string comparison; IN with only separators is incomplete")
  func edgeCases() {
    #expect(matchTyped(.string("nan"), .equals, "nan"))
    #expect(!matchTyped(.string("nan"), .lessThan, "nan"))
    #expect(match([cond("name", .in, " , ,")]).isEmpty)
    #expect(match([cond("name", .in, " , ,"), cond("name", .equals, "bob", .or)]) == [1: [0]])
  }
}
