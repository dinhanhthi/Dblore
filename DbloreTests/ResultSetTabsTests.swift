// ResultSetTabsTests.swift
// The tab labels of a multi-statement run and the split between tabs and the "More" menu.

import Foundation
import Testing

@testable import Dblore

@Suite("Result Set Tabs Tests")
@MainActor
struct ResultSetTabsTests {
  @Test("A tab names the rows, the verb and its count, the verb alone, an error or MongoDB's count")
  func labels() {
    let column = [ColumnInfo(name: "id", type: "integer")]
    let cases: [(query: String, result: CellResult, dialect: SQLDialect, expected: String)] = [
      ("SELECT id FROM t", CellResult(columns: column, rowCount: 120), .postgresql, "1 · 120 rows"),
      ("update t set a = 1", CellResult(affectedRows: 3), .postgresql, "1 · UPDATE 3"),
      ("-- note\ncreate table t (a int)", CellResult(), .postgresql, "1 · CREATE"),
      ("SELECT nope", CellResult(error: "relation does not exist"), .postgresql, "1 · Error"),
      (
        "db.t.updateMany({}, {$set: {a: 1}})", CellResult(affectedRows: 3), .mongodb,
        "1 · 3 affected"
      ),
    ]
    for item in cases {
      let statement = StatementResult(queryText: item.query, result: item.result, statementIndex: 0)
      #expect(
        ResultSetTabs.label(for: statement, at: 0, dialect: item.dialect) == item.expected,
        "\(item.query)")
    }
  }

  @Test("Six results stay tabs; from seven, five tabs and the rest in More")
  func overflowSplit() {
    #expect(ResultSetTabs.tabCount(for: 2) == 2)
    #expect(ResultSetTabs.tabCount(for: 6) == 6)
    #expect(ResultSetTabs.tabCount(for: 7) == 5)
  }
}
