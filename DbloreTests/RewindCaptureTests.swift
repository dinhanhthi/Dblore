// RewindCaptureTests.swift
// Data Rewind capture in the gated edit paths, against a temporary SQLite file: the row read
// right before and after each keyed write (each read in its own savepoint), the entry lifecycle
// with the transaction, and the plans the data viewer builds.

import Foundation
import Testing

@testable import Dblore

@Suite("Rewind capture", .serialized)
@MainActor
struct RewindCaptureTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  private static let columns = [
    ColumnInfo(name: "id", type: "INTEGER"), ColumnInfo(name: "label", type: "TEXT"),
    ColumnInfo(name: "score", type: "REAL"),
  ]

  // MARK: - 21.1 Capture hook

  @Test("Without a plan the batch and the inline edit send exactly today's statements")
  func noPlanSendsTodaysStatements() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.tearDown() }
    let target = try await fixture.target()
    let update = BoundStatement(
      sql: "UPDATE \"main\".\"items\" SET \"label\" = ?1 WHERE \"id\" = ?2", values: ["z", "1"])
    let edit = try CellUpdateStatement.make(
      qualifiedName: target.qualifiedName, columnName: "label", newValue: "w",
      primaryKeyColumns: ["id"], rowData: ["id": .int(3)], dialect: .sqlite)
    fixture.factory.reset()

    _ = try await fixture.manager.executeGatedBatch(
      [update], policy: open, connectionEpoch: target.connectionEpoch, rewind: nil)
    _ = try await fixture.manager.executeGatedUpdate(
      edit, policy: open, connectionEpoch: target.connectionEpoch, rewind: nil)

    #expect(
      fixture.factory.statements == [
        "BEGIN IMMEDIATE", update.sql, "COMMIT", "BEGIN IMMEDIATE", edit.sql, "COMMIT",
      ])
    await fixture.recorder.flushed()
    #expect(try fixture.store.count() == 0)
  }

  @Test("A staged batch records each row read before and after its write, committed")
  func stagedBatchRecordsImages() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.tearDown() }
    let target = try await fixture.target()
    var set = RowChangeSet(target: target)
    set.stageDelete(row: RowChangeSet.RowKey(values: [.int(2)]))
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(1)]), column: "label", value: .string("z"),
      original: .string("a"))
    set.stageInsert(values: ["id": .int(10), "label": .string("n")])
    set.stageInsert(values: ["label": .string("generated")])
    let statements = try RowChangeSQLBuilder.statements(
      for: set, target: target, columns: Self.columns, dialect: .sqlite)
    let plan = try #require(
      RewindPlan.make(
        target: target, resultColumns: Self.columns, editKind: .staged,
        steps: try RowChangeSQLBuilder.rewindSteps(
          for: set, target: target, columns: Self.columns, dialect: .sqlite),
        engine: .sqlite, enabled: true))

    _ = try await fixture.manager.executeGatedBatch(
      statements, policy: open, connectionEpoch: target.connectionEpoch, rewind: plan)

    await fixture.recorder.flushed()
    let entry = try #require(try fixture.store.entries(connectionKey: nil).first)
    #expect(entry.state == .committed)
    #expect(entry.editKind == .staged)
    #expect(entry.engine == .sqlite)
    #expect(entry.schema == "main")
    #expect(entry.table == "items")
    #expect(entry.statementCount == 4)
    #expect(!entry.notCaptured)
    #expect(entry.notRewindableReason == RewindPlan.generatedKeyReason)
    #expect(entry.columns.map(\.name) == ["id", "label", "score"])
    let rows = try fixture.store.rows(entryID: entry.id)
    #expect(
      rows == [
        RewindRow(
          operation: .delete, primaryKey: ["id": "2"],
          before: ["id": "2", "label": "NULL", "score": "2.25"], after: nil),
        RewindRow(
          operation: .update, primaryKey: ["id": "1"],
          before: ["id": "1", "label": "'a'", "score": "1.5"],
          after: ["id": "1", "label": "'z'", "score": "1.5"]),
        RewindRow(
          operation: .insert, primaryKey: ["id": "10"], before: nil,
          after: ["id": "10", "label": "'n'", "score": "NULL"]),
        RewindRow(operation: .insert, primaryKey: [:], before: nil, after: nil),
      ])
    let stored = try await fixture.manager.executeInternal(
      "SELECT id, label FROM items ORDER BY id")
    #expect(stored.rows.count == 4)
    #expect(stored.rows.first == [.int(1), .string("z")])
  }

  @Test("A capture read that fails is rolled back to its savepoint and the edit still applies")
  func failedCaptureKeepsTheEdit() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.tearDown() }
    let target = try await fixture.target()
    let edit = try CellUpdateStatement.make(
      qualifiedName: target.qualifiedName, columnName: "label", newValue: "w",
      primaryKeyColumns: ["id"], rowData: ["id": .int(3)], dialect: .sqlite)
    // A table that is not there: the capture read fails on the server. (A missing column would
    // not: SQLite reads an unknown double-quoted name as a string literal.)
    let gone = EditTarget(
      qualifiedName: "\"main\".\"gone\"", tableID: target.tableID, primaryKeyColumns: ["id"],
      connectionEpoch: target.connectionEpoch, schema: "main", name: "gone")
    let plan = RewindPlan(
      target: gone, columns: [RewindColumn(name: "id", typeName: "INTEGER")], editKind: .inline,
      steps: [.init(operation: .update, keyBefore: [.int(3)], keyAfter: [.int(3)])])

    let rows = try await fixture.manager.executeGatedUpdate(
      edit, policy: open, connectionEpoch: target.connectionEpoch, rewind: plan)

    #expect(rows == 1)
    let stored = try await fixture.manager.executeInternal("SELECT label FROM items WHERE id = 3")
    #expect(stored.rows == [[.string("w")]])
    #expect(fixture.factory.statements.contains("ROLLBACK TO SAVEPOINT dblore_capture"))
    await fixture.recorder.flushed()
    let entry = try #require(try fixture.store.entries(connectionKey: nil).first)
    #expect(entry.notCaptured)
    #expect(entry.state == .committed)
    #expect(
      try fixture.store.rows(entryID: entry.id) == [
        RewindRow(operation: .update, primaryKey: [:], before: nil, after: nil)
      ])
  }

  @Test("A capture read lost with its transaction stops the edit and the batch before they run")
  func lostCaptureStopsTheWrite() async throws {
    func failingCapture(_ fixture: Fixture) async throws -> RewindPlan {
      try await fixture.lostCapturePlan(
        step: .init(operation: .update, keyBefore: [.int(1)], keyAfter: [.int(1)]))
    }

    let protected = try await Fixture.make(protectedMode: true)
    defer { protected.tearDown() }
    let target = try await protected.target()
    let edit = try CellUpdateStatement.make(
      qualifiedName: target.qualifiedName, columnName: "label", newValue: "w",
      primaryKeyColumns: ["id"], rowData: ["id": .int(1)], dialect: .sqlite)
    let plan = try await failingCapture(protected)
    await #expect(throws: (any Error).self) {
      _ = try await protected.manager.executeGatedUpdate(
        edit, policy: ProtectionPolicy(protectionLevel: .none),
        connectionEpoch: target.connectionEpoch, rewind: plan)
    }
    #expect(!protected.factory.statements.contains(edit.sql))
    #expect(await protected.manager.transactionStatus().state.isIdle)
    let label = try await protected.manager.executeInternal("SELECT label FROM items WHERE id = 1")
    #expect(label.rows == [[.string("a")]])
    await protected.recorder.flushed()
    #expect(try protected.store.count() == 0)

    let open = try await Fixture.make()
    defer { open.tearDown() }
    let update = BoundStatement(
      sql: "UPDATE \"main\".\"items\" SET \"label\" = ?1 WHERE \"id\" = ?2", values: ["z", "1"],
      expectedRows: 1)
    let batchPlan = try await failingCapture(open)
    await #expect(throws: (any Error).self) {
      _ = try await open.manager.executeGatedBatch(
        [update], policy: self.open, connectionEpoch: batchPlan.target.connectionEpoch,
        rewind: batchPlan)
    }
    #expect(!open.factory.statements.contains(update.sql))
    let stored = try await open.manager.executeInternal("SELECT label FROM items WHERE id = 1")
    #expect(stored.rows == [[.string("a")]])
    await open.recorder.flushed()
    #expect(try open.store.count() == 0)
  }

  @Test("A capture read lost after the write undoes it in every mode, without the read's error")
  func lostAfterReadUndoesTheWrite() async throws {
    // No read before the UPDATE: the read that fails comes after the write
    let step = RewindPlan.Step(operation: .update, keyBefore: nil, keyAfter: [.int(1)])
    // Protected, then the app's own transaction (Protected mode off)
    for protectedMode in [true, false] {
      let fixture = try await Fixture.make(protectedMode: protectedMode)
      defer { fixture.tearDown() }
      let target = try await fixture.target()
      let edit = try CellUpdateStatement.make(
        qualifiedName: target.qualifiedName, columnName: "label", newValue: "w",
        primaryKeyColumns: ["id"], rowData: ["id": .int(1)], dialect: .sqlite)
      let plan = try await fixture.lostCapturePlan(step: step)
      let error = await #expect(throws: DatabaseError.self) {
        _ = try await fixture.manager.executeGatedUpdate(
          edit, policy: ProtectionPolicy(protectionLevel: .none),
          connectionEpoch: target.connectionEpoch, rewind: plan)
      }
      try await fixture.expectUndone(edit.sql, error: error)
    }

    let fixture = try await Fixture.make()
    defer { fixture.tearDown() }
    let update = BoundStatement(
      sql: "UPDATE \"main\".\"items\" SET \"label\" = ?1 WHERE \"id\" = ?2", values: ["z", "1"],
      expectedRows: 1)
    let plan = try await fixture.lostCapturePlan(step: step)
    let error = await #expect(throws: DatabaseError.self) {
      _ = try await fixture.manager.executeGatedBatch(
        [update], policy: self.open, connectionEpoch: plan.target.connectionEpoch, rewind: plan)
    }
    try await fixture.expectUndone(update.sql, error: error)
  }

  @Test("A capture of a replaced connection reads nothing and records nothing, even committed")
  func replacedConnectionCapturesNothing() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.tearDown() }
    let target = try await fixture.target()
    let plan = RewindPlan(
      target: target, columns: [RewindColumn(name: "id", typeName: "INTEGER")],
      editKind: .inline,
      steps: [.init(operation: .update, keyBefore: [.int(1)], keyAfter: [.int(1)])])
    var capture = await fixture.manager.startRewindCapture(plan, statementCount: 1)
    #expect(capture != nil)
    try await fixture.manager.connect(config: fixture.config)
    fixture.factory.reset()

    try await fixture.manager.captureBefore(0, into: &capture)
    await fixture.manager.recordRewind(capture, committed: true)

    #expect(fixture.factory.statements.isEmpty)
    #expect(capture?.notCaptured == true)
    await fixture.recorder.flushed()
    #expect(try fixture.store.count() == 0)
  }

  // MARK: - 21.2 Lifecycle

  @Test("Under Protected mode an entry stays pending until Commit, and Rollback discards it")
  func protectedCommitAndRollback() async throws {
    let fixture = try await Fixture.make(protectedMode: true)
    defer { fixture.tearDown() }
    let target = try await fixture.target()

    try await fixture.inlineEdit(id: 1, label: "x", target: target)
    let first = try await fixture.newestEntry()
    #expect(first.state == .pending)
    #expect(await fixture.recorder.openEntryIDs() == [first.id])
    try await fixture.manager.commitAppTransaction(
      expectedGeneration: await fixture.manager.transactionStatus().generation)
    #expect(try await fixture.state(of: first.id) == .committed)
    #expect(await fixture.recorder.openEntryIDs().isEmpty)

    try await fixture.inlineEdit(id: 1, label: "y", target: target)
    let second = try await fixture.newestEntry()
    #expect(second.state == .pending)
    try await fixture.manager.rollbackAppTransaction()
    #expect(try await fixture.state(of: second.id) == .discarded)
    #expect(try await fixture.state(of: first.id) == .committed)
  }

  @Test("Inside the user's transaction an entry waits for the user's COMMIT or ROLLBACK")
  func userTransactionDecides() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.tearDown() }
    let target = try await fixture.target()

    _ = try await fixture.manager.execute(userSQL: "BEGIN", policy: open)
    try await fixture.inlineEdit(id: 1, label: "x", target: target)
    let first = try await fixture.newestEntry()
    #expect(first.state == .pending)
    _ = try await fixture.manager.execute(userSQL: "COMMIT", policy: open)
    #expect(try await fixture.state(of: first.id) == .committed)

    _ = try await fixture.manager.execute(userSQL: "BEGIN", policy: open)
    try await fixture.inlineEdit(id: 1, label: "y", target: target)
    let second = try await fixture.newestEntry()
    #expect(second.state == .pending)
    _ = try await fixture.manager.execute(userSQL: "ROLLBACK", policy: open)
    #expect(try await fixture.state(of: second.id) == .discarded)
  }

  @Test("A connection lost during Commit leaves the entry pending and no longer open")
  func lossDuringCommitLeavesPending() async throws {
    let fixture = try await Fixture.make(protectedMode: true)
    defer { fixture.tearDown() }
    let target = try await fixture.target()
    try await fixture.inlineEdit(id: 1, label: "x", target: target)
    let entry = try await fixture.newestEntry()
    let manager = fixture.manager
    let epoch = await manager.connectionEpoch
    await manager.setTransactionEndHook { _ in await manager.markSessionLost(epoch: epoch) }

    await #expect(throws: DatabaseError.self) {
      try await manager.commitAppTransaction(
        expectedGeneration: await manager.transactionStatus().generation)
    }

    #expect(try await fixture.state(of: entry.id) == .pending)
    #expect(await fixture.recorder.openEntryIDs().isEmpty)
  }

  @Test("A connection lost during the user's COMMIT leaves the entry pending")
  func lossDuringUserCommitLeavesPending() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.tearDown() }
    let target = try await fixture.target()
    _ = try await fixture.manager.execute(userSQL: "BEGIN", policy: open)
    try await fixture.inlineEdit(id: 1, label: "x", target: target)
    let entry = try await fixture.newestEntry()
    let manager = fixture.manager
    let epoch = await manager.connectionEpoch
    fixture.factory.intercept { sql in
      guard sql == "COMMIT" else { return }
      await manager.markSessionLost(epoch: epoch)
      throw InjectedFailure()
    }

    await #expect(throws: (any Error).self) {
      _ = try await manager.execute(userSQL: "COMMIT", policy: self.open)
    }

    #expect(try await fixture.state(of: entry.id) == .pending)
    #expect(await fixture.recorder.openEntryIDs().isEmpty)
  }

  @Test("A COMMIT failing without a server answer leaves the entry pending, a rejection discards")
  func failedCommitWithoutAnswer() async throws {
    // MySQL reports a lost connection later (close events), so the COMMIT error alone may come
    // after the server committed; an error the server answered (a deadlock) did not commit.
    // SQLite keeps the user's transaction open after a failed COMMIT (it can be retried); the
    // app's own COMMIT is followed by ROLLBACK.
    let rejected = MySQLSessionError(code: 1213, sqlState: "40001", message: "Deadlock found")
    let busy = SQLiteSessionError(extendedCode: 5, message: "database is locked")
    let cases: [(any Error & Sendable, user: RewindEntry.State, app: RewindEntry.State)] = [
      (MySQLSessionError.closed, .pending, .pending), (rejected, .discarded, .discarded),
      (busy, .pending, .discarded),
    ]
    for (failure, expected, expectedApp) in cases {
      let user = try await Fixture.make()
      defer { user.tearDown() }
      _ = try await user.manager.execute(userSQL: "BEGIN", policy: open)
      try await user.inlineEdit(id: 1, label: "x", target: try await user.target())
      let typed = try await user.newestEntry()
      user.factory.intercept { sql in
        if sql == "COMMIT" { throw failure }
      }
      await #expect(throws: (any Error).self) {
        _ = try await user.manager.execute(userSQL: "COMMIT", policy: self.open)
      }
      #expect(try await user.state(of: typed.id) == expected)
      #expect(await user.recorder.openEntryIDs().isEmpty)

      let app = try await Fixture.make(protectedMode: true)
      defer { app.tearDown() }
      try await app.inlineEdit(id: 1, label: "x", target: try await app.target())
      let reviewed = try await app.newestEntry()
      app.factory.intercept { sql in
        if sql == "COMMIT" { throw failure }
      }
      await #expect(throws: DatabaseError.self) {
        try await app.manager.commitAppTransaction(
          expectedGeneration: await app.manager.transactionStatus().generation)
      }
      #expect(try await app.state(of: reviewed.id) == expectedApp)
      #expect(await app.recorder.openEntryIDs().isEmpty)
    }
  }

  @Test("A capture read lost inside the user's transaction discards its earlier entries")
  func lostCaptureInUserTransactionDiscards() async throws {
    let step = RewindPlan.Step(operation: .update, keyBefore: [.int(1)], keyAfter: [.int(1)])
    let update = BoundStatement(
      sql: "UPDATE \"main\".\"items\" SET \"label\" = ?1 WHERE \"id\" = ?2", values: ["z", "1"],
      expectedRows: 1)
    for batch in [false, true] {
      let fixture = try await Fixture.make()
      defer { fixture.tearDown() }
      let target = try await fixture.target()
      _ = try await fixture.manager.execute(userSQL: "BEGIN", policy: open)
      try await fixture.inlineEdit(id: 2, label: "x", target: target)
      let earlier = try await fixture.newestEntry()
      let plan = try await fixture.lostCapturePlan(step: step)
      await #expect(throws: (any Error).self) {
        if batch {
          _ = try await fixture.manager.executeGatedBatch(
            [update], policy: self.open, connectionEpoch: target.connectionEpoch, rewind: plan)
        } else {
          _ = try await fixture.manager.executeGatedUpdate(
            try CellUpdateStatement.make(
              qualifiedName: target.qualifiedName, columnName: "label", newValue: "w",
              primaryKeyColumns: ["id"], rowData: ["id": .int(1)], dialect: .sqlite),
            policy: self.open, connectionEpoch: target.connectionEpoch, rewind: plan)
        }
      }
      #expect(try await fixture.state(of: earlier.id) == .discarded)
      #expect(await fixture.recorder.openEntryIDs().isEmpty)
      // The user's COMMIT (answered OK by MySQL, with no transaction left) changes nothing
      _ = try await fixture.manager.execute(userSQL: "COMMIT", policy: open)
      #expect(try await fixture.state(of: earlier.id) == .discarded)
    }
  }

  @Test("A MySQL deadlock on the edit inside the user's transaction discards its earlier entries")
  func deadlockInUserTransactionDiscards() async throws {
    let update = BoundStatement(
      sql: "UPDATE \"main\".\"items\" SET \"label\" = ?1 WHERE \"id\" = ?2", values: ["z", "1"],
      expectedRows: 1)
    // A lock wait timeout (1205) undoes the statement alone: the transaction goes on
    let deadlock = MySQLSessionError(code: 1213, sqlState: "40001", message: "Deadlock found")
    let timeout = MySQLSessionError(code: 1205, sqlState: "HY000", message: "Lock wait timeout")
    for (failure, batch) in [(deadlock, false), (deadlock, true), (timeout, false)] {
      let fixture = try await Fixture.make()
      defer { fixture.tearDown() }
      let target = try await fixture.target()
      _ = try await fixture.manager.execute(userSQL: "BEGIN", policy: open)
      try await fixture.inlineEdit(id: 2, label: "x", target: target)
      let earlier = try await fixture.newestEntry()
      fixture.factory.intercept { sql in
        if sql.hasPrefix("UPDATE") { throw failure }
      }
      await #expect(throws: (any Error).self) {
        if batch {
          _ = try await fixture.manager.executeGatedBatch(
            [update], policy: self.open, connectionEpoch: target.connectionEpoch, rewind: nil)
        } else {
          try await fixture.inlineEdit(id: 1, label: "w", target: target)
        }
      }
      guard failure == deadlock else {
        #expect(try await fixture.state(of: earlier.id) == .pending)
        #expect(await fixture.recorder.openEntryIDs() == [earlier.id])
        continue
      }
      #expect(try await fixture.state(of: earlier.id) == .discarded)
      #expect(await fixture.recorder.openEntryIDs().isEmpty)
      fixture.factory.intercept { _ in }
      _ = try await fixture.manager.execute(userSQL: "COMMIT", policy: open)
      #expect(try await fixture.state(of: earlier.id) == .discarded)
    }
  }

  @Test("MySQL BEGIN / START TRANSACTION commits the open transaction; other engines do not")
  func mysqlBeginCommitsOpenTransaction() throws {
    func classified(_ sql: String, _ dialect: SQLDialect) throws -> ClassifiedStatement {
      try #require(SQLStatementClassifier.classifyStatement(sql, dialect: dialect))
    }
    let rules = ProtectedTransactionRules.self
    for sql in ["BEGIN", "BEGIN WORK", "START TRANSACTION", "# note\nSTART TRANSACTION READ ONLY"] {
      #expect(rules.beginCommitsOpenTransaction(try classified(sql, .mysql), dialect: .mysql))
    }
    #expect(!rules.beginCommitsOpenTransaction(try classified("COMMIT", .mysql), dialect: .mysql))
    for dialect in [SQLDialect.postgresql, .sqlite] {
      #expect(
        !rules.beginCommitsOpenTransaction(try classified("BEGIN", dialect), dialect: dialect))
    }
  }

  @Test("A user COMMIT answered with a ROLLBACK tag discards the entry")
  func userCommitRolledBackDiscards() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.tearDown() }
    _ = try await fixture.manager.execute(userSQL: "BEGIN", policy: open)
    try await fixture.inlineEdit(id: 1, label: "x", target: try await fixture.target())
    let entry = try await fixture.newestEntry()
    // PostgreSQL answers a COMMIT of a transaction a failed statement aborted this way
    fixture.factory.rewrite("COMMIT", as: "ROLLBACK")

    _ = try await fixture.manager.execute(userSQL: "COMMIT", policy: open)

    #expect(try await fixture.state(of: entry.id) == .discarded)
    let label = try await fixture.manager.executeInternal("SELECT label FROM items WHERE id = 1")
    #expect(label.rows == [[.string("a")]])
  }

  @Test("A reconnect and a session loss discard the open entries")
  func reconnectAndLossDiscard() async throws {
    let fixture = try await Fixture.make(protectedMode: true)
    defer { fixture.tearDown() }
    try await fixture.inlineEdit(id: 1, label: "x", target: try await fixture.target())
    let replaced = try await fixture.newestEntry()
    #expect(replaced.state == .pending)
    // The old session is closed before the new one opens, so its write lock is gone
    try await fixture.manager.connect(config: fixture.config)
    #expect(try await fixture.state(of: replaced.id) == .discarded)

    try await fixture.inlineEdit(id: 1, label: "y", target: try await fixture.target())
    let lost = try await fixture.newestEntry()
    #expect(lost.state == .pending)
    await fixture.manager.markSessionLost(epoch: await fixture.manager.connectionEpoch)
    #expect(try await fixture.state(of: lost.id) == .discarded)
  }

  // MARK: - 21.3 Plans from the data viewer

  @Test("Data viewer staged and inline edits record entries, none once recording is off")
  func dataViewerEditsRecord() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.tearDown() }
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(cells: [], connectionConfig: fixture.config))
    viewModel.viewMode = .editor
    viewModel.connectionState = .connected
    viewModel.connectionManager = fixture.manager
    let suiteName = "RewindCaptureTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    viewModel.historySettings = AppSettings(defaults: suite)
    viewModel.dataViewer = DataViewerState(
      schema: "main", name: "items", orderColumns: ["id"], databaseType: .sqlite)
    await viewModel.loadDataViewerPage()

    #expect(viewModel.stageEdit(row: 0, column: "label", value: .string("z")) == nil)
    #expect(viewModel.stageInsert(values: ["id": .int(10), "label": .string("n")]) == nil)
    await viewModel.commitStaged()
    #expect(viewModel.dataViewer?.changeSet == nil)

    let result = try #require(viewModel.editorResult)
    let label = try #require(result.columns.firstIndex { $0.name == "label" })
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      viewModel.onStatementsExecuted = {
        viewModel.onStatementsExecuted = nil
        continuation.resume()
      }
      viewModel.handleStagedGridCellEdit(row: 1, column: label, newValue: "w", result: result)
    }

    await fixture.recorder.flushed()
    let entries = try fixture.store.entries(connectionKey: nil)
    #expect(entries.map(\.editKind) == [.inline, .staged])
    #expect(entries.allSatisfy { $0.state == .committed && !$0.notCaptured })
    let staged = try fixture.store.rows(entryID: entries[1].id)
    #expect(staged.map(\.operation) == [.update, .insert])
    #expect(staged.last?.after?["label"] == .some("'n'"))
    let inline = try fixture.store.rows(entryID: entries[0].id)
    #expect(inline.first?.before?["label"] == .some("NULL"))
    #expect(inline.first?.after?["label"] == .some("'w'"))

    viewModel.historySettings.rewindEnabled = false
    #expect(viewModel.stageEdit(row: 0, column: "label", value: .string("off")) == nil)
    await viewModel.commitStaged()
    await fixture.recorder.flushed()
    #expect(try fixture.store.count() == 2)
  }

  @Test("No plan for an engine without Data Rewind, or a target without its table name")
  func noPlanOutsideKeyedSQLTargets() {
    let target = EditTarget(
      qualifiedName: "\"main\".\"items\"", tableID: .sqlite(schema: "main", table: "items"),
      primaryKeyColumns: ["id"], schema: "main", name: "items")
    let steps = [RewindPlan.Step(operation: .delete, keyBefore: [.int(1)], keyAfter: nil)]
    for engine in [DatabaseType.duckdb, .mongodb] {
      #expect(
        RewindPlan.make(
          target: target, resultColumns: Self.columns, editKind: .staged, steps: steps,
          engine: engine, enabled: true) == nil)
    }
    let unnamed = EditTarget(
      qualifiedName: target.qualifiedName, tableID: target.tableID, primaryKeyColumns: ["id"])
    #expect(
      RewindPlan.make(
        target: unnamed, resultColumns: Self.columns, editKind: .staged, steps: steps,
        engine: .sqlite, enabled: true) == nil)
  }
}

