// DataModelDocumentTests.swift
// Unit tests for document round-trip serialization

import Foundation
import Testing

@testable import Dblore

@Suite("Data Model - Document Tests")
@MainActor
struct DataModelDocumentTests {
  // MARK: - Document Operations Tests (Round-trip Serialization)

  @Test("Document round-trip serialization with cells and results")
  func documentRoundTripWithResults() throws {
    // Arrange - Create notebook with cells containing results
    let result = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "integer"),
        ColumnInfo(name: "name", type: "text"),
        ColumnInfo(name: "created_at", type: "timestamp"),
      ],
      rows: [
        [.int(1), .string("Alice"), .date(Date())],
        [.int(2), .string("Bob"), .null],
        [.int(3), .json("{\"foo\":\"bar\"}"), .bool(true)],
      ],
      executionTime: 0.123,
      rowCount: 3,
      timestamp: Date(),
      sourceQuery: "SELECT * FROM users LIMIT 3",
      tableName: "users",
      primaryKeyColumns: ["id"]
    )

    let cells = [
      NotebookCell(
        id: UUID(),
        cellType: .sql,
        content: "SELECT * FROM users LIMIT 3",
        executionCount: 1,
        result: result
      ),
      NotebookCell(
        id: UUID(),
        cellType: .sql,
        content: "SELECT COUNT(*) FROM orders",
        executionCount: 2,
        result: nil
      ),
    ]

    let original = DbloreNotebook(
      id: UUID(),
      cells: cells,
      metadata: NotebookMetadata(
        createdAt: Date(),
        modifiedAt: Date(),
        title: "Test Notebook"
      ),
      connectionConfig: ConnectionConfig(
        host: "localhost",
        port: 5432,
        database: "testdb",
        username: "testuser"
      ),
      settings: NotebookSettings()
    )

    // Act - Encode to JSON
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    // Act - Decode from JSON
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(DbloreNotebook.self, from: data)

    // Assert
    #expect(decoded.cells.count == 2)
    #expect(decoded.cells[0].result != nil)
    #expect(decoded.cells[0].result?.columns.count == 3)
    #expect(decoded.cells[0].result?.rows.count == 3)
    #expect(decoded.cells[0].result?.tableName == "users")
    #expect(decoded.cells[0].result?.primaryKeyColumns == ["id"])
    #expect(decoded.cells[1].result == nil)
    #expect(decoded.connectionConfig?.host == "localhost")
  }

  @Test("Chart spec round-trips through the file coder, series and split columns included")
  func chartSpecRoundTripsThroughDocumentCoder() throws {
    let spec = ChartSpec(
      kind: .line, xColumn: "day", yColumns: ["total"], seriesColumn: "status",
      facetColumn: "region")
    let notebook = DbloreNotebook(
      id: UUID(),
      cells: [NotebookCell(content: "SELECT 1", chartSpec: spec)],
      metadata: NotebookMetadata(createdAt: Date(), modifiedAt: Date(), title: "Charts"),
      connectionConfig: nil,
      settings: NotebookSettings()
    )

    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: false)
    let decoded = try DocumentCoder.decode(from: data)

    #expect(decoded.cells.first?.chartSpec == spec)
  }

  // MARK: - Timestamps (microseconds and the wall-clock column flag)

  /// 2026-10-15 12:00:00 UTC
  private static let noonSeconds: Double = 1_792_065_600

  /// A notebook whose result and pin hold `dates` in a naive and a zoned column
  private func timestampNotebook(_ dates: [Date]) -> DbloreNotebook {
    let result = CellResult(
      columns: [
        ColumnInfo(name: "naive", type: "timestamp", wallClock: true),
        ColumnInfo(name: "zoned", type: "timestamptz"),
      ],
      rows: dates.map { [.date($0), .date($0)] },
      rowCount: dates.count)
    let pin = PinnedResult(
      result: result, pinnedAt: Date(timeIntervalSince1970: Self.noonSeconds), sourceQuery: nil)
    return DbloreNotebook(
      id: UUID(),
      cells: [NotebookCell(content: "SELECT 1", result: result, pinnedResult: pin)],
      metadata: NotebookMetadata(createdAt: Date(), modifiedAt: Date(), title: "Timestamps"),
      connectionConfig: nil,
      settings: NotebookSettings())
  }

  /// The `rows` of the cell's saved result
  private func savedRows(_ data: Data) throws -> [[[String: Any]]] {
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cells = try #require(json["cells"] as? [[String: Any]])
    let result = try #require(cells.first?["result"] as? [String: Any])
    return try #require(result["rows"] as? [[[String: Any]]])
  }

  @Test("A date keeps its microseconds through value + micros; whole seconds write no micros")
  func dateMicrosRoundTrip() throws {
    let dates = [
      Date(timeIntervalSince1970: Self.noonSeconds + 0.123456),
      Date(timeIntervalSince1970: Self.noonSeconds),
      Date(timeIntervalSince1970: -0.5),
    ]
    let data = try DocumentCoder.encode(timestampNotebook(dates), includeResultsOnSave: true)
    let rows = try savedRows(data)
    #expect(
      rows.map { $0[0]["value"] as? String } == [
        "2026-10-15T12:00:00Z", "2026-10-15T12:00:00Z", "1969-12-31T23:59:59Z",
      ])
    #expect(rows.map { $0[0]["micros"] as? Int } == [123_456, nil, 500_000])

    let decoded = try DocumentCoder.decode(from: data)
    let cell = try #require(decoded.cells.first)
    for result in [cell.result, cell.pinnedResult?.result] {
      let rows = try #require(result?.rows)
      #expect(
        rows.map { $0[0].outputString(wallClock: true) } == [
          "2026-10-15 12:00:00.123456", "2026-10-15 12:00:00", "1969-12-31 23:59:59.5",
        ])
    }
  }

  @Test("A plain ISO 8601 reader (older builds) still decodes every saved date cell")
  func olderReaderKeepsEveryDateCell() throws {
    let dates = [
      Date(timeIntervalSince1970: Self.noonSeconds + 0.123456),
      Date(timeIntervalSince1970: -0.5),
    ]
    let data = try DocumentCoder.encode(timestampNotebook(dates), includeResultsOnSave: true)
    let plain = ISO8601DateFormatter()
    for row in try savedRows(data) {
      let parsed = row.compactMap { ($0["value"] as? String).flatMap(plain.date(from:)) }
      #expect(parsed.count == row.count)
    }
  }

  @Test("A date without micros reads whole seconds; a value with a fraction reads too")
  func dateWithoutMicrosDecodes() throws {
    let json: [String: Any] = [
      "cells": [
        [
          "content": "SELECT 1",
          "result": [
            "columns": [["name": "at", "type": "timestamptz"]],
            "rows": [
              [["type": "date", "value": "2026-10-15T12:00:00Z"]],
              [["type": "date", "value": "2026-10-15T12:00:00.123456Z"]],
              [["type": "date", "value": "2026-10-15T12:00:00Z", "micros": 1_000_000]],
              // Beyond the microsecond range: whole seconds, no trap
              [["type": "date", "value": "300000-01-01T00:00:00Z", "micros": 5]],
            ],
          ],
        ]
      ]
    ]
    let notebook = try DocumentCoder.decode(
      from: try JSONSerialization.data(withJSONObject: json))
    let rows = try #require(notebook.cells.first?.result?.rows)
    #expect(
      rows.prefix(3).map { $0.map { $0.outputString(wallClock: false) } } == [
        ["2026-10-15T12:00:00Z"], ["2026-10-15T12:00:00.123456Z"], ["2026-10-15T12:00:00Z"],
      ])
    #expect(rows.last == [.date(Date(timeIntervalSince1970: 9_404_918_380_800))])
  }

  @Test("The wall-clock column key round-trips in results and pins; absent reads zoned")
  func wallClockColumnKeyRoundTrip() throws {
    let data = try DocumentCoder.encode(
      timestampNotebook([Date(timeIntervalSince1970: Self.noonSeconds)]),
      includeResultsOnSave: true)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cells = try #require(json["cells"] as? [[String: Any]])
    let columns = try #require(
      (cells.first?["result"] as? [String: Any])?["columns"] as? [[String: Any]])
    #expect(columns.map { $0["wallClock"] as? Bool } == [true, nil])

    let cell = try #require(try DocumentCoder.decode(from: data).cells.first)
    #expect(cell.result?.columns.map(\.wallClock) == [true, false])
    #expect(cell.pinnedResult?.result.columns.map(\.wallClock) == [true, false])
  }

  @Test("Malformed statement result entries decode to an empty result")
  func malformedStatementResultDecodesEmpty() throws {
    let json: [String: Any] = [
      "cells": [
        [
          "content": "SELECT 1; SELECT 2",
          "statementResults": [
            ["queryText": "SELECT 1", "statementIndex": 0, "result": "not a dictionary"],
            ["queryText": "SELECT 2", "statementIndex": 1],
          ],
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)

    let notebook = try DocumentCoder.decode(from: data)

    let statements = notebook.cells[0].statementResults
    #expect(statements.map(\.queryText) == ["SELECT 1", "SELECT 2"])
    #expect(statements.allSatisfy { $0.result.rows.isEmpty && $0.result.columns.isEmpty })
  }

  // MARK: - File Conflict (an open file changed on disk)

  /// A temp file opened in a fresh workspace, dated a minute ago so a write now is newer
  @MainActor
  private struct OpenFile {
    let manager: WorkspaceManager
    let tabId: UUID
    let url: URL
    let suiteName: String

    static func open(_ name: String, data: Data) async throws -> OpenFile {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("conflict-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let url = folder.appendingPathComponent(name)
      try data.write(to: url)
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: url.path)
      let suiteName = "DataModelDocumentTests.\(UUID().uuidString)"
      let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
      manager.recents = RecentManager(defaults: try #require(UserDefaults(suiteName: suiteName)))
      var hooks = SecurityScopedAccessHooks()
      hooks.resolve = { _ in throw CocoaError(.fileNoSuchFile) }
      hooks.makeBookmark = { _ in nil }
      manager.accessHooks = hooks
      try await manager.openFile(url: url)
      let tabId = try #require(manager.tabs.first { $0.fileURL == url }).id
      // The document presents its file once the queued registration ran
      #expect(SQLiteFileAccess.onPresenterQueue {})
      return OpenFile(manager: manager, tabId: tabId, url: url, suiteName: suiteName)
    }

    var isDirty: Bool { manager.tabs.first { $0.id == tabId }?.isDirty == true }

    /// Closes the tab (unregistering its presenter) and removes the temp files
    func close() {
      manager.closeTabImmediately(id: tabId)
      try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
      UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
  }

  /// Another writer replacing the file's text through file coordination, as other apps do
  private func coordinatedWrite(_ text: String, to url: URL) async throws {
    try await Task.detached {
      var coordinationError: NSError?
      var writeError: (any Error)?
      NSFileCoordinator(filePresenter: nil).coordinate(
        writingItemAt: url, options: [], error: &coordinationError
      ) { url in
        do { try Data(text.utf8).write(to: url) } catch { writeError = error }
      }
      if let error = coordinationError ?? writeError { throw error }
    }.value
  }

  /// Waits up to 5 s for `condition` (a presenter's change is debounced 500 ms)
  private func wait(until condition: () -> Bool) async {
    for _ in 0..<50 where !condition() {
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  @Test("An external write to a file with unsaved edits sets its document's conflict state")
  func externalWriteWhileDirtySetsConflictState() async throws {
    let file = try await OpenFile.open("query.sql", data: Data("select 1".utf8))
    defer { file.close() }
    let document = try #require(file.manager.editorDocument(for: file.tabId))
    let viewModel = try #require(file.manager.viewModel(for: file.tabId))
    viewModel.editorContent = "select 2"
    file.manager.markDirty(tabId: file.tabId)

    try await coordinatedWrite("select 3", to: file.url)
    await wait { document.fileConflictState.showDialog }

    #expect(document.fileConflictState.showDialog)
    #expect(document.fileConflictState.conflictType == .modified)
    #expect(viewModel.editorContent == "select 2")
    #expect(file.isDirty)
  }

  @Test("Load External puts the file's text into the tab and leaves it clean")
  func loadExternalRefreshesTab() async throws {
    let script = try await OpenFile.open("query.sql", data: Data("select 1".utf8))
    defer { script.close() }
    let scriptModel = try #require(script.manager.viewModel(for: script.tabId))
    scriptModel.editorContent = "select 2"
    script.manager.markDirty(tabId: script.tabId)
    try Data("select 3".utf8).write(to: script.url)

    try await script.manager.loadExternalVersion(tabId: script.tabId)

    #expect(scriptModel.editorContent == "select 3")
    #expect(!script.isDirty)

    func encoded(_ sql: String) throws -> Data {
      let cells = [NotebookCell(cellType: .sql, content: sql)]
      return try DocumentCoder.encode(
        DbloreNotebook(cells: cells, documentType: .notebook), includeResultsOnSave: false)
    }
    let notebook = try await OpenFile.open("notes.dblore", data: encoded("select 1"))
    defer { notebook.close() }
    let notebookModel = try #require(notebook.manager.viewModel(for: notebook.tabId))
    notebook.manager.markDirty(tabId: notebook.tabId)
    try encoded("select 4").write(to: notebook.url)

    try await notebook.manager.loadExternalVersion(tabId: notebook.tabId)

    #expect(notebookModel.notebook.cells.map(\.content) == ["select 4"])
    #expect(!notebook.isDirty)
  }

  @Test("Keep My Version keeps the tab's edits and asks again only about a newer change")
  func keepMyVersionKeepsEdits() async throws {
    let file = try await OpenFile.open("query.sql", data: Data("select 1".utf8))
    defer { file.close() }
    let document = try #require(file.manager.editorDocument(for: file.tabId))
    let viewModel = try #require(file.manager.viewModel(for: file.tabId))
    viewModel.editorContent = "select 2"
    file.manager.markDirty(tabId: file.tabId)
    try Data("select 3".utf8).write(to: file.url)
    document.presentedItemDidChange()
    await wait { document.fileConflictState.showDialog }
    #expect(document.fileConflictState.showDialog)

    // The alert's binding dismisses it, then Keep My Version runs
    document.fileConflictState.dismiss()
    file.manager.keepMyVersion(tabId: file.tabId)

    #expect(viewModel.editorContent == "select 2")
    #expect(file.isDirty)
    // The same change reported again does not ask again (no signal ends the debounce: wait 4x)
    document.presentedItemDidChange()
    try await Task.sleep(for: .seconds(2))
    #expect(!document.fileConflictState.showDialog)
    // A newer change, reported the same way, does ask
    try writeNewerChange("select 4", to: file.url)
    document.presentedItemDidChange()
    await wait { document.fileConflictState.showDialog }
    #expect(document.fileConflictState.showDialog)
  }

  @Test("Keep My Version still asks about a change made while the alert was up")
  func keepMyVersionAsksAboutChangeDuringAlert() async throws {
    let file = try await OpenFile.open("query.sql", data: Data("select 1".utf8))
    defer { file.close() }
    let document = try #require(file.manager.editorDocument(for: file.tabId))
    file.manager.markDirty(tabId: file.tabId)
    try Data("select 3".utf8).write(to: file.url)
    document.presentedItemDidChange()
    await wait { document.fileConflictState.showDialog }
    #expect(document.fileConflictState.showDialog)

    // Another change lands before the user clicks
    try writeNewerChange("select 4", to: file.url)
    document.fileConflictState.dismiss()
    file.manager.keepMyVersion(tabId: file.tabId)

    document.presentedItemDidChange()
    await wait { document.fileConflictState.showDialog }
    #expect(document.fileConflictState.showDialog)
  }

  @Test("A markdown note does not ask about its file, and Load External leaves it alone")
  func markdownNoteHasNoFileConflictFlow() async throws {
    let note = try await OpenFile.open("note.md", data: Data("# One".utf8))
    defer { note.close() }
    let viewModel = try #require(note.manager.viewModel(for: note.tabId))
    viewModel.editorContent = "# Two"
    note.manager.markDirty(tabId: note.tabId)
    try Data("# Three".utf8).write(to: note.url)

    try await note.manager.loadExternalVersion(tabId: note.tabId)

    #expect(!note.manager.watchesFileConflicts(tabId: note.tabId))
    #expect(note.manager.editorDocument(for: note.tabId)?.content == "# One")
    #expect(viewModel.editorContent == "# Two")
    #expect(note.isDirty)
    let script = try await OpenFile.open("query.sql", data: Data("select 1".utf8))
    defer { script.close() }
    #expect(script.manager.watchesFileConflicts(tabId: script.tabId))
  }

  @Test("The app's own save of a file is not reported as an external change")
  func ownSaveIsNotAConflict() async throws {
    let file = try await OpenFile.open("query.sql", data: Data("select 1".utf8))
    defer { file.close() }
    let document = try #require(file.manager.editorDocument(for: file.tabId))
    let viewModel = try #require(file.manager.viewModel(for: file.tabId))
    viewModel.editorContent = "select 2"
    file.manager.markDirty(tabId: file.tabId)

    try await file.manager.saveTab(id: file.tabId)
    document.presentedItemDidChange()
    try await Task.sleep(for: .seconds(2))

    #expect(!file.isDirty)
    #expect(!document.fileConflictState.showDialog)
    // A newer external change after the save does ask
    try writeNewerChange("select 3", to: file.url)
    document.presentedItemDidChange()
    await wait { document.fileConflictState.showDialog }
    #expect(document.fileConflictState.showDialog)
  }

  @Test("A save over a change on disk the tab has not shown writes nothing and asks instead")
  func saveOverUnseenExternalChangeAsks() async throws {
    let file = try await OpenFile.open("query.sql", data: Data("select 1".utf8))
    defer { file.close() }
    let document = try #require(file.manager.editorDocument(for: file.tabId))
    let viewModel = try #require(file.manager.viewModel(for: file.tabId))
    viewModel.editorContent = "select 2"
    file.manager.markDirty(tabId: file.tabId)
    // Lands just before the save, inside the presenter's debounce: not reported yet
    try writeNewerChange("select 3", to: file.url)

    await #expect(throws: FileConflictError.self) {
      try await file.manager.saveTab(id: file.tabId)
    }

    #expect(try String(contentsOf: file.url, encoding: .utf8) == "select 3")
    #expect(document.fileConflictState.showDialog)
    #expect(document.fileConflictState.conflictType == .modified)
    #expect(file.isDirty)
    // While the alert asks, another save writes nothing either
    await #expect(throws: FileConflictError.self) {
      try await file.manager.saveTab(id: file.tabId)
    }
    #expect(try String(contentsOf: file.url, encoding: .utf8) == "select 3")
    // Keep My Version, then Save writes the tab's text
    document.fileConflictState.dismiss()
    file.manager.keepMyVersion(tabId: file.tabId)
    try await file.manager.saveTab(id: file.tabId)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == "select 2")
    #expect(!file.isDirty)
  }

  /// Another writer's change, dated a minute ahead so it is newer than any date seen so far
  private func writeNewerChange(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
  }

  // MARK: Close Document after the file was deleted

  /// A dirty notebook tab in a workspace whose pending transaction (if any) the tab opened
  private func deletedFileTab(pendingTransaction: Bool) -> (WorkspaceManager, UUID) {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    // Never show an NSAlert from tests
    manager.pendingTransactionPrompt = { _, _, _ in .cancel }
    let tabId = manager.newNotebook()
    manager.markDirty(tabId: tabId)
    if pendingTransaction {
      let pending = SQLStatementClassifier.classify("UPDATE t SET v = 1 WHERE id = 1").map {
        StatementSummary(statement: $0, affectedRows: 1)
      }
      manager.pendingTransaction = .appTx(pending: pending)
      manager.transactionOriginTabId = tabId
    }
    return (manager, tabId)
  }

  @Test("Close Document of a deleted file waits for the tab's pending transaction")
  func deletedFileCloseResolvesTransactionFirst() async {
    let (manager, tabId) = deletedFileTab(pendingTransaction: true)

    manager.closeTabForDeletedFile(id: tabId)

    // Deferred to the Commit / Roll back / Cancel question, not closed at once
    #expect(manager.tabs.contains { $0.id == tabId })
    // Without a database the actor reports no transaction: the resolve passes, the tab closes
    await wait { !manager.tabs.contains { $0.id == tabId } }
    #expect(!manager.tabs.contains { $0.id == tabId })
    // The edits were already dropped: no save question
    #expect(!manager.showingCloseConfirmation)
    #expect(manager.tabToClose == nil)
  }

  @Test("Cancel at the transaction question keeps the deleted file's tab and its edits")
  func deletedFileCloseCancelKeepsEdits() async {
    let (manager, tabId) = deletedFileTab(pendingTransaction: true)

    manager.closeTabForDeletedFile(id: tabId)
    // The deferred resolve finds another prompt open and returns false, as Cancel does
    manager.isResolvingPendingTransaction = true
    try? await Task.sleep(for: .milliseconds(300))
    manager.isResolvingPendingTransaction = false

    #expect(manager.tabs.contains { $0.id == tabId })
    #expect(manager.tabs.first { $0.id == tabId }?.isDirty == true)
    // A later normal close (transaction resolved meanwhile) asks the save question
    manager.pendingTransaction = .idle
    manager.requestCloseTab(id: tabId)
    #expect(manager.showingCloseConfirmation)
    #expect(manager.tabToClose == tabId)
    manager.cancelClose()
  }

  @Test("Close Document of a deleted file without a pending transaction closes at once")
  func deletedFileCloseWithoutTransactionClosesAtOnce() {
    let (manager, tabId) = deletedFileTab(pendingTransaction: false)

    manager.closeTabForDeletedFile(id: tabId)

    #expect(!manager.tabs.contains { $0.id == tabId })
    #expect(!manager.showingCloseConfirmation)
    #expect(manager.tabToClose == nil)
  }
}

// MARK: - Saved-file compatibility (pre-Phase-4 <-> current)

/// A `.dblore` written by the pre-Phase-4 `DocumentCoder`: LIMIT-rewrite metadata, ctid row
/// identifiers, edit-target fields and pagination state. Shape reproduced literally.
private let legacyFixture = """
  {"cells":[{"cellType":"sql","content":"SELECT * FROM users","executionCount":3,
  "id":"6F1C2E5A-0000-4000-8000-000000000001","isResultVisible":true,"isRunning":false,
  "paginationInfo":{"baseQuery":"SELECT * FROM users","currentPage":2,"rowsPerPage":2,"totalRows":9},
  "result":{"columns":[{"name":"id","type":"int4"},{"name":"name","type":"text"}],
  "executionTime":0.25,"primaryKeyColumns":["id"],"rowCount":2,
  "rowIdentifiers":[{"type":"string","value":"(0,1)"},{"type":"string","value":"(0,2)"}],
  "rows":[[{"type":"int","value":1},{"type":"string","value":"Alice"}],
  [{"type":"int","value":2},{"type":"null"}]],
  "sourceQuery":"SELECT * FROM users","tableName":"users","timestamp":"2026-01-02T03:04:05Z",
  "userLimitExceeded":true,"userRequestedLimit":500,"wasLimited":true},
  "selectedStatementIndex":0,"statementPaginationInfo":{"6F1C2E5A-0000-4000-8000-000000000002":
  {"baseQuery":"SELECT 1","currentPage":1,"rowsPerPage":1,"totalRows":1}},
  "statementResults":[{"id":"6F1C2E5A-0000-4000-8000-000000000002","queryText":"SELECT 1",
  "result":{"columns":[{"name":"?column?","type":"int4"}],"executionTime":0.01,
  "primaryKeyColumns":["id"],"rowCount":1,"rows":[[{"type":"int","value":1}]],
  "tableName":"users","timestamp":"2026-01-02T03:04:05Z","wasLimited":false},
  "statementIndex":0}]}],
  "documentType":"notebook","id":"6F1C2E5A-0000-4000-8000-0000000000AA",
  "metadata":{"createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-02T00:00:00Z",
  "title":"Legacy"},"settings":{"keyboardShortcuts":{}},"version":"1.0"}
  """

/// Mirror of the pre-Phase-4 `DocumentCoder.decode` result/cell reading (b8be7db and 74e4dc6
/// are identical there): every key is read leniently (`as? T ?? default`); nothing is required
/// beyond a top-level object. Returns what the old build would have used.
private struct LegacyFileView {
  struct Result {
    let columnNames: [String]
    let rowCount: Int
    let rowsDecoded: Int
    let wasLimited: Bool
    let tableName: String?
    let primaryKeyColumns: [String]
    let rowIdentifiers: Int
    let userLimitExceeded: Bool
    let userRequestedLimit: Int?
    /// Old build: inline edit is offered when the result carries a table name
    var isEditableInOldBuild: Bool {
      tableName != nil
    }
  }

  struct Cell {
    let result: Result?
    let statementResults: [Result]
    let hasPaginationInfo: Bool
    let statementPaginationCount: Int
  }

  let cells: [Cell]

  init(data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data)
    let json = try #require(object as? [String: Any])
    let cellsArray = json["cells"] as? [[String: Any]] ?? []
    cells = cellsArray.map { cellDict in
      let statements = (cellDict["statementResults"] as? [[String: Any]] ?? []).compactMap {
        ($0["result"] as? [String: Any]).map(Self.result(from:))
      }
      return Cell(
        result: (cellDict["result"] as? [String: Any]).map(Self.result(from:)),
        statementResults: statements,
        hasPaginationInfo: cellDict["paginationInfo"] as? [String: Any] != nil,
        statementPaginationCount: (cellDict["statementPaginationInfo"] as? [String: [String: Any]])?
          .count ?? 0
      )
    }
  }

  private static func result(from dict: [String: Any]) -> Result {
    let columns = dict["columns"] as? [[String: Any]] ?? []
    let rows = dict["rows"] as? [[[String: Any]]] ?? []
    return Result(
      columnNames: columns.map { $0["name"] as? String ?? "" },
      rowCount: dict["rowCount"] as? Int ?? 0,
      rowsDecoded: rows.count,
      wasLimited: dict["wasLimited"] as? Bool ?? false,
      tableName: dict["tableName"] as? String,
      primaryKeyColumns: dict["primaryKeyColumns"] as? [String] ?? [],
      rowIdentifiers: (dict["rowIdentifiers"] as? [[String: Any]])?.count ?? 0,
      userLimitExceeded: dict["userLimitExceeded"] as? Bool ?? false,
      userRequestedLimit: dict["userRequestedLimit"] as? Int
    )
  }
}

@Suite("Data Model - Saved-file compatibility")
@MainActor
struct DocumentLegacyCompatibilityTests {
  private func legacyData() throws -> Data {
    try #require(legacyFixture.data(using: .utf8))
  }

  private func currentNotebook() -> DbloreNotebook {
    var result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4", tableOID: 16400, attributeNumber: 1)],
      rows: [[.int(1)], [.int(2)]], executionTime: 0.5, rowCount: 2,
      timestamp: Date(timeIntervalSince1970: 1_800_000_000), wasLimited: true,
      sourceQuery: "SELECT id FROM users", tableName: "public.users", primaryKeyColumns: ["id"]
    )
    result.editTarget = EditTarget(
      qualifiedName: "public.users", tableID: .postgresql(oid: 16400), primaryKeyColumns: ["id"])
    let statement = StatementResult(
      queryText: "SELECT id FROM users", result: result, statementIndex: 0
    )
    let cell = NotebookCell(
      content: "SELECT id FROM users", executionCount: 1, result: result,
      statementResults: [statement]
    )
    return DbloreNotebook(
      id: UUID(), cells: [cell],
      metadata: NotebookMetadata(createdAt: Date(), modifiedAt: Date(), title: "Current"),
      connectionConfig: nil, settings: NotebookSettings()
    )
  }

  private func assertOldBuildReads(_ data: Data) throws {
    let view = try LegacyFileView(data: data)
    let cell = try #require(view.cells.first)
    let result = try #require(cell.result)
    #expect(result.columnNames == ["id"])
    #expect(result.rowCount == 2)
    #expect(result.rowsDecoded == 2)
    #expect(result.wasLimited)
    #expect(result.isEditableInOldBuild == false)
    #expect(result.primaryKeyColumns.isEmpty)
    #expect(result.rowIdentifiers == 0)
    #expect(result.userLimitExceeded == false)
    #expect(result.userRequestedLimit == nil)
    #expect(cell.hasPaginationInfo == false)
    #expect(cell.statementPaginationCount == 0)
    #expect(cell.statementResults.count == 1)
    #expect(cell.statementResults.first?.isEditableInOldBuild == false)
    // Keys the old build always wrote stay present
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cells = try #require(json["cells"] as? [[String: Any]])
    let dict = try #require(cells.first?["result"] as? [String: Any])
    for key in ["columns", "rows", "executionTime", "rowCount", "timestamp", "wasLimited"] {
      #expect(dict[key] != nil, "missing \(key)")
    }
  }

  @Test("Legacy file decodes: results intact, no edit target")
  func legacyFixtureDecodes() throws {
    let notebook = try DocumentCoder.decode(from: legacyData())
    let cell = try #require(notebook.cells.first)
    let result = try #require(cell.result)
    #expect(cell.content == "SELECT * FROM users")
    #expect(cell.executionCount == 3)
    #expect(result.columns.map(\.name) == ["id", "name"])
    #expect(result.rows == [[.int(1), .string("Alice")], [.int(2), .null]])
    #expect(result.rowCount == 2)
    #expect(result.wasLimited)
    #expect(result.sourceQuery == "SELECT * FROM users")
    #expect(result.editTarget == nil)
    #expect(cell.statementResults.count == 1)
    #expect(cell.statementResults.first?.result.editTarget == nil)
  }

  @Test("Legacy file: stale LIMIT/ctid/edit-target/pagination state is not carried after load")
  func legacyStateDroppedOnLoad() throws {
    let notebook = try DocumentCoder.decode(from: legacyData())
    let result = try #require(notebook.cells.first?.result)
    #expect(result.tableName == nil)
    #expect(result.primaryKeyColumns.isEmpty)
    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: true)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("paginationInfo"))
    #expect(!text.contains("PaginationInfo"))
    #expect(!text.contains("rowIdentifiers"))
    #expect(!text.contains("tableName"))
  }

  @Test("File saved by the current build opens in the pre-Phase-4 build")
  func currentFileReadByOldDecoder() throws {
    try assertOldBuildReads(
      DocumentCoder.encode(currentNotebook(), includeResultsOnSave: true)
    )
  }

  @Test("FileOptimizationService encodes with the same rules as the main coder")
  func fileOptimizationMatchesMainCoder() throws {
    let notebook = currentNotebook()
    let data = try FileOptimizationService.DocumentCoder.encode(
      notebook, includeResultsOnSave: true
    )
    try assertOldBuildReads(data)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("primaryKeyColumns"))
    #expect(!text.contains("tableName"))
    #expect(try data == (DocumentCoder.encode(notebook, includeResultsOnSave: true)))
  }
}
