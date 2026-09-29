// DataViewerStateTests.swift
// The data viewer tab pages a table or view with server-side LIMIT/OFFSET: the generated SQL
// must stay a single-relation SELECT (so inline edit keeps working) and quote every identifier.

import Foundation
import Testing

@testable import SQLNotebook

@MainActor
@Suite("Data Viewer State Tests")
struct DataViewerStateTests {
  private func state(
    schema: String = "public", name: String = "users", orderColumns: [String] = []
  ) -> DataViewerState {
    DataViewerState(schema: schema, name: name, orderColumns: orderColumns)
  }

  private func result(_ rows: [[CellValue]]) -> QueryResult {
    QueryResult(
      columns: [ColumnInfo(name: "count", type: "int8")], rows: rows, rowCount: rows.count,
      executionTime: 0)
  }

  @Test("Page 1 without order columns is the plain LIMIT query")
  func firstPageSQL() {
    #expect(state().pageSQL == #"SELECT * FROM "public"."users" LIMIT 100"#)
  }

  @Test("Order columns add a quoted ORDER BY")
  func orderBySQL() {
    #expect(
      state(orderColumns: ["id"]).pageSQL
        == #"SELECT * FROM "public"."users" ORDER BY "id" LIMIT 100"#)
  }

  @Test("Page 3 at page size 50 offsets by 100")
  func offsetSQL() {
    var viewer = state()
    viewer.page = 3
    viewer.pageSize = 50
    #expect(viewer.pageSQL.hasSuffix("LIMIT 50 OFFSET 100"))
  }

  @Test("Embedded double quotes are doubled")
  func quotedIdentifiers() {
    let viewer = state(schema: #"my"s"#, name: #"we"ird"#)
    #expect(viewer.pageSQL.hasPrefix(#"SELECT * FROM "my""s"."we""ird" "#))
    #expect(viewer.countSQL == #"SELECT count(*) FROM "my""s"."we""ird""#)
  }

  @Test("Empty schema gives an unqualified relation")
  func emptySchema() {
    #expect(state(schema: "").pageSQL == #"SELECT * FROM "users" LIMIT 100"#)
  }

  @Test("Page SQL stays a single-relation SELECT (editable)")
  func singleRelation() {
    var ordered = state(orderColumns: ["id", "name"])
    ordered.page = 2
    #expect(CellUpdateStatement.singleRelation(in: state().pageSQL) != nil)
    #expect(CellUpdateStatement.singleRelation(in: ordered.pageSQL) != nil)
  }

  @Test("pageCount rounds up and is at least 1", arguments: [(0, 1), (100, 1), (101, 2)])
  func pageCount(total: Int, expected: Int) {
    var viewer = state()
    viewer.totalRows = total
    #expect(viewer.pageCount == expected)
  }

  @Test("Unknown total: no page count, Next allowed")
  func unknownTotal() {
    #expect(state().pageCount == nil)
    #expect(state().canGoNext)
    #expect(!state().canGoPrevious)
  }

  @Test("canGoNext is false on the last page")
  func lastPage() {
    var viewer = state()
    viewer.totalRows = 250
    viewer.page = 3
    #expect(!viewer.canGoNext)
    #expect(viewer.canGoPrevious)
    viewer.page = 2
    #expect(viewer.canGoNext)
  }

  @Test("rowRange covers the loaded rows of the page")
  func rowRange() {
    var viewer = state()
    viewer.page = 2
    #expect(viewer.rowRange(loadedRows: 40) == 101...140)
    #expect(viewer.rowRange(loadedRows: 0) == nil)
  }

  @Test("total(from:) reads an int or numeric string first cell")
  func total() {
    #expect(DataViewerState.total(from: result([[.int(42)]])) == 42)
    #expect(DataViewerState.total(from: result([[.string("42")]])) == 42)
    #expect(DataViewerState.total(from: result([])) == nil)
    #expect(DataViewerState.total(from: result([[.string("abc")]])) == nil)
  }

  @Test("Title omits the public schema")
  func title() {
    #expect(state().title == "users")
    #expect(state(schema: "").title == "users")
    #expect(state(schema: "sales").title == "sales.users")
  }

  @Test("loadKey changes with page but not with hidden columns")
  func loadKey() {
    var viewer = state()
    let key = viewer.loadKey
    viewer.hiddenColumns = ["email"]
    #expect(viewer.loadKey == key)
    viewer.page = 2
    #expect(viewer.loadKey != key)
  }

  private func filtered(_ dialect: DatabaseType = .postgresql) -> DataViewerState {
    var viewer = state(orderColumns: ["id"])
    viewer.databaseType = dialect
    viewer.filter = TableFilter(conditions: [
      FilterCondition(column: "name", op: .equals, value: "o'brien")
    ])
    return viewer
  }

  @Test("Filter adds WHERE after the relation and before ORDER BY/LIMIT")
  func filterSQL() {
    var viewer = filtered()
    viewer.page = 2
    #expect(
      viewer.pageSQL
        == #"SELECT * FROM "public"."users" WHERE "name" = 'o''brien' ORDER BY "id" LIMIT 100 OFFSET 100"#
    )
    #expect(
      viewer.countSQL == #"SELECT count(*) FROM "public"."users" WHERE "name" = 'o''brien'"#)
    #expect(CellUpdateStatement.singleRelation(in: viewer.pageSQL) != nil)
  }

  @Test("A filter without a complete condition leaves the SQL unchanged")
  func incompleteFilterSQL() {
    var viewer = state()
    viewer.filter = TableFilter(conditions: [FilterCondition(column: "name", value: "")])
    #expect(viewer.pageSQL == state().pageSQL)
    #expect(viewer.countSQL == state().countSQL)
  }

  @Test("The dialect drives the filter literals")
  func filterDialect() {
    var viewer = filtered(.sqlite)
    viewer.filter.conditions[0].op = .ilike
    #expect(viewer.countSQL.hasSuffix(#"WHERE "name" LIKE 'o''brien'"#))
    viewer.databaseType = .postgresql
    #expect(viewer.countSQL.hasSuffix(#"WHERE "name"::text ILIKE 'o''brien'"#))
  }

  @Test("loadKey changes with the applied filter")
  func loadKeyFilter() {
    let viewer = state()
    #expect(filtered().loadKey != viewer.loadKey)
  }
}