// MARK: - Fixture

/// A temporary `items (id INTEGER PRIMARY KEY, label TEXT, score REAL)` file with rows
/// (1, 'a', 1.5), (2, NULL, 2.25), (3, NULL, NULL), a connected manager whose session records
/// every statement it is given, and a temporary rewind store.
@MainActor
private struct Fixture {
  let databaseURL: URL
  let storeURL: URL
  let config: ConnectionConfig
  let factory: RecordingSessionFactory
  let manager: DatabaseConnectionManager
  let store: RewindStore
  let recorder: RewindRecorder

  static func make(protectedMode: Bool = false) async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
    let databaseURL = directory.appendingPathComponent("dblore-rewind-\(UUID().uuidString).sqlite")
    let storeURL = directory.appendingPathComponent(
      "dblore-rewind-store-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: databaseURL)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT, score REAL)")
    try handle.execute(
      "INSERT INTO items VALUES (1, 'a', 1.5), (2, NULL, 2.25), (3, NULL, NULL)")
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: databaseURL.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: protectedMode)
    let factory = RecordingSessionFactory()
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)
    let store = try RewindStore(url: storeURL)
    let recorder = RewindRecorder(store: store)
    await manager.setRewindRecorder(recorder)
    return Fixture(
      databaseURL: databaseURL, storeURL: storeURL, config: config, factory: factory,
      manager: manager, store: store, recorder: recorder)
  }

  /// The edit target of `items` on the current connection
  func target() async throws -> EditTarget {
    let table = try #require(
      try await manager.fetchEditTable(
        tableName: "main.items", tableID: .sqlite(schema: "main", table: "items")))
    return EditTarget(
      qualifiedName: table.qualifiedName, tableID: table.resolvedTableRef,
      primaryKeyColumns: table.primaryKeyColumns, connectionEpoch: table.connectionEpoch,
      schema: table.schema, name: table.name)
  }

  /// One inline edit of `label` with its plan, through the gate
  func inlineEdit(id: Int, label: String, target: EditTarget) async throws {
    let edit = try CellUpdateStatement.make(
      qualifiedName: target.qualifiedName, columnName: "label", newValue: label,
      primaryKeyColumns: ["id"], rowData: ["id": .int(id)], dialect: .sqlite)
    let plan = try #require(
      RewindPlan.make(
        target: target,
        resultColumns: [
          ColumnInfo(name: "id", type: "INTEGER"), .init(name: "label", type: "TEXT"),
        ],
        editKind: .inline,
        steps: [
          RewindPlan.inlineStep(
            assignments: [(column: "label", value: label)], primaryKeyColumns: ["id"],
            rowData: ["id": .int(id)])
        ].compactMap { $0 },
        engine: .sqlite, enabled: true))
    _ = try await manager.executeGatedUpdate(
      edit, policy: ProtectionPolicy(protectionLevel: .none),
      connectionEpoch: target.connectionEpoch, rewind: plan)
  }

  /// A plan whose capture read fails (table `gone`) and whose `ROLLBACK TO SAVEPOINT` fails
  /// too: the transaction went with the read (MySQL rolls it back whole on a deadlock).
  func lostCapturePlan(step: RewindPlan.Step) async throws -> RewindPlan {
    let target = try await target()
    factory.intercept { sql in
      if sql == "ROLLBACK TO SAVEPOINT dblore_capture" { throw InjectedFailure() }
    }
    let gone = EditTarget(
      qualifiedName: "\"main\".\"gone\"", tableID: target.tableID, primaryKeyColumns: ["id"],
      connectionEpoch: target.connectionEpoch, schema: "main", name: "gone")
    return RewindPlan(
      target: gone, columns: [RewindColumn(name: "id", typeName: "INTEGER")], editKind: .inline,
      steps: [step])
  }

  /// `sql` ran and was undone: row 1 unchanged, no transaction left, nothing recorded, and
  /// `error` tells the transaction was lost, not the read's own error (table `gone`).
  func expectUndone(_ sql: String, error: DatabaseError?) async throws {
    #expect(factory.statements.contains(sql))
    let message = error?.localizedDescription ?? ""
    #expect(message.contains("transaction"))
    #expect(!message.contains("gone"))
    #expect(await manager.transactionStatus().state.isIdle)
    let label = try await manager.executeInternal("SELECT label FROM items WHERE id = 1")
    #expect(label.rows == [[.string("a")]])
    await recorder.flushed()
    #expect(try store.count() == 0)
  }

  func newestEntry() async throws -> RewindEntry {
    await recorder.flushed()
    return try #require(try store.entries(connectionKey: nil).first)
  }

  func state(of id: Int64) async throws -> RewindEntry.State? {
    await recorder.flushed()
    return try store.entries(connectionKey: nil).first { $0.id == id }?.state
  }

  func tearDown() {
    let manager = manager
    let urls = [databaseURL, storeURL]
    Task {
      await manager.disconnect()
      for url in urls {
        for suffix in ["", "-wal", "-shm", "-journal"] {
          try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
      }
    }
  }
}

