// InlineEditSessionTargetTests.swift
// Inline edit targets are session-only and server-validated: a result decoded from a file (or
// built with a table name / primary key / column OIDs but no live target) is read-only, the
// UPDATE uses the server's schema-qualified name, and only a SELECT from exactly one relation
// can be edited.

import Foundation
import Testing

@testable import Dblore

// MARK: - Single-relation SELECT

@Suite("Inline Edit - single relation SELECT")
struct InlineEditSingleRelationTests {
  private func relation(_ sql: String) -> String? {
    CellUpdateStatement.singleRelation(in: sql)
  }

  @Test("Plain, aliased and filtered SELECTs from one relation are editable")
  func singleRelationAccepted() {
    #expect(relation("SELECT * FROM t") == "T")
    #expect(relation("SELECT * FROM t AS x") == "T")
    #expect(relation("select id, v from t x where id > 1 order by id limit 5 offset 2") == "T")
    #expect(relation("SELECT * FROM s6a.t FETCH FIRST 3 ROWS ONLY;") == "S6A.T")
    #expect(relation(#"SELECT * FROM "my.table""#) == #""my.table""#)
    #expect(relation(#"SELECT * FROM "We""ird" w"#) == #""We""ird""#)
    #expect(relation("SELECT extract(year FROM d) FROM t") == "T")
  }

  @Test("Comma self-join is not editable")
  func commaSelfJoinRejected() {
    #expect(relation("SELECT a.id, b.name FROM accounts a, accounts b") == nil)
    #expect(relation("SELECT * FROM accounts, accounts") == nil)
  }

  @Test("Subquery, CTE, set operation and JOIN are not editable")
  func complexRejected() {
    #expect(relation("SELECT * FROM t WHERE id IN (SELECT id FROM u)") == nil)
    #expect(relation("SELECT id FROM t UNION SELECT id FROM u") == nil)
    #expect(relation("WITH c AS (SELECT 1) SELECT * FROM t") == nil)
    #expect(relation("SELECT * FROM t JOIN u ON u.id = t.id") == nil)
    #expect(relation("SELECT * FROM (SELECT * FROM t) s") == nil)
    #expect(relation("SELECT * FROM generate_series(1, 3)") == nil)
    #expect(relation("SELECT * FROM t GROUP BY id") == nil)
    #expect(relation("SELECT * FROM t x(a, b)") == nil)
    #expect(relation("SELECT 1") == nil)
    #expect(relation("SELECT * FROM t; SELECT * FROM u") == nil)
    #expect(relation(#"SELECT * FROM t WHERE v = 'a\' , u'"#) == nil)
    #expect(relation("SELECT * FROM a.b.c") == nil)
  }
}

// MARK: - Server-qualified name

@Suite("Inline Edit - server-qualified table name")
struct InlineEditQualifiedNameTests {
  @Test("Only %I.%I output is accepted")
  func validatesServerFormat() {
    #expect(CellUpdateStatement.isServerQualifiedName("public.t"))
    #expect(CellUpdateStatement.isServerQualifiedName(#"public."my.table""#))
    #expect(CellUpdateStatement.isServerQualifiedName(#""My ""S"".x"."user""#))
    #expect(!CellUpdateStatement.isServerQualifiedName("t"))
    #expect(!CellUpdateStatement.isServerQualifiedName("a.b.c"))
    #expect(!CellUpdateStatement.isServerQualifiedName("Public.t"))
    #expect(!CellUpdateStatement.isServerQualifiedName("public.t; DROP TABLE x"))
    #expect(!CellUpdateStatement.isServerQualifiedName(#"public."t"#))
    #expect(!CellUpdateStatement.isServerQualifiedName(#"public."""#))
    #expect(!CellUpdateStatement.isServerQualifiedName(""))
  }

  @Test("The UPDATE uses the pre-quoted qualified name verbatim")
  func usesQualifiedNameVerbatim() throws {
    let statement = try CellUpdateStatement.make(
      qualifiedName: #"public."my.table""#, columnName: "v", newValue: "x",
      primaryKeyColumns: ["id"], rowData: ["id": .int(1)])
    #expect(statement.sql == #"UPDATE public."my.table" SET "v" = $1 WHERE "id" = $2"#)
  }

  @Test("A name that is not server output is refused")
  func refusesUserText() {
    #expect(throws: DatabaseError.self) {
      try CellUpdateStatement.make(
        qualifiedName: "t", columnName: "v", newValue: "x", primaryKeyColumns: ["id"],
        rowData: ["id": .int(1)])
    }
  }
}

// MARK: - Session-only target

@Suite("Inline Edit - session-only edit target")
@MainActor
struct InlineEditSessionOnlyTests {
  private let cellId = UUID()
  private let rowData: [String: CellValue] = ["id": .int(1), "name": .string("old")]

