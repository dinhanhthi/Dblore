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

  private func matchTyped(_ cell: CellValue, _ op: FilterOperator, _ value: String) -> Bool {
    TableHighlight(
      filter: TableFilter(conditions: [cond("c", op, value)]), style: .cell
    ).matches(rows: [[cell]], columns: ["c"], dialect: SQLDialect.postgresql).isEmpty == false
  }

}
