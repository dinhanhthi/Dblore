import Foundation
import Testing

@testable import Dblore

@Suite("Table import model")
@MainActor
struct TableImportModelTests {
  @Test("Injected picker loads a 100-row preview and infers column types")
  func preview() async throws {
    let url = temporaryFile(
      "name,active\n" + (0..<105).map { "person\($0),true" }.joined(separator: "\n"),
      extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel(chooseFile: { url })
    await model.pickFile()
    #expect(model.fileURL == url)
    #expect(model.previewRows.count == 100)
    #expect(model.mappings.map(\.sourceName) == ["name", "active"])
    #expect(model.mappings.map(\.kind) == [.text, .boolean])
    #expect(model.progress == 1)
    #expect(model.errorMessage == nil)
  }

  @Test("New-table mapping skips, renames, and binds typed SQLite booleans")
  func mappedNewTable() async throws {
    let url = temporaryFile("name,skip,active\nAda,x,true\nBob,y,false\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .new(schema: nil, table: "people")
    model.mappings[0].targetName = "full name"
    model.mappings[1].included = false
    let batch = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 7)

    #expect(batch.connectionEpoch == 7)
    #expect(batch.historySource == .dataImport)
    #expect(batch.statements.count == 2)
    #expect(
      batch.statements[0].sql == #"CREATE TABLE "people" ("full name" TEXT, "active" INTEGER)"#)
    #expect(batch.statements[1].values == ["Ada", "1", "Bob", "0"])
    #expect(batch.statements[1].sql.contains("CAST(?2 AS INTEGER)"))
    #expect(batch.rowRanges == [nil, 1...2])
    #expect(batch.preview.contains("-- 2 rows from file"))
    #expect(!batch.preview.contains("Ada"))
  }

  @Test("Existing table import has only INSERT statements")
  func existingTable() async throws {
    let url = temporaryFile("{\"v\":\"x\"}\n{\"v\":\"y\"}\n", extension: "json")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .existing(schema: "main", table: "t")
    let batch = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 3)
    #expect(batch.statements.count == 1)
    #expect(batch.statements[0].sql.hasPrefix("INSERT INTO"))
    #expect(batch.rowRanges == [1...2])
  }

