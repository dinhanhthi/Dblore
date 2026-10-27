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

  @Test("A UTF-8 preview fails the full import instead of switching to Latin-1")
  func encodingChangesAfterPreview() async throws {
    // The invalid byte sits past the first 64 KB read, so only the full parse sees it
    var data = Data(("name\n" + String(repeating: "caf\u{00e9}\n", count: 20_000)).utf8)
    data.append(contentsOf: [0xFF, 0x0A])
    let url = temporaryFile("", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .new(schema: nil, table: "people")
    #expect(model.previewRows.first == ["caf\u{00e9}"])
    await #expect(throws: DelimitedTextError.encodingChanged) {
      _ = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 1)
    }
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
    var config = ConnectionConfig(
      databaseType: .sqlite, database: "/tmp/unused.sqlite", username: "",
      protectionLevel: .none, protectedMode: false)
    config.applyCommitStyle(.confirm)
    notebook.connectionConfig = config
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
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
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
    #expect(reason?.contains("UNIQUE") == true)
    // The toast never shows server detail, which can quote file values
    #expect(toasts.count == 1)
    #expect(toasts.first?.contains("Rows 1–2") == true)
    #expect(toasts.first?.contains("UNIQUE") == false)
  }

  @Test("A batch confirmed in Safe Mode after the sheet closed points the toast at History")
  func confirmedImportFailure() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-confirm-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: .alertAll, protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal("CREATE TABLE t (id INTEGER PRIMARY KEY)")
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    let recorder = ImportHistoryRecorder()
    viewModel.historyRecorder = recorder
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    let batch = PendingStagedBatch(
      statements: [
        BoundStatement(
          sql: "INSERT INTO t (id) VALUES (?1), (?2)", values: ["7", "7"], expectedRows: 2)
      ],
      preview: "INSERT INTO t (id) -- 2 rows from file",
      connectionEpoch: await manager.connectionEpoch, historySource: .dataImport,
      rowRanges: [1...2])

    // The sheet closes once Safe Mode asks; the failure arrives after the user confirms
    #expect(await viewModel.beginImportBatch(batch) == nil)
    #expect(viewModel.queryConfirmationState.showDialog)
    await viewModel.executePendingQuery()

    #expect(toasts.count == 1)
    let toast = try #require(toasts.first)
    #expect(toast.contains("Rows 1–2"))
    #expect(toast.contains("History"))
    #expect(!toast.contains("import sheet"))
    #expect(!toast.contains("UNIQUE"))
    let entry = await recorder.nextEntry()
    #expect(entry.status == .error)
    #expect(entry.errorMessage == "Rows 1–2: Import failed")
  }

  @Test("JSON preview of a single-line array with very long records returns the same rows")
  func longJSONRecordPreview() async throws {
    let records = (0..<120).map {
      "{\"id\":\($0),\"blob\":\"\(String(repeating: "x", count: 66_000))\"}"
    }
    let url = temporaryFile("[" + records.joined(separator: ",") + "]", extension: "json")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    #expect(model.errorMessage == nil)
    #expect(model.mappings.map(\.sourceName) == ["id", "blob"])
    #expect(model.previewRows.count == 100)
    #expect(model.previewRows.first?.first == "0")
    #expect(model.previewRows.last?.first == "99")
    #expect(model.previewRows.last?.last??.count == 66_000)
  }

  @Test("Preview of very long records returns the same rows")
  func longRecordPreview() async throws {
    let rows = (0..<100).map { "\($0),\(String(repeating: "x", count: 70_000))" }
    let url = temporaryFile("id,blob\n" + rows.joined(separator: "\n") + "\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    #expect(model.errorMessage == nil)
    #expect(model.mappings.map(\.sourceName) == ["id", "blob"])
    #expect(model.previewRows.count == 100)
    #expect(model.previewRows.first?.first == "0")
    #expect(model.previewRows.last?.first == "99")
    #expect(model.previewRows.last?.last??.count == 70_000)
  }

  @Test("An import never sends a Data Rewind plan, so imported rows are never recorded")
  func importRecordsNoRewind() async throws {
    let directory = FileManager.default.temporaryDirectory
    let url = directory.appendingPathComponent("dblore-import-rewind-\(UUID().uuidString).sqlite")
    let storeURL = directory.appendingPathComponent("dblore-import-store-\(UUID().uuidString)")
    defer {
      for path in [url.path, storeURL.path] {
        for suffix in ["", "-wal", "-shm"] {
          try? FileManager.default.removeItem(atPath: path + suffix)
        }
      }
    }
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", safeMode: .silent,
      protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal("CREATE TABLE t (id INTEGER PRIMARY KEY)")
    let store = try RewindStore(url: storeURL)
    let recorder = RewindRecorder(store: store)
    await manager.setRewindRecorder(recorder)
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    let epoch = await manager.connectionEpoch
    let target = EditTarget(
      qualifiedName: "\"main\".\"t\"", tableID: .sqlite(schema: "main", table: "t"),
      primaryKeyColumns: ["id"], connectionEpoch: epoch, schema: "main", name: "t")
    // Even a plan set by mistake is not sent for an import
    let batch = PendingStagedBatch(
      statements: [BoundStatement(sql: "INSERT INTO t (id) VALUES (?1)", values: ["5"])],
      preview: "INSERT INTO t (id) -- 1 row from file", connectionEpoch: epoch,
      historySource: .dataImport, rowRanges: [1...1],
      rewindPlan: RewindPlan(
        target: target, columns: [RewindColumn(name: "id", typeName: "INTEGER")],
        editKind: .staged,
        steps: [.init(operation: .insert, keyBefore: nil, keyAfter: [.int(5)])]))

    #expect(await viewModel.beginImportBatch(batch) == nil)

    let stored = try await manager.executeInternal("SELECT id FROM t")
    #expect(stored.rows == [[.int(5)]])
    await recorder.flushed()
    #expect(try store.count() == 0)
  }

  @Test("SQLite TEXT affinity follows the declared type")
  func textAffinity() {
    for type in ["TEXT", "varchar(10)", "CLOB", "NATIVE CHARACTER(70)"] {
      #expect(TableImportModel.hasTextAffinity(type), "\(type)")
    }
    for type in ["INTEGER", "BOOLEAN", "NUMERIC", "REAL", ""] {
      #expect(!TableImportModel.hasTextAffinity(type), "\(type)")
    }
  }

  @Test("Match keys: primary key first, then unique indexes on plain columns only")
  func matchKeysFromIndexes() async {
    let structure = keyStructure(
      indexes: [
        index("a_partial", [.column("code")], isPartial: true),
        index("b_lower", [.column("org"), .expression("lower(name)")]),
        index("c_plain", [.column("name")], isUnique: false),
        index("users_email_key", [.column("email")]),
        index("users_pkey", [.column("id")], isPrimary: true),
        index("z_pair", [.column("org"), .column("code")]),
      ],
      constraints: [
        .init(name: "users_pkey", kind: .primaryKey, columns: ["id"]),
        .init(name: "users_email_key", kind: .unique, columns: ["email"]),
      ])
    let model = TableImportModel()
    model.destination = .existing(schema: nil, table: "Users")
    model.tables = [DatabaseTable(schema: "public", name: "users")]
    let requested = StructureRequests()
    await model.loadMatchKeys { schema, table in
      await requested.record(schema, table)
      return structure
    }
    #expect(await requested.last == ["public", "Users"])
    #expect(model.matchKeys.map(\.columns) == [["id"], ["email"], ["org", "code"]])
    #expect(model.matchKeys.map(\.isPrimaryKey) == [true, false, false])
    #expect(model.matchKeys[0].displayName == "Primary key (id)")
    #expect(model.matchKeys[2].displayName == "z_pair (org, code)")
    #expect(model.matchModesUnavailableReason == nil)
  }

  @Test("A key known only as a constraint is offered unless its index has an expression part")
  func matchKeysFromConstraints() async {
    // SQLite INTEGER PRIMARY KEY and DuckDB keys have no index row; a constraint whose index
    // has an expression part lists only its plain columns
    let structure = keyStructure(
      indexes: [index("u_mixed", [.column("a"), .expression(nil)])],
      constraints: [
        .init(name: nil, kind: .primaryKey, columns: ["id"]),
        .init(name: "t_code_key", kind: .unique, columns: ["code"]),
        .init(name: "u_mixed", kind: .unique, columns: ["a"]),
      ])
    let model = TableImportModel()
    model.destination = .existing(schema: "main", table: "t")
    await model.loadMatchKeys { _, _ in structure }
    #expect(model.matchKeys.map(\.columns) == [["id"], ["code"]])
    #expect(model.matchModesUnavailableReason == nil)
  }

  @Test("Without a primary key or plain unique index only Insert is available, with the reason")
  func noMatchKeys() async {
    let structure = keyStructure(
      indexes: [index("p", [.column("a")], isPartial: true)], constraints: [])
    let model = TableImportModel()
    model.destination = .existing(schema: "main", table: "t")
    await model.loadMatchKeys { _, _ in structure }
    #expect(model.matchKeys.isEmpty)
    #expect(
      model.matchModesUnavailableReason
        == "This table has no primary key or unique index on plain columns, so only Insert is available."
    )
    await model.loadMatchKeys { _, _ in throw DatabaseError.queryFailed("denied", 0) }
    #expect(model.matchKeys.isEmpty)
    #expect(model.matchModesUnavailableReason?.contains("denied") == true)
  }

  @Test("Keyed rows route to INSERT, UPDATE, skip or refused per mode, and the counts match")
  func rowsRoutePerMode() async throws {
    // Row 1 exists, 2 is new, 3 matches two rows, 4 has no key, 5 repeats row 2's key
    let url = temporaryFile("id,name\n1,a\n2,b\n3,c\n,d\n2,e\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .existing(schema: "main", table: "t")
    let structure = keyStructure(
      columns: [column("id", "INTEGER"), column("name", "TEXT")], indexes: [],
      constraints: [.init(name: nil, kind: .primaryKey, columns: ["id"])])
    await model.loadMatchKeys { _, _ in structure }
    model.matchKey = model.matchKeys.first
    #expect(model.matchKey != nil)
    let reads = MatchReads(existing: ["1": 1, "3": 2])
    let tooMany = "2 rows in the table match this key."
    let repeated = "This key appears earlier in the file."
    let cases: [(ImportMode, [String], [ClosedRange<Int>?], [Int], [Int])] = [
      // mode, statement verbs, row ranges, [insert, update, skip], refused rows
      (.insert, ["INSERT"], [2...4], [2, 0, 0], [1, 3, 5]),
      (.update, ["UPDATE"], [1...1], [0, 1, 1], [3, 4, 5]),
      (.insertOrUpdate, ["INSERT", "UPDATE"], [2...4, 1...1], [2, 1, 0], [3, 5]),
      (.insertSkippingExisting, ["INSERT"], [2...4], [2, 0, 1], [3, 5]),
    ]
    for (mode, verbs, ranges, counts, refusedRows) in cases {
      model.mode = mode
      let batch = try await model.prepareBatch(
        dialect: .sqlite, connectionEpoch: 1, readMatches: reads.read)
      #expect(batch.statements.map { String($0.sql.prefix(6)) } == verbs, "\(mode)")
      #expect(batch.rowRanges == ranges, "\(mode)")
      let summary = try #require(model.matchSummary)
      #expect([summary.inserts, summary.updates, summary.skips] == counts, "\(mode)")
      #expect(summary.refusedCount == refusedRows.count, "\(mode)")
      #expect(summary.refused.map(\.row) == refusedRows, "\(mode)")
      #expect(summary.refused.first { $0.row == 3 }?.reason == tooMany)
      #expect(summary.refused.first { $0.row == 5 }?.reason == repeated)
      #expect(
        batch.preview.hasPrefix("-- From file: \(counts[0]) to insert, \(counts[1]) to update"))
    }
    model.mode = .insertOrUpdate
    let batch = try await model.prepareBatch(
      dialect: .sqlite, connectionEpoch: 1, readMatches: reads.read)
    #expect(batch.statements[0].values == ["2", "b", nil, "d"])
    #expect(batch.statements[1].sql == #"UPDATE "t" SET "name" = ?1 WHERE "id" = ?2"#)
    #expect(batch.statements[1].values == ["a", "1"])
    #expect(model.matchSummary?.newRows == 2)
    #expect(model.matchSummary?.existingRows == 1)
  }

  @Test("A failed match read stops the import before anything is written")
  func matchReadFailureWritesNothing() async throws {
    let url = temporaryFile("id,name\n1,a\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .existing(schema: "main", table: "t")
    let structure = keyStructure(
      columns: [column("id", "INTEGER"), column("name", "TEXT")], indexes: [],
      constraints: [.init(name: nil, kind: .primaryKey, columns: ["id"])])
    await model.loadMatchKeys { _, _ in structure }
    model.matchKey = model.matchKeys.first
    model.mode = .insertOrUpdate
    await #expect(throws: TableImportError.self) {
      try await model.prepareBatch(
        dialect: .sqlite, connectionEpoch: 1,
        readMatches: { _ in throw DatabaseError.queryFailed("denied", 0) })
    }
    #expect(model.matchSummary == nil)
    #expect(!model.isMatchingRows)
  }

  @Test("A keyed import inserts and updates through the tab, and History keeps the counts")
  func keyedImportHistory() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-keyed-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", safeMode: .silent,
      protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal(
      "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t VALUES (1, 'a'), (3, 'c')")
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    let recorder = ImportHistoryRecorder()
    viewModel.historyRecorder = recorder
    let file = temporaryFile("id,name\n1,A\n2,B\n3,c\n2,Z\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: file) }
    let model = TableImportModel()
    await model.loadFile(file)
    model.destination = .existing(schema: "main", table: "t")

    // An open transaction: the read would see (and could abort) it, so nothing is read or sent
    _ = try await manager.execute(
      userSQL: "BEGIN", policy: ProtectionPolicy(protectionLevel: .none))
    await model.loadMatchKeys { try await manager.fetchTableStructure(schema: $0, table: $1) }
    model.matchKey = model.matchKeys.first
    #expect(model.matchKey != nil)
    model.mode = .insertOrUpdate
    #expect(await model.submit(to: viewModel) == false)
    #expect(model.errorMessage?.contains("nothing was written") == true)
    _ = try await manager.execute(
      userSQL: "ROLLBACK", policy: ProtectionPolicy(protectionLevel: .none))
    #expect(
      try await manager.executeInternal("SELECT id, name FROM t ORDER BY id").rows == [
        [.int(1), .string("a")], [.int(3), .string("c")],
      ])

    #expect(await model.submit(to: viewModel))
    #expect(
      try await manager.executeInternal("SELECT id, name FROM t ORDER BY id").rows == [
        [.int(1), .string("A")], [.int(2), .string("B")], [.int(3), .string("c")],
      ])
    let entry = await recorder.nextEntry()
    #expect(entry.status == .success)
    #expect(entry.sql.hasPrefix("-- From file: 1 to insert, 2 to update, 0 skipped, 1 refused"))
    #expect(entry.rowCount == 3)
  }

  @Test("Only keys whose columns are all imported are offered; losing the last goes to Insert")
  func offeredKeysFollowMapping() async throws {
    let url = temporaryFile("id,code,name\n1,a,x\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .existing(schema: "main", table: "t")
    let structure = keyStructure(
      columns: [column("id", "INTEGER"), column("code", "TEXT"), column("name", "TEXT")],
      indexes: [index("t_code_key", [.column("code")])],
      constraints: [.init(name: nil, kind: .primaryKey, columns: ["id"])])
    await model.loadMatchKeys { _, _ in structure }
    #expect(model.offeredMatchKeys.map(\.columns) == [["id"], ["code"]])
    #expect(model.mode == .insert)
    #expect(model.matchKey == nil)

    // Leaving Insert picks the primary key; going back to Insert drops the key (plain INSERT)
    model.selectMode(.update)
    #expect(model.mode == .update)
    #expect(model.matchKey?.columns == ["id"])
    model.selectMode(.insert)
    #expect(model.matchKey == nil)
    model.selectMode(.insertOrUpdate)

    // The chosen key's column is no longer imported: the next offered key takes its place
    model.mappings[0].included = false
    model.syncMatchChoice()
    #expect(model.offeredMatchKeys.map(\.columns) == [["code"]])
    #expect(model.matchKey?.columns == ["code"])
    #expect(model.mode == .insertOrUpdate)

    // Names compare exactly, as the planner binds them: "Code" does not import "code"
    model.mappings[1].targetName = "Code"
    model.syncMatchChoice()
    #expect(model.offeredMatchKeys.isEmpty)
    #expect(model.matchKey == nil)
    #expect(model.mode == .insert)
    #expect(model.keyedModesUnavailableReason?.contains("Import every column of a key") == true)
    model.selectMode(.update)
    #expect(model.mode == .insert)

    // A load reason wins over the mapping one
    await model.loadMatchKeys { _, _ in throw DatabaseError.queryFailed("denied", 0) }
    #expect(model.keyedModesUnavailableReason?.contains("denied") == true)
  }

  @Test("A debounced key load cancelled while it waits reads nothing")
  func debouncedKeyLoadCancelled() async {
    let model = TableImportModel()
    model.destination = .existing(schema: "main", table: "t")
    let requested = StructureRequests()
    let structure = keyStructure(
      indexes: [], constraints: [.init(name: nil, kind: .primaryKey, columns: ["id"])])
    let load = Task {
      await model.loadMatchKeys(after: .seconds(60)) { schema, table in
        await requested.record(schema, table)
        return structure
      }
    }
    load.cancel()
    await load.value
    #expect(await requested.last.isEmpty)
    #expect(!model.isLoadingMatchKeys)
    #expect(model.matchKeys.isEmpty)
  }

  @Test("A keyed import shows its summary before Safe Mode; Back writes nothing")
  func summaryBeforeSafeMode() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-review-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: .alertAll, protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal(
      "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t VALUES (1, 'a')")
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    let file = temporaryFile("id,name\n1,A\n2,B\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: file) }
    let model = TableImportModel()
    await model.loadFile(file)
    model.destination = .existing(schema: "main", table: "t")
    await model.loadMatchKeys { try await manager.fetchTableStructure(schema: $0, table: $1) }
    model.selectMode(.insertOrUpdate)
    let stored = { try await manager.executeInternal("SELECT id, name FROM t ORDER BY id").rows }
    let original: [[CellValue]] = [[.int(1), .string("a")]]

    // The counts come first: nothing is written and Safe Mode has not asked yet
    #expect(await model.prepareImport(for: viewModel))
    #expect(model.isReviewingMatches)
    #expect(model.notice == nil)
    #expect(model.matchSummary?.newRows == 1)
    #expect(model.matchSummary?.existingRows == 1)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(try await stored() == original)

    // Back: the prepared batch is gone, so a late Continue does nothing
    model.endMatchReview()
    #expect(!model.isReviewingMatches)
    #expect(model.matchSummary == nil)
    #expect(await model.confirmImport(to: viewModel) == false)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(try await stored() == original)

    // Continue: the one Safe Mode decision, then the batch
    #expect(await model.prepareImport(for: viewModel))
    #expect(await model.confirmImport(to: viewModel))
    #expect(!model.isReviewingMatches)
    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(try await stored() == original)
    await viewModel.executePendingQuery()
    #expect(try await stored() == [[.int(1), .string("A")], [.int(2), .string("B")]])

    // A failed match read stays in the sheet: no toast carries its detail
    _ = try await manager.execute(
      userSQL: "BEGIN", policy: ProtectionPolicy(protectionLevel: .none))
    #expect(await model.prepareImport(for: viewModel) == false)
    #expect(model.errorMessage?.contains("nothing was written") == true)
    #expect(!model.isReviewingMatches)
    #expect(toasts.isEmpty)
    _ = try await manager.execute(
      userSQL: "ROLLBACK", policy: ProtectionPolicy(protectionLevel: .none))
  }

  @Test("Every row skipped or refused is a notice with the summary, not an error")
  func nothingToWriteIsNotice() async throws {
    let url = temporaryFile("id,name\n1,a\n3,c\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .existing(schema: "main", table: "t")
    let structure = keyStructure(
      columns: [column("id", "INTEGER"), column("name", "TEXT")], indexes: [],
      constraints: [.init(name: nil, kind: .primaryKey, columns: ["id"])])
    await model.loadMatchKeys { _, _ in structure }
    model.selectMode(.insertSkippingExisting)
    let reads = MatchReads(existing: ["1": 1, "3": 2])
    #expect(
      await model.prepareImport(dialect: .sqlite, connectionEpoch: 1, readMatches: reads.read)
        == false)
    #expect(model.errorMessage == nil)
    #expect(model.notice == "No rows to write: 1 skipped, 1 refused.")
    #expect(model.isReviewingMatches)
    #expect(model.matchSummary?.refused.map(\.row) == [2])
    model.endMatchReview()
    #expect(model.notice == nil)
    #expect(!model.isReviewingMatches)
  }

  private func keyStructure(
    columns: [TableStructure.Column] = [], indexes: [TableStructure.Index],
    constraints: [TableStructure.Constraint]
  ) -> TableStructure {
    TableStructure(
      tableID: .sqlite(schema: "main", table: "t"), schema: "main", name: "t", columns: columns,
      indexes: indexes, constraints: constraints)
  }

  private func column(_ name: String, _ dataType: String) -> TableStructure.Column {
    TableStructure.Column(ordinal: 1, name: name, dataType: dataType, isNullable: true)
  }

  private func index(
    _ name: String, _ keys: [TableStructure.Index.Key], isUnique: Bool = true,
    isPrimary: Bool = false, isPartial: Bool = false
  ) -> TableStructure.Index {
    TableStructure.Index(
      name: name, keys: keys, isUnique: isUnique, isPrimary: isPrimary, method: nil,
      isPartial: isPartial, predicate: isPartial ? "a > 0" : nil)
  }

  private func temporaryFile(_ contents: String, extension fileExtension: String) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-\(UUID().uuidString).\(fileExtension)")
    try! Data(contents.utf8).write(to: url)
    return url
  }
}

private actor StructureRequests {
  private(set) var last: [String] = []

  func record(_ schema: String, _ table: String) { last = [schema, table] }
}

/// Stub match reads (SQLite shape): the count of each listed position from its key text
private struct MatchReads: Sendable {
  let existing: [String: Int]

  var read: @Sendable (BoundStatement) async throws -> [[CellValue]] {
    { [existing] read in
      let positions = read.sql.matches(of: /\((\d+), \?\d+\)/).map { Int($0.1)! }
      return zip(positions, read.values).compactMap { position, value in
        existing[value ?? ""].map { [.int(position), .int($0)] }
      }
    }
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
