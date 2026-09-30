// DataViewerStagingTests.swift
// Data viewer staging toolbar: change summary, SQL preview, Commit with no shortcut,
// and the read-only / missing primary key gate.

import SwiftUI
import Testing

@testable import Dblore

@Suite("Data Viewer Staging Tests")
@MainActor
struct DataViewerStagingTests {
  @Test("Summary text includes insert, edit, and delete counts")
  func summaryIncludesCounts() {
    let text = DataViewerControls.stagedChangesSummary(
      RowChangeSet.Counts(inserts: 2, deletes: 8, edits: 4))
    #expect(text.contains("14 changes"))
    #expect(text.contains("2 inserts"))
    #expect(text.contains("4 edits"))
    #expect(text.contains("8 deletes"))
  }

  @Test("Preview sheet text equals previewStagedSQL")
  func previewSheetMatchesStagedSQL() {
    let viewModel = viewer(primaryKey: ["id"], protection: .none)
    #expect(viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)

    let sheet = StagedChangesPreviewSheet(viewModel: viewModel)
    #expect(sheet.sql == viewModel.previewStagedSQL())
    #expect(sheet.sql.contains("nickname"))
  }

  @Test("Commit has no key equivalent")
  func commitHasNoKeyEquivalent() {
    #expect(DataViewerControls.commitKeyEquivalent == nil)
  }

  @Test("Read-only or no primary key disables staging")
  func stagingDisabledWithoutKeyOrWhenReadOnly() {
    let noKey = viewer(primaryKey: [], protection: .none)
    #expect(noKey.stagingEnabled == false)
    #expect(noKey.rowStagingUnavailableReason == NotebookViewModel.tableHasNoPrimaryKey)

    let readOnly = viewer(primaryKey: ["id"], protection: .readOnly)
    #expect(readOnly.stagingEnabled == false)
    #expect(readOnly.rowStagingUnavailableReason == NotebookViewModel.connectionIsReadOnly)

    let ready = viewer(primaryKey: ["id"], protection: .none)
    #expect(ready.stagingEnabled)
    #expect(ready.rowStagingUnavailableReason == nil)
  }

  private func viewer(
    primaryKey: [String], protection: ConnectionProtectionLevel
  )
    -> NotebookViewModel
  {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.notebook.connectionConfig = ConnectionConfig(
      host: "localhost", port: 5432, database: "app", username: "ana", password: "x",
      protectionLevel: protection, safeMode: .silent, protectedMode: false)
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"])
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "int4"),
        ColumnInfo(name: "nickname", type: "text"),
      ],
      rows: [[.int(1), .string("old")]],
      rowCount: 1,
      editTarget: EditTarget(
        qualifiedName: "public.users", oid: 1, primaryKeyColumns: primaryKey,
        connectionEpoch: 0, updateOnly: true))
    return viewModel
  }
}