  @Test("A column first seen after the preview cannot be silently omitted")
  func lateJSONColumn() async throws {
    let rows = (0..<100).map { "{\"id\":\($0)}" }.joined(separator: "\n")
    let url = temporaryFile(rows + "\n{\"id\":100,\"late\":\"secret\"}\n", extension: "json")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .new(schema: nil, table: "people")
    #expect(model.mappings.map(\.sourceName) == ["id"])
    await #expect(throws: TableImportError.self) {
      _ = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 1)
    }
  }

  @Test("A wider CSV row after the preview cannot be silently omitted")
  func lateCSVColumn() async throws {
    let url = temporaryFile(
      "id\n" + (0..<100).map(String.init).joined(separator: "\n") + "\n100,secret\n",
      extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .new(schema: nil, table: "people")
    await #expect(throws: TableImportError.self) {
      _ = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 1)
    }
  }

  @Test("Preview reads enough rows from a large file without requiring its tail")
  func boundedPreview() async throws {
    let url = temporaryFile(
      "id\n" + (0..<100).map(String.init).joined(separator: "\n") + "\n"
        + String(repeating: "x", count: 9 * 1_024 * 1_024), extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    #expect(model.previewRows.count == 100)
    #expect(model.errorMessage == nil)
  }

  @Test("JSON preview keeps Unicode when the read ends inside a UTF-8 codepoint")
  func jsonPreviewUTF8Boundary() async throws {
    let firstRows = "[" + Array(repeating: "{\"café\":1}", count: 100).joined(separator: ",")
    let marker = ", {\"tail\":\""
    let padding = 65_535 - firstRows.utf8.count - marker.utf8.count
    let content = firstRows + marker + String(repeating: "x", count: padding) + "é\"}]"
    let url = temporaryFile(content, extension: "json")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    #expect(model.previewRows.count == 100)
    #expect(model.mappings.map(\.sourceName) == ["café"])
  }

  @Test("A huge record stops preview at its memory budget")
  func previewBudget() async throws {
    let url = temporaryFile(
      "id\n" + String(repeating: "x", count: 9 * 1_024 * 1_024), extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    #expect(model.previewRows.isEmpty)
    #expect(model.errorMessage == TableImportError.previewLimit.localizedDescription)
  }

  @Test("A sparse file above the safety limit fails before full parsing")
  func fullImportSizeLimit() async throws {
    let url = temporaryFile(
      "id\n" + (0..<100).map(String.init).joined(separator: "\n") + "\n",
      extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 257 * 1_024 * 1_024)
    try handle.close()
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .new(schema: nil, table: "people")
    await #expect(throws: TableImportError.self) {
      _ = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 1)
    }
  }

  @Test("Import history does not retain database detail or bound file values")
  func importHistoryRedactsFailure() async throws {
    let viewModel = NotebookViewModel()
    let recorder = ImportHistoryRecorder()
    viewModel.historyRecorder = recorder
    await viewModel.recordExecution(
      [
        QueryHistoryOutcome(
          sql: "INSERT INTO t (v) -- 1 row from file", duration: 0,
          rowCount: nil, status: .error,
          errorMessage: "Detail: Key (v)=(secret-from-file) already exists")
      ],
      source: .dataImport)
    let entry = try #require(await recorder.entries.first)
    #expect(entry.errorMessage == "Import failed")
  }

  @Test("A cancelled import is recorded as cancelled without source values")
  func cancelledImportHistory() async {
    let viewModel = NotebookViewModel()
    let recorder = ImportHistoryRecorder()
    viewModel.historyRecorder = recorder
    viewModel.recordFailure(
      DatabaseError.batchCancelled,
      sql: "INSERT INTO t (v) -- 2 rows from file", duration: 0,
      source: .dataImport)
    let entry = await recorder.nextEntry()
    #expect(entry.status == .cancelled)
    #expect(entry.errorMessage == "Import cancelled")
  }

  @Test("Reload uses the format selected in the sheet")
  func selectedFormat() async throws {
    let url = temporaryFile("{\"name\":\"Ada\"}\n", extension: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    model.format = .json
    await model.reloadPreview()
    #expect(model.format == .json)
    #expect(model.mappings.map(\.sourceName) == ["name"])
    #expect(model.previewRows == [["Ada"]])
  }

  @Test("Pure gate pre-check explains why CREATE is blocked")
  func schemaProtection() async {
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = ConnectionConfig(
      databaseType: .sqlite, database: "/tmp/unused.sqlite", username: "",
      protectionLevel: .schemaOnly, safeMode: .silent)
    let viewModel = NotebookViewModel(notebook: notebook)
    let batch = PendingStagedBatch(
      statements: [
        BoundStatement(
          sql: "CREATE TABLE t (v TEXT)", values: [], expectedRows: nil)
      ],
      preview: "CREATE TABLE t (v TEXT);", connectionEpoch: 0,
      historySource: .dataImport)
    let reason = await viewModel.beginImportBatch(batch)
    #expect(reason?.contains("Schema change") == true)
    #expect(viewModel.pendingStagedBatch == nil)
  }

  @Test("Safe Mode confirms the import summary before sending bound SQL")
  func safeModeSummary() async {
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = ConnectionConfig(
      databaseType: .sqlite, database: "/tmp/unused.sqlite", username: "",
      protectionLevel: .none, safeMode: .alertAll)
    let viewModel = NotebookViewModel(notebook: notebook)
    let summary = "INSERT INTO \"t\" (\"name\") -- 1 rows from file"
    let batch = PendingStagedBatch(
      statements: [
        BoundStatement(
          sql: "INSERT INTO t (name) VALUES (?1)", values: ["secret"])
      ],
      preview: summary, connectionEpoch: 0, historySource: .dataImport,
      rowRanges: [1...1])
    let reason = await viewModel.beginImportBatch(batch)
    #expect(reason == nil)
    #expect(viewModel.pendingStagedBatch?.preview == summary)
    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(!viewModel.queryConfirmationState.pendingQuery.contains("secret"))
  }

  @Test("A failed import reports the source row range")
  func failedRowRange() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-range-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", safeMode: .silent,
      protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    let batch = PendingStagedBatch(
      statements: [
        BoundStatement(
          sql: "CREATE TABLE t (id INTEGER PRIMARY KEY)", values: [], expectedRows: nil),
        BoundStatement(
          sql: "INSERT INTO t (id) VALUES (?1), (?2)", values: ["1", "1"], expectedRows: 2),
      ],
      preview: "CREATE TABLE t (id INTEGER PRIMARY KEY);\nINSERT INTO t (id) -- 2 rows from file",
      connectionEpoch: await manager.connectionEpoch, historySource: .dataImport,
      rowRanges: [nil, 1...2])
    let reason = await viewModel.beginImportBatch(batch)
    #expect(reason?.contains("Rows 1–2") == true)
  }

  private func temporaryFile(_ contents: String, extension fileExtension: String) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-\(UUID().uuidString).\(fileExtension)")
    try! Data(contents.utf8).write(to: url)
    return url
  }
}

private actor ImportHistoryRecorder: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []
  private var waiter: CheckedContinuation<QueryHistoryEntry, Never>?

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
    waiter?.resume(returning: entry)
    waiter = nil
  }

  func nextEntry() async -> QueryHistoryEntry {
    if let entry = entries.first { return entry }
    return await withCheckedContinuation { waiter = $0 }
  }
}
