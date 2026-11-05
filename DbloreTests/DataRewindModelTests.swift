// DataRewindModelTests.swift
// The Data Rewind sheet's model on a temporary SQLite file: the entries of this connection with
// their states, Safe Mode before the rewind runs, History rows with source rewind, the D5
// lifecycle under Protected mode (rewound on Commit, still committed after Roll Back), the row
// named when a conflict rolls the rewind back, and consent before rows are skipped.

import Foundation
import Testing

@testable import Dblore

@Suite("DataRewindModelTests", .serialized)
@MainActor
struct DataRewindModelTests {
  @Test(
    "Lists this connection's entries with their state; only committed or unconfirmed ones can be picked"
  )
  func listsEntriesWithStates() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let committed = try await fixture.edit(id: 1, label: "z")
    let key = RewindEntry.connectionKey(for: fixture.config)
    let unconfirmed = try fixture.store.record(
      fixture.storedEntry(key: key, state: .pending), rows: [])
    let discarded = try fixture.store.record(
      fixture.storedEntry(key: key, state: .discarded), rows: [])
    _ = try fixture.store.record(fixture.storedEntry(key: "other", state: .committed), rows: [])
    let model = fixture.model(style: .immediate)

    await model.load()

    #expect(Set(model.items.map(\.id)) == [committed, unconfirmed, discarded])
    #expect(model.status(of: committed) == .committed)
    #expect(model.status(of: unconfirmed) == .unconfirmed)
    #expect(model.status(of: discarded) == .discarded)
    #expect(
      model.items.filter(\.status.isSelectable).map(\.id).sorted() == [committed, unconfirmed])
  }

  @Test(
    "Safe Mode asks first; the rewind then restores the row, marks it rewound and records History")
  func confirmThenRewind() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let id = try await fixture.edit(id: 1, label: "z")
    let model = fixture.model(style: .confirm)
    await model.load()

    await model.setSelection([id])
    let plan = try #require(model.plan)
    #expect(plan.statements.count == 1)
    await model.rewind()

    #expect(model.isConfirming)
    #expect(try await fixture.label(1) == .string("z"))

    await model.confirmRewind()

    #expect(model.errorMessage == nil)
    #expect(try await fixture.label(1) == .string("a"))
    await fixture.recorder.flushed()
    #expect(try fixture.store.entries(connectionKey: nil).first { $0.id == id }?.state == .rewound)
    #expect(model.status(of: id) == .rewound)
    let history = await fixture.history.entries
    #expect(history.map(\.source) == [.rewind])
    #expect(history.map(\.status) == [.success])
    #expect(history.first?.sql == plan.preview)
  }

  @Test("A masked column shows mask text in the preview and History; the rewind restores it")
  func maskedColumnPreviewKeepsRealRestore() async throws {
    let fixture = try await Fixture(maskRules: [ColumnMaskRule(pattern: "label", style: .full)])
    defer { fixture.remove() }
    let id = try await fixture.edit(id: 1, label: "z")
    let model = fixture.model(style: .immediate)
    await model.load()

    await model.setSelection([id])
    let plan = try #require(model.plan)
    #expect(plan.preview.contains(ColumnMaskRule.maskText))
    #expect(!plan.preview.contains("'a'"))
    #expect(!plan.preview.contains("z'"))
    let values = plan.statements.flatMap(\.values).compactMap(\.self)
    #expect(values.contains("a"))
    #expect(values.contains { $0.contains("z") })
    await model.rewind()

    #expect(model.errorMessage == nil)
    #expect(try await fixture.label(1) == .string("a"))
    // History keeps the masked preview commented out, so Insert or Copy never runs mask text
    let logged = try #require(await fixture.history.entries.first?.sql)
    #expect(logged.contains(ColumnMaskRule.maskText))
    #expect(
      logged.split(whereSeparator: \.isNewline).allSatisfy { $0.hasPrefix("-- ") })
    // An unmasked literal with a line break stays inside the comment
    var broken = plan
    broken.previews = ["UPDATE items SET note = 'x\nDELETE FROM items;' WHERE id = 1;"]
    #expect(
      DataRewindModel.historySQL(broken).split(whereSeparator: \.isNewline)
        .allSatisfy { $0.hasPrefix("-- ") })
  }

  @Test("A failed rewind of a masked column hides the server's text, keeping its code")
  func maskedFailureHidesServerText() throws {
    var plan = RewindInverse()
    plan.previews = [
      "INSERT INTO users (id, email) VALUES ('7', '\u{2022}\u{2022}\u{2022}\u{2022}');"
    ]
    plan.origins = [
      RewindInverse.Origin(
        entryID: 1, created: Date(), table: "users", operation: .delete, key: "id = 7")
    ]
    plan.masksValues = true
    let reasons = [
      (
        "ERROR 23505: duplicate key value violates unique constraint \"users_email_key\" "
          + "DETAIL: Key (email)=(a@b.com) already exists.", "23505"
      ),
      ("ERROR 1062 (23000): Duplicate entry 'a@b.com' for key 'users.email'", "1062"),
      ("UNIQUE constraint failed: a@b.com", nil),
    ]
    for (reason, code) in reasons {
      let message = DataRewindModel.failureMessage(
        DatabaseError.batchStatementFailed(
          index: 0, sqlPrefix: "INSERT INTO users", reason: reason, rolledBack: true),
        plan: plan)
      #expect(!message.contains("a@b.com"))
      #expect(message.contains("users row id = 7"))
      if let code { #expect(message.contains(code)) }
    }
    let other = DataRewindModel.failureMessage(
      NSError(
        domain: "test", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Key (email)=(a@b.com) already exists"]),
      plan: plan)
    #expect(!other.contains("a@b.com"))
    let lost = DataRewindModel.failureMessage(
      DatabaseError.connectionLost("Key (email)=(a@b.com) already exists"), plan: plan)
    #expect(!lost.contains("a@b.com"))
    // Dblore's own refusals keep their text
    let blocked = DataRewindModel.failureMessage(
      DatabaseError.blockedByProtection(
        statementIndex: 0, kind: .dml, reason: "Writes are not allowed on this connection"),
      plan: plan)
    #expect(blocked.contains("Writes are not allowed on this connection"))
    let cancelled = DataRewindModel.failureMessage(CancellationError(), plan: plan)
    #expect(cancelled == "Nothing was rewound: \(CancellationError().localizedDescription)")
    // A changed row says so: its reason holds counts, never values
    let changed = DataRewindModel.failureMessage(
      DatabaseError.batchStatementFailed(
        index: 0, sqlPrefix: "INSERT INTO users",
        reason: DatabaseConnectionManager.unexpectedRowCountReason + "1 row, affected 0",
        rolledBack: true),
      plan: plan)
    #expect(changed.contains("changed since the edit"))
  }

  @Test("Under Protected mode the rewind waits: rewound on Commit, still committed after Roll Back")
  func protectedRewindFollowsTheTransaction() async throws {
    let fixture = try await Fixture(protectedMode: true)
    defer { fixture.remove() }
    let first = try await fixture.edit(id: 1, label: "z")
    let second = try await fixture.edit(id: 2, label: "y")
    let model = fixture.model(style: .review)
    await model.load()

    await model.setSelection([first])
    await model.rewind()

    #expect(model.errorMessage == nil)
    #expect(model.status(of: first) == .rewindPending)
    await fixture.recorder.flushed()
    #expect(try fixture.state(of: first) == .committed)
    try await fixture.manager.commitAppTransaction(
      expectedGeneration: await fixture.manager.transactionStatus().generation)
    await fixture.recorder.flushed()
    #expect(try fixture.state(of: first) == .rewound)
    #expect(try await fixture.label(1) == .string("a"))

    await model.load()
    await model.setSelection([second])
    await model.rewind()
    try await fixture.manager.rollbackAppTransaction()
    await fixture.recorder.flushed()
    #expect(try fixture.state(of: second) == .committed)
    #expect(try await fixture.label(2) == .string("y"))
  }

  @Test("A row changed since the edit rolls the whole rewind back and is named")
  func conflictNamesTheRow() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let id = try await fixture.edit(id: 1, label: "z")
    _ = try await fixture.manager.executeInternal("UPDATE items SET label = 'other' WHERE id = 1")
    let model = fixture.model(style: .immediate)
    await model.load()

    await model.setSelection([id])
    await model.rewind()

    let message = try #require(model.errorMessage)
    #expect(message.contains("items"))
    #expect(message.contains("id = 1"))
    #expect(message.contains("changed since the edit"))
    #expect(try await fixture.label(1) == .string("other"))
    await fixture.recorder.flushed()
    #expect(try fixture.state(of: id) == .committed)
    #expect(await fixture.history.entries.map(\.status) == [.error])
  }

  @Test("A statement error other than a changed row is reported as such, with the row")
  func statementErrorIsNotAConflict() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    // Undoing a DELETE of a row that is still there: the re-insert breaks the primary key
    let id = try fixture.store.record(
      fixture.storedEntry(key: RewindEntry.connectionKey(for: fixture.config), state: .committed),
      rows: [
        RewindRow(
          operation: .delete, primaryKey: ["id": "1"],
          before: ["id": "1", "label": "'a'", "score": "1.5"], after: nil)
      ])
    let model = fixture.model(style: .immediate)
    await model.load()

    await model.setSelection([id])
    await model.rewind()

    let message = try #require(model.errorMessage)
    #expect(message.contains("items row id = 1"))
    #expect(message.contains("could not be rewound"))
    #expect(!message.contains("changed since the edit"))
  }

  @Test("Closing the sheet while the plan is read ends the planning and drops the late plan")
  func sheetClosedWhilePlanning() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let id = try await fixture.edit(id: 1, label: "z")
    let model = fixture.model(style: .immediate)
    await model.load()

    let planning = Task { await model.setSelection([id]) }
    for _ in 0..<1000 where model.activity != .planning { await Task.yield() }
    try #require(model.activity == .planning, "the planning did not start within 1000 yields")
    model.sheetDisappeared()

    #expect(model.activity == nil)
    await planning.value
    #expect(model.activity == nil)
    #expect(model.plan == nil)
  }

  @Test("Rows that were not captured are left out only once the user agrees")
  func skippedRowsNeedConsent() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    _ = try await fixture.manager.executeInternal("UPDATE items SET label = 'c' WHERE id = 2")
    var entry = fixture.storedEntry(
      key: RewindEntry.connectionKey(for: fixture.config), state: .committed)
    entry.notCaptured = true
    let id = try fixture.store.record(
      entry,
      rows: [
        RewindRow(operation: .update, primaryKey: [:], before: nil, after: nil),
        RewindRow(
          operation: .update, primaryKey: ["id": "2"],
          before: ["id": "2", "label": "'b'", "score": "NULL"],
          after: ["id": "2", "label": "'c'", "score": "NULL"]),
      ])
    let model = fixture.model(style: .immediate)
    await model.load()
    await model.setSelection([id])

    #expect(model.plan?.skipped.count == 1)
    #expect(!model.canRewind)
    await model.rewind()
    #expect(try await fixture.label(2) == .string("c"))

    model.skipConsent = true
    await model.rewind()
    #expect(model.errorMessage == nil)
    #expect(try await fixture.label(2) == .string("b"))
  }
}

