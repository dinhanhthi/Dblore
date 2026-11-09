// TableImportStreamTests.swift
// The one-file sheet's streamed import (CSV, TSV, NDJSON into a new table or one without a key)
// sent through the gate to a fake session: what reaches the session, in which order. A changed
// file stops before its changed block's INSERT and rolls back; a file the first read refuses
// (encoding, a late NDJSON key) sends nothing; DuckDB in Protected mode is refused at the gate;
// MySQL sends its CREATE TABLE before the rows' transaction. Keyed and JSON-array imports and the
// multi-file batch stay on the in-memory path. Temporary files, no server.
//
// Covered elsewhere, not repeated here: the batch shape, checked 1,000-row chunks and row
// ranges (`TableImportModelTests.streamedCSV`); a changed, extra or missing block at the run
// level (`streamedFileChanged`); NDJSON streamed, a JSON array in memory, MySQL's
// `separateCreate` (`streamedEligibility`); Safe Mode and the sheet's run (`streamedSafeModeRun`);
// DuckDB Protected mode refused by the sheet through `submit` (`DuckDBTableImportTests`
// `importInTransactionRefused`, which takes the streamed path since `submit` allows it).

import Foundation
import Testing

@testable import Dblore

@Suite("Table import stream")
@MainActor
struct TableImportStreamTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  @Test("A CSV streams through the gate: BEGIN, CREATE, one INSERT per block, COMMIT")
  func endToEndThroughGate() async throws {
    let lines = (1...2_500).map { "p\($0),\($0)" }
    let url = temporaryFile("name,n\n" + lines.joined(separator: "\n") + "\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let (factory, manager, viewModel) = try await postgresTab(currentSchema: "qa_trap")
    defer { Task { await manager.disconnect() } }
    let sentBefore = factory.statements.count
    let model = TableImportModel()
    await model.loadFile(url)
    // An empty Schema: the prelude and every chunk name the schema current_schema() gave
    model.destination = .new(schema: nil, table: "t")

    #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
    #expect(model.errorMessage == nil)
    let sent = Array(factory.statements.dropFirst(sentBefore))
    #expect(sent.filter { $0.contains("current_schema()") }.count == 1)
    let run = writes(sent)
    try #require(run.count == 6, "\(run)")
    #expect(run[0] == "BEGIN")
    #expect(run[1] == #"CREATE TABLE "qa_trap"."t" ("name" text, "n" bigint)"#)
    #expect(run[2...4].allSatisfy { $0.hasPrefix(#"INSERT INTO "qa_trap"."t" ("name", "n") "#) })
    #expect(run[5] == "COMMIT")
    // Every file row, in file order, once
    let binds = insertBinds(factory)
    #expect(binds.count == 2 * 2_500)
    #expect(binds.prefix(2) == [.text("p1"), .text("1")])
    #expect(binds.suffix(2) == [.text("p2500"), .text("2500")])
    #expect(await manager.transactionSnapshot().isIdle)
  }

  @Test("A second block changed after the check stops before its INSERT and rolls back")
  func fileChangedThroughGate() async throws {
    let rows = (1...2_000).map { "\($0)" }
    let url = temporaryFile("id\n" + rows.joined(separator: "\n") + "\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let (factory, manager, viewModel) = try await postgresTab()
    defer { Task { await manager.disconnect() } }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .new(schema: "public", table: "t")
    #expect(await model.prepareImport(for: viewModel))
    var changed = rows
    changed[1_500] = "99999"  // still an integer: only the digest tells
    try Data(("id\n" + changed.joined(separator: "\n") + "\n").utf8).write(to: url)
    let sentBefore = factory.statements.count

    #expect(await model.confirmImport(to: viewModel) == false)
    let message = try #require(model.errorMessage)
    #expect(message.contains(TableImportError.fileChanged.localizedDescription), "\(message)")
    let run = writes(Array(factory.statements.dropFirst(sentBefore)))
    try #require(run.count == 4, "\(run)")
    #expect(run[0] == "BEGIN")
    #expect(run[1].hasPrefix(#"CREATE TABLE "public"."t""#))
    #expect(run[2].hasPrefix(#"INSERT INTO "public"."t""#))
    #expect(run[3] == "ROLLBACK")
    // Only the first, unchanged block was sent
    #expect(insertBinds(factory).count == 1_000)
    #expect(!insertBinds(factory).contains(.text("99999")))
    #expect(await manager.transactionSnapshot().isIdle)
  }

  @Test("A cancel while the second block is read rolls back the CREATE and the first block")
  func cancelDuringPassTwo() async throws {
    let rows = (1...2_000).map { "\($0)" }
    let url = temporaryFile("id\n" + rows.joined(separator: "\n") + "\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let (factory, manager, _) = try await postgresTab()
    defer { Task { await manager.disconnect() } }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .new(schema: "public", table: "t")
    let streamed = try #require(
      try await model.prepareBatch(dialect: .postgresql, connectionEpoch: 0, allowsStreaming: true)
        .streamed)
    let pause = ChunkPause()
    let paused = copy(streamed) { calls in
      if calls == 1 { await pause.checkpoint() }
    }
    let sentBefore = factory.statements.count
    let epoch = await manager.connectionEpoch
    let run = Task {
      try await manager.executeGatedBatch(streamed: paused, policy: open, connectionEpoch: epoch)
    }
    await pause.waitUntilArrived()
    let status = await manager.runningStatementStatus()
    #expect(status.inFlight)
    let outcome = await manager.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    await pause.resume()
    await #expect(throws: DatabaseError.self) { _ = try await run.value }
    let sent = writes(Array(factory.statements.dropFirst(sentBefore)))
    #expect(sent.first == "BEGIN")
    #expect(sent.filter { $0.hasPrefix("INSERT") }.count == 1, "\(sent)")
    #expect(sent.last == "ROLLBACK", "\(sent)")
    #expect(!sent.contains("COMMIT"))
  }

  @Test(
    "A Latin-1 byte after a UTF-8 preview is refused by the first read, before anything is sent")
  func encodingChangedSendsNothing() async throws {
    // ASCII rows fill the preview and the first 1 MiB chunk; the Latin-1 é sits in the second
    let row = String(repeating: "a", count: 999) + "\n"
    var data = Data(("name\n" + String(repeating: row, count: 1_100)).utf8)
    data.append(contentsOf: Array("caf".utf8) + [0xE9, 0x0A])
    let url = temporaryFile("", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let (factory, manager, viewModel) = try await postgresTab(currentSchema: "qa_trap")
    defer { Task { await manager.disconnect() } }
    let sentBefore = factory.statements.count
    let model = TableImportModel()
    await model.loadFile(url)
    #expect(model.previewRows.count == 100)
    model.destination = .new(schema: nil, table: "t")
    #expect(model.streamsImport)
    await #expect(throws: DelimitedTextError.encodingChanged) {
      _ = try await model.prepareBatch(
        dialect: .postgresql, connectionEpoch: 0, allowsStreaming: true)
    }

    // Through the tab: refused with the encoding message; not even current_schema() is read
    #expect(await model.prepareImport(for: viewModel) == false)
    #expect(model.errorMessage == DelimitedTextError.encodingChanged.localizedDescription)
    #expect(factory.statements.count == sentBefore, "\(factory.statements.dropFirst(sentBefore))")
  }

  @Test("An NDJSON line after the preview with a key the mapping lacks sends nothing")
  func lateNDJSONKeySendsNothing() async throws {
    let lines = (0..<150).map { "{\"id\": \($0)}" }
    let url = temporaryFile(
      lines.joined(separator: "\n") + "\n{\"id\": 150, \"late\": \"secret\"}\n",
      extension: "json")
    defer { try? FileManager.default.removeItem(at: url) }
    let (factory, manager, viewModel) = try await postgresTab(currentSchema: "qa_trap")
    defer { Task { await manager.disconnect() } }
    let sentBefore = factory.statements.count
    let model = TableImportModel()
    await model.loadFile(url)
    #expect(model.mappings.map(\.sourceName) == ["id"])
    model.destination = .new(schema: nil, table: "t")
    #expect(model.streamsImport)
    do {
      _ = try await model.prepareBatch(
        dialect: .postgresql, connectionEpoch: 0, allowsStreaming: true)
      Issue.record("Expected columnsChanged")
    } catch TableImportError.columnsChanged {
      // Pass 1 met the key the preview never saw
    }
    #expect(await model.prepareImport(for: viewModel) == false)
    #expect(model.errorMessage == TableImportError.columnsChanged.localizedDescription)
    #expect(factory.statements.count == sentBefore, "\(factory.statements.dropFirst(sentBefore))")
  }

  @Test("The streamed path reads past the in-memory file size cap")
  func noFileSizeCap() async throws {
    // A sparse 257 MiB file: the in-memory read refuses its size before reading it; pass 1
    // starts reading and stops at the invalid byte in its first 1 MiB chunk, past the preview
    var data = Data(
      ("name\n" + String(repeating: String(repeating: "a", count: 999) + "\n", count: 200)).utf8)
    data.append(contentsOf: [0xFF, 0x0A])
    let url = temporaryFile("", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(DelimitedTextReader.maxImportFileBytes) + 1_048_576)
    try handle.close()
    let model = TableImportModel()
    await model.loadFile(url)
    #expect(model.previewRows.count == 100)
    model.destination = .new(schema: nil, table: "t")
    do {
      _ = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 0)
      Issue.record("Expected fileTooLarge")
    } catch TableImportError.fileTooLarge {
      // The in-memory path's cap
    }
    await #expect(throws: DelimitedTextError.encodingChanged) {
      _ = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 0, allowsStreaming: true)
    }
  }

  @Test("DuckDB in Protected mode refuses a streamed import at the gate before any chunk")
  func duckDBProtectedRefused() async throws {
    let url = temporaryFile("v\na\nb\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .new(schema: "main", table: "t")
    let streamed = try #require(
      try await model.prepareBatch(dialect: .duckdb, connectionEpoch: 0, allowsStreaming: true)
        .streamed)
    let calls = ChunkCalls()
    let counted = copy(streamed) { _ in _ = await calls.increment() }

    for protectedMode in [true, false] {
      let factory = FakeDatabaseSessionFactory(
        capabilities: DatabaseType.duckdb.capabilities, commandRows: Self.insertRows("$"))
      let manager = DatabaseConnectionManager(sessionFactory: factory)
      try await manager.connect(
        config: ConnectionConfig(
          databaseType: .duckdb, database: DuckDBSession.inMemoryPath, sslMode: .disable,
          protectionLevel: .none, safeMode: .silent, protectedMode: protectedMode,
          readOnlyFile: false))
      let sentBefore = factory.statements.count
      let epoch = await manager.connectionEpoch
      let policy = ProtectionPolicy(protectionLevel: .none, protectedMode: protectedMode)
      if protectedMode {
        do {
          _ = try await manager.executeGatedBatch(
            streamed: counted, policy: policy, connectionEpoch: epoch)
          Issue.record("Expected the Protected mode refusal")
        } catch DatabaseError.sequentialBatchRefused(let reason) {
          #expect(reason == DatabaseConnectionManager.duckDBImportProtectedModeRefusal)
        }
        #expect(await calls.count == 0)
        #expect(factory.statements.count == sentBefore)
      } else {
        // Outside Protected mode the data-import rule lets it run (row edits stay refused)
        let rows = try await manager.executeGatedBatch(
          streamed: counted, policy: policy, connectionEpoch: epoch)
        #expect(rows == 2)
        let sent = writes(Array(factory.statements.dropFirst(sentBefore)))
        #expect(
          sent == [
            "BEGIN TRANSACTION", #"CREATE TABLE "t" ("v" text)"#,
            #"INSERT INTO "t" ("v") VALUES ($1), ($2)"#, "COMMIT",
          ])
      }
      await manager.disconnect()
    }
  }

  @Test("MySQL sends a new table's CREATE alone before the rows' transaction")
  func mysqlCreateBeforeBegin() async throws {
    let rows = (1...1_500).map { "\($0)" }
    let url = temporaryFile("id\n" + rows.joined(separator: "\n") + "\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mysql.capabilities, commandRows: Self.insertRows("?"))
    let config = ConnectionConfig(
      databaseType: .mysql, host: "fake", port: 3306, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    let viewModel = tab(manager: manager, config: config)
    let sentBefore = factory.statements.count
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .new(schema: nil, table: "t")

    #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
    let sent = writes(Array(factory.statements.dropFirst(sentBefore)))
    try #require(sent.count == 5, "\(sent)")
    #expect(sent[0].hasPrefix("CREATE TABLE `t`"))
    #expect(sent[1] == "START TRANSACTION")
    #expect(sent[2...3].allSatisfy { $0.hasPrefix("INSERT INTO `t`") })
    #expect(sent[4] == "COMMIT")
    #expect(insertBinds(factory).count == 1_500)
  }

  @Test("Safe Mode says a MySQL new table is created first and stays if the rows fail")
  func mysqlSafeModeNamesKeptTable() async throws {
    let url = temporaryFile("id\n1\n2\n", extension: "csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mysql.capabilities, commandRows: Self.insertRows("?"))
    var config = ConnectionConfig(
      databaseType: .mysql, host: "fake", port: 3306, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, protectedMode: false)
    config.applyCommitStyle(.confirm)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    let viewModel = tab(manager: manager, config: config)
    let sentBefore = factory.statements.count
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .new(schema: nil, table: "t")

    _ = await model.submit(to: viewModel)
    #expect(viewModel.queryConfirmationState.showDialog)
    // The statement list cuts each line at 80 characters and drops comment-only lines, so the
    // note is a line of its own under the list
    #expect(
      viewModel.queryConfirmationState.alsoAffected == [
        NotebookViewModel.separateCreateSafeModeNote
      ])
    #expect(writes(Array(factory.statements.dropFirst(sentBefore))).isEmpty)
  }

  @Test("A JSON array stays in memory; NDJSON streams")
  func jsonLayouts() async throws {
    // `streamedEligibility` checks the batches; this checks what the sheet is told
    let array = temporaryFile("  [{\"id\": 1}, {\"id\": 2}]", extension: "json")
    let lines = temporaryFile("{\"id\": 1}\n{\"id\": 2}\n", extension: "json")
    defer {
      try? FileManager.default.removeItem(at: array)
      try? FileManager.default.removeItem(at: lines)
    }
    let whole = TableImportModel()
    await whole.loadFile(array)
    whole.destination = .new(schema: nil, table: "t")
    #expect(!whole.streamsImport)
    let staged = try await whole.prepareBatch(
      dialect: .sqlite, connectionEpoch: 0, allowsStreaming: true)
    #expect(staged.streamed == nil)
    #expect(
      staged.statements.map { String($0.sql.prefix(12)) } == ["CREATE TABLE", "INSERT INTO "])

    let streamed = TableImportModel()
    await streamed.loadFile(lines)
    streamed.destination = .new(schema: nil, table: "t")
    #expect(streamed.streamsImport)
    let batch = try await streamed.prepareBatch(
      dialect: .sqlite, connectionEpoch: 0, allowsStreaming: true)
    #expect(batch.streamed != nil)
    #expect(batch.statements.isEmpty)
  }

  @Test("The multi-file batch reads an eligible CSV whole: its CREATE and INSERTs are statements")
  func multiFileStaysInMemory() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-stream-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let rows = (1...1_500).map { "\($0)" }
    try Data(("id\n" + rows.joined(separator: "\n") + "\n").utf8)
      .write(to: folder.appendingPathComponent("a.csv"))
    let model = MultiFileImportModel(schema: "main", tables: [])
    await model.load([folder])
    let batch = try await model.prepareBatch(dialect: .sqlite, connectionEpoch: 0).batch
    #expect(batch.streamed == nil)
    #expect(batch.statements.first?.sql.hasPrefix(#"CREATE TABLE "a" ("#) == true)
    let inserts = batch.statements.dropFirst()
    #expect(!inserts.isEmpty)
    #expect(inserts.allSatisfy { $0.sql.hasPrefix(#"INSERT INTO "a" ("#) })
    #expect(inserts.reduce(0) { $0 + ($1.expectedRows ?? 0) } == 1_500)
  }

  // MARK: - Helpers

  /// INSERT and transaction statements of a run, without the app's reads
  private func writes(_ sent: [String]) -> [String] {
    sent.filter { sql in
      ["BEGIN", "START", "CREATE", "INSERT", "COMMIT", "ROLLBACK"].contains {
        sql.hasPrefix($0)
      }
    }
  }

  /// The binds of every INSERT the fake accepted, in order
  private func insertBinds(_ factory: FakeDatabaseSessionFactory) -> [SQLBindValue] {
    factory.sessions.flatMap { session in
      zip(session.statements, session.statementBinds).flatMap { sql, binds in
        sql.hasPrefix("INSERT") ? binds : []
      }
    }
  }

  /// An INSERT's affected rows for a one-row-per-tuple statement: its placeholders over its
  /// columns (the column list's commas plus one)
  private static func insertRows(_ placeholder: Character) -> @Sendable (String) -> Int? {
    { sql in
      guard sql.hasPrefix("INSERT"), let open = sql.firstIndex(of: "("),
        let close = sql[open...].firstIndex(of: ")")
      else { return nil }
      let columns = sql[open...close].filter { $0 == "," }.count + 1
      return sql.filter { $0 == placeholder }.count / columns
    }
  }

  /// A connected PostgreSQL tab on a fake session whose current_schema() is `currentSchema`
  private func postgresTab(
    currentSchema: String = "public"
  ) async throws -> (FakeDatabaseSessionFactory, DatabaseConnectionManager, NotebookViewModel) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.postgresql.capabilities, commandRows: Self.insertRows("$"),
      queryAnswer: { sql, _ in
        guard sql.contains("current_schema()") else { return nil }
        return FakeQueryAnswer(
          columns: [ColumnInfo(name: "current_schema", type: "text")],
          rows: [[.string(currentSchema)]])
      })
    let config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)
    return (factory, manager, tab(manager: manager, config: config))
  }

  private func tab(
    manager: DatabaseConnectionManager, config: ConnectionConfig
  ) -> NotebookViewModel {
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    return viewModel
  }

  /// `streamed` with `before` run ahead of each chunk (the call's number, from 0)
  private func copy(
    _ streamed: StreamedBatch, before: @escaping @Sendable (Int) async -> Void
  ) -> StreamedBatch {
    let calls = ChunkCalls()
    var copy = StreamedBatch(
      relation: streamed.relation,
      nextChunk: {
        await before(await calls.increment() - 1)
        return try await streamed.nextChunk()
      }, operation: streamed.operation, rowsLabel: streamed.rowsLabel)
    copy.prelude = streamed.prelude
    copy.isDataImport = streamed.isDataImport
    copy.rowRange = streamed.rowRange
    return copy
  }

  private func temporaryFile(_ contents: String, extension fileExtension: String) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-stream-\(UUID().uuidString).\(fileExtension)")
    try! Data(contents.utf8).write(to: url)
    return url
  }
}

private actor ChunkCalls {
  private(set) var count = 0

  /// The count after this call
  @discardableResult
  func increment() -> Int {
    count += 1
    return count
  }
}

/// Holds a chunk source at one call until the test resumes it
private actor ChunkPause {
  private var arrived = false
  private var arrivalWaiter: CheckedContinuation<Void, Never>?
  private var resumeWaiter: CheckedContinuation<Void, Never>?

  func checkpoint() async {
    arrived = true
    arrivalWaiter?.resume()
    arrivalWaiter = nil
    await withCheckedContinuation { resumeWaiter = $0 }
  }

  func waitUntilArrived() async {
    if arrived { return }
    await withCheckedContinuation { arrivalWaiter = $0 }
  }

  func resume() {
    resumeWaiter?.resume()
    resumeWaiter = nil
  }
}