  /// A result as a crafted file would carry it: table, primary key and column OIDs.
  private func craftedResult() -> CellResult {
    CellResult(
      columns: [
        ColumnInfo(name: "id", type: "int4", tableOID: 16_400, attributeNumber: 1),
        ColumnInfo(name: "name", type: "text", tableOID: 16_400, attributeNumber: 2),
      ],
      rows: [[.int(1), .string("old")]], rowCount: 1, sourceQuery: "SELECT * FROM users",
      tableName: "victim", primaryKeyColumns: ["id"])
  }

  private func makeViewModel(result: CellResult) -> NotebookViewModel {
    let notebook = DbloreNotebook(
      id: UUID(),
      cells: [
        NotebookCell(
          id: cellId, cellType: .sql, content: "SELECT * FROM users", executionCount: 1,
          result: result)
      ],
      metadata: NotebookMetadata(createdAt: Date(), modifiedAt: Date(), title: "Session target"),
      connectionConfig: ConnectionConfig(protectionLevel: .none, safeMode: .alertRead),
      settings: NotebookSettings())
    return NotebookViewModel(notebook: notebook)
  }

  private func edit(_ viewModel: NotebookViewModel) {
    viewModel.handleCellValueEdit(
      columnName: "name", columnType: "text", newValue: "new", originalValue: .string("old"),
      tableName: "victim", rowData: rowData, primaryKeyColumns: ["id"], cellId: cellId,
      connectionManager: DatabaseConnectionManager())
  }

  @Test("Decoded document with tableName/primaryKeyColumns in the result -> canEdit false")
  func decodedResultNotEditable() throws {
    let data = try DocumentCoder.encode(
      makeViewModel(result: craftedResult()).notebook, includeResultsOnSave: true)
    var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var cells = try #require(json["cells"] as? [[String: Any]])
    var resultDict = try #require(cells[0]["result"] as? [String: Any])
    resultDict["tableName"] = "victim"
    resultDict["primaryKeyColumns"] = ["id"]
    cells[0]["result"] = resultDict
    json["cells"] = cells
    let decoded = try DocumentCoder.decode(from: JSONSerialization.data(withJSONObject: json))
    let result = try #require(decoded.cells.first?.result)
    #expect(result.editTarget == nil)
    let viewModel = NotebookViewModel(notebook: decoded)
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .none)
    #expect(viewModel.canEdit(result) == false)
  }

  @Test("Edit-target fields are not written to the document any more")
  func editTargetNotPersisted() throws {
    var result = craftedResult()
    result.editTarget = EditTarget(
      qualifiedName: "public.users", tableID: .postgresql(oid: 1), primaryKeyColumns: ["id"])
    let data = try DocumentCoder.encode(
      makeViewModel(result: result).notebook, includeResultsOnSave: true)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("primaryKeyColumns"))
    #expect(!text.contains("tableName"))
    #expect(!text.contains("public.users"))
  }

  @Test("Crafted result with tableName/PK/OIDs but no live target: edit refused before sending")
  func craftedResultRefused() {
    let viewModel = makeViewModel(result: craftedResult())
    #expect(viewModel.canEdit(craftedResult()) == false)
    WorkspaceWindowManager.shared.dismissToast()
    edit(viewModel)
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
  }

  @Test("A target from another (stale) result generation is refused before sending")
  func staleGenerationRefused() {
    let target = EditTarget(
      qualifiedName: "public.users", tableID: .postgresql(oid: 16_400), primaryKeyColumns: ["id"])
    var live = craftedResult()
    live.editTarget = target
    let viewModel = makeViewModel(result: live)
    // The sidebar was opened on an older run of the cell: same table, other generation
    let stale = EditTarget(
      qualifiedName: "public.users", tableID: .postgresql(oid: 16_400), primaryKeyColumns: ["id"])
    viewModel.showCellDetail(
      columnName: "name", columnType: "text", value: .string("old"), tableName: "users",
      rowData: rowData, primaryKeyColumns: ["id"], editTarget: stale, cellId: cellId)
    WorkspaceWindowManager.shared.dismissToast()
    edit(viewModel)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
  }

  @Test("Live target: the edit is accepted and sent without a confirmation")
  func liveTargetAccepted() {
    let target = EditTarget(
      qualifiedName: "s6a.users", tableID: .postgresql(oid: 16_400), primaryKeyColumns: ["id"])
    var live = craftedResult()
    live.editTarget = target
    let viewModel = makeViewModel(result: live)
    #expect(viewModel.canEdit(live))
    viewModel.showCellDetail(
      columnName: "name", columnType: "text", value: .string("old"), tableName: "users",
      rowData: rowData, primaryKeyColumns: ["id"], editTarget: target, cellId: cellId)
    WorkspaceWindowManager.shared.dismissToast()
    edit(viewModel)
    // Refusals toast synchronously; an accepted edit is sent in a Task
    #expect(WorkspaceWindowManager.shared.toastState.currentToast == nil)
    #expect(viewModel.queryConfirmationState.showDialog == false)
  }
}