private actor RewindHistoryRecorder: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}

@MainActor
private final class Fixture {
  let directory: URL
  let config: ConnectionConfig
  let manager = DatabaseConnectionManager()
  let store: RewindStore
  let recorder: RewindRecorder
  let viewModel: NotebookViewModel
  let history = RewindHistoryRecorder()

  /// `protectedMode` is the tab's: the edits themselves always commit at once
  /// `maskRules`: the connection's column mask rules (the saved rows have none)
  init(protectedMode: Bool = false, maskRules: [ColumnMaskRule] = []) async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-rewind-model-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var connected = ConnectionConfig(
      databaseType: .sqlite, database: directory.appendingPathComponent("db.sqlite").path,
      username: "", protectionLevel: .none, safeMode: .silent, protectedMode: false)
    connected.maskRules = maskRules
    await manager.setSavedMaskRules { _ in [] }
    try await manager.connect(config: connected)
    for statement in [
      "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT, score REAL)",
      "INSERT INTO items VALUES (1, 'a', 1.5), (2, 'b', NULL)",
    ] {
      _ = try await manager.executeInternal(statement)
    }
    store = try RewindStore(url: directory.appendingPathComponent("rewind.sqlite"))
    recorder = RewindRecorder(store: store)
    await manager.setRewindRecorder(recorder)
    var config = connected
    config.protectedMode = protectedMode
    self.config = config
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    viewModel.historyRecorder = history
    let suiteName = "DataRewindModelTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    suite.removePersistentDomain(forName: suiteName)
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = true
    viewModel.historySettings = settings
  }

  func model(style: CommitStyle) -> DataRewindModel {
    DataRewindModel(viewModel: viewModel, environment: .init(commitStyle: { _ in style }))
  }

  /// One committed inline edit of `label` with its Data Rewind plan; the new entry's id
  func edit(id: Int, label: String) async throws -> Int64 {
    let table = try #require(
      try await manager.fetchEditTable(
        tableName: "main.items", tableID: .sqlite(schema: "main", table: "items")))
    let target = EditTarget(
      qualifiedName: table.qualifiedName, tableID: table.resolvedTableRef,
      primaryKeyColumns: table.primaryKeyColumns, connectionEpoch: table.connectionEpoch,
      schema: table.schema, name: table.name)
    let edit = try CellUpdateStatement.make(
      qualifiedName: target.qualifiedName, columnName: "label", newValue: label,
      primaryKeyColumns: ["id"], rowData: ["id": .int(id)], dialect: .sqlite)
    let plan = RewindPlan.make(
      target: target,
      resultColumns: [
        ColumnInfo(name: "id", type: "INTEGER"), ColumnInfo(name: "label", type: "TEXT"),
        ColumnInfo(name: "score", type: "REAL"),
      ],
      editKind: .inline,
      steps: [
        RewindPlan.inlineStep(
          assignments: [(column: "label", value: label)], primaryKeyColumns: ["id"],
          rowData: ["id": .int(id)])
      ].compactMap { $0 },
      engine: .sqlite, enabled: true)
    _ = try await manager.executeGatedUpdate(
      edit, policy: ProtectionPolicy(protectionLevel: .none),
      connectionEpoch: target.connectionEpoch, rewind: plan)
    await recorder.flushed()
    return try #require(try store.entries(connectionKey: nil).map(\.id).max())
  }

  /// An entry of `items` written straight into the store
  func storedEntry(key: String, state: RewindEntry.State) -> RewindEntry {
    RewindEntry(
      id: 0, connectionKey: key, schema: "main", table: "items",
      qualifiedName: "\"main\".\"items\"", engine: .sqlite, created: Date(), state: state,
      editKind: .staged, statementCount: 1,
      columns: [
        RewindColumn(name: "id", typeName: "INTEGER"),
        RewindColumn(name: "label", typeName: "TEXT"),
        RewindColumn(name: "score", typeName: "REAL"),
      ],
      notCaptured: false, notRewindableReason: nil)
  }

  func state(of id: Int64) throws -> RewindEntry.State? {
    try store.entries(connectionKey: nil).first { $0.id == id }?.state
  }

  func label(_ id: Int) async throws -> CellValue? {
    try await manager.executeInternal("SELECT label FROM items WHERE id = \(id)").rows.first?
      .first
  }

  func remove() {
    let manager = manager
    let directory = directory
    Task {
      await manager.disconnect()
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