/// Real SQLite sessions that note every statement they are given, in order.
private final class RecordingSessionFactory: DatabaseSessionFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [String] = []
  private var interceptor: (@Sendable (String) async throws -> Void)?
  private var rewrites: [String: String] = [:]

  var statements: [String] { lock.withLock { sent } }

  func reset() { lock.withLock { sent = [] } }

  /// Runs before each statement is sent; throwing fails it without sending it
  func intercept(_ body: @escaping @Sendable (String) async throws -> Void) {
    lock.withLock { interceptor = body }
  }

  /// `sql` is sent as `replacement` (noted as `sql`), its result answered as the server would
  func rewrite(_ sql: String, as replacement: String) {
    lock.withLock { rewrites[sql] = replacement }
  }

  /// Notes `sql` and returns the text to send
  func note(_ sql: String) async throws -> String {
    let (body, text) = lock.withLock {
      sent.append(sql)
      return (interceptor, rewrites[sql] ?? sql)
    }
    try await body?(sql)
    return text
  }

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    RecordingSession(inner: SQLiteSession(config: config), factory: self)
  }
}

private final class RecordingSession: DatabaseSession, @unchecked Sendable {
  let inner: any DatabaseSession
  let factory: RecordingSessionFactory

  init(inner: any DatabaseSession, factory: RecordingSessionFactory) {
    self.inner = inner
    self.factory = factory
  }

  var capabilities: DatabaseCapabilities { inner.capabilities }
  var closeEvents: AsyncStream<SessionCloseReason> { inner.closeEvents }

  func open() async throws { try await inner.open() }
  func close() async { await inner.close() }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    try await inner.query(factory.note(sql), binds: binds)
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    try await inner.command(factory.note(sql), binds: binds)
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    try await inner.openCursor(factory.note(sql), binds: binds)
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    try await inner.fetch(cursor, maxRows: maxRows)
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    try await inner.closeCursor(cursor)
  }

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    try await inner.applySessionSettings(
      statementTimeoutSeconds: statementTimeoutSeconds, lockTimeoutSeconds: lockTimeoutSeconds,
      idleTimeoutSeconds: idleTimeoutSeconds)
  }

  func interrupt() async { await inner.interrupt() }

  func formatError(_ error: Error) -> String { inner.formatError(error) }
}

private struct InjectedFailure: Error {}
