// CrossTableSearchModelTests.swift
// Find a Value in Every Table: a matching row shows the same text as the grid.

import Foundation
import Testing

@testable import Dblore

@Suite("Cross-table search model")
@MainActor
struct CrossTableSearchModelTests {
  @Test("A date shows the grid text of its column: naive the wall clock (regression A5)")
  func matchDatesShowTheGridText() {
    let noon = Date(timeIntervalSince1970: 1_792_065_600)  // 2026-10-15 12:00:00 UTC
    let statement = CrossTableSearchQueryBuilder.Statement(
      sql: "", parameters: [:], displayColumns: ["naive", "zoned"], searchedColumns: ["note"])
    let columns = [
      ColumnInfo(name: "naive", type: "timestamp", wallClock: true),
      ColumnInfo(name: "zoned", type: "timestamptz"),
      ColumnInfo(name: "match", type: "int4"),
    ]
    CellValue.$displayZone.withValue(TimeZone(identifier: "Asia/Ho_Chi_Minh")!) {
      let matches = CrossTableSearchModel.matches(
        [[.date(noon), .date(noon), .int(1)]], columns: columns, statement: statement)
      #expect(matches.map(\.values) == [["2026-10-15 12:00:00", "2026-10-15 19:00:00+07:00"]])
      #expect(matches.map(\.column) == ["note"])
    }
  }
}
