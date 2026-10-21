// StructureEditorModelTests.swift
// StructureEditorModel: loads the table off the main actor, explains up front why a table cannot
// be edited, stages changes into an exact DDL preview, asks Safe Mode before sending, applies
// through the gate and reports applied / pending / inside-transaction / partial outcomes.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("StructureEditorModelTests")
struct StructureEditorModelTests {
  private typealias Column = TableStructure.Column

  // MARK: - Fixtures

  private static func column(
    _ ordinal: Int, _ name: String, _ type: String, nullable: Bool = true,
    default defaultExpression: String? = nil
  ) -> Column {
    Column(
      ordinal: ordinal, name: name, dataType: type, isNullable: nullable,
      defaultExpression: defaultExpression, identity: nil, generated: nil, comment: nil,
      columnType: nil, extra: nil, characterSet: nil, collation: nil)
  }

  private static let items = TableStructure(
    tableID: .postgresql(oid: 1), schema: "public", name: "items",
    columns: [column(1, "id", "integer", nullable: false), column(2, "name", "text")],
    indexes: [
      TableStructure.Index(
        name: "items_name", keys: [.column("name")], isUnique: false, isPrimary: false,
        method: "btree", isPartial: false, predicate: nil)
    ],
    constraints: [
      TableStructure.Constraint(name: "items_pkey", kind: .primaryKey, columns: ["id"])
    ])

  private static let mysql80 = MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36)
  private static let open = ProtectionPolicy(protectionLevel: .none)

  private static func newColumn(_ name: String, _ type: String) -> StructureChange.NewColumn {
    StructureChange.NewColumn(name: name, type: type, isNullable: true, defaultExpression: nil)
  }

  private func makeModel(
    _ database: FakeStructureDatabase, type: DatabaseType = .postgresql,
    policy: ProtectionPolicy = open,
    commitStyle: @escaping @MainActor () -> CommitStyle = { .immediate },
    history: HistoryLog = HistoryLog()
  ) -> StructureEditorModel {
    StructureEditorModel(
      schema: "public", table: "items",
      context: StructureEditorContext(
        database: database, databaseType: type, policy: policy, commitStyle: commitStyle,
        caller: nil, recordHistory: { history.outcomes += $0 }))
  }

  // MARK: - Load

  @Test("Load fills the structure; a failed load shows the error; a paused catalog says why")
  func loadStates() async throws {
    let model = makeModel(FakeStructureDatabase(structure: Self.items))
    #expect(model.loadState == .idle)
    await model.load()
    #expect(model.loadState == .loaded)
    #expect(model.structure == Self.items)
    #expect(model.workingColumns.map(\.column.name) == ["id", "name"])
    #expect(model.disabledReason == nil)

    let failing = FakeStructureDatabase(structure: Self.items)
    await failing.setLoadError(DatabaseError.queryFailed("boom", 0))
    let failed = makeModel(failing)
    await failed.load()
    guard case .failed(let message) = failed.loadState else {
      Issue.record("Expected a failed load")
      return
    }
    #expect(message.contains("boom"))

    let paused = FakeStructureDatabase(structure: Self.items)
    await paused.setLoadError(DatabaseError.metadataPausedDuringTransaction)
    let pausedModel = makeModel(paused)
    await pausedModel.load()
    #expect(pausedModel.loadState == .failed(StructureEditorModel.pausedMessage))
  }

  // MARK: - Disabled reasons

  @Test("DuckDB, protected connections and unsafe MySQL states are read-only up front")
  func disabledReasons() async throws {
    let cases: [(DatabaseType, ProtectionPolicy, StructureEditorConnectionState, String)] = [
      (.duckdb, Self.open, .init(), "DuckDB tables can only be viewed"),
      (
        .postgresql, ProtectionPolicy(protectionLevel: .readOnly), .init(),
        StructureEditorModel.readOnlyMessage
      ),
      (
        .postgresql, ProtectionPolicy(protectionLevel: .schemaOnly), .init(),
        StructureEditorModel.schemaOnlyMessage
      ),
      (.mysql, Self.open, .init(), StructureEditorModel.mysqlUnknownServerMessage),
      (
        .mysql, ProtectionPolicy(protectionLevel: .none, protectedMode: true),
        .init(mysqlServerInfo: Self.mysql80), StructureEditorModel.mysqlReviewMessage
      ),
      (
        .mysql, Self.open, .init(mysqlServerInfo: Self.mysql80, transactionOpen: true),
        StructureEditorModel.mysqlTransactionMessage
      ),
    ]
    for (type, policy, state, reason) in cases {
      let database = FakeStructureDatabase(structure: Self.items, state: state)
      let model = makeModel(database, type: type, policy: policy)
      await model.load()
      #expect(model.isReadOnly, "\(type)")
      #expect(model.disabledReason == reason, "\(type)")
      model.addColumn(Self.newColumn("note", "text"))
      #expect(model.changes.isEmpty, "\(type)")
      #expect(!model.canApply, "\(type)")
    }

    let ready = FakeStructureDatabase(
      structure: Self.items, state: .init(mysqlServerInfo: Self.mysql80))
    let mysql = makeModel(ready, type: .mysql)
    await mysql.load()
    #expect(mysql.disabledReason == nil)
  }

  // MARK: - Staging and preview

  @Test("Staged edits rebuild the exact preview; a second edit replaces; undo and discard")
  func stagingBuildsPreview() async throws {
    let model = makeModel(FakeStructureDatabase(structure: Self.items))
    await model.load()

    model.addColumn(Self.newColumn("note", "text"))
    model.setType("bigint", for: .loaded("id"))
    model.setType("numeric", for: .loaded("id"))
    model.rename(.loaded("name"), to: "title")
    model.dropIndex(named: "items_name")
    model.setDefault("'x'", for: .added("note"))

    #expect(
      model.previewStatements == [
        "DROP INDEX \"public\".\"items_name\"",
        "ALTER TABLE \"public\".\"items\" ADD COLUMN \"note\" text DEFAULT 'x', "
          + "ALTER COLUMN \"id\" TYPE numeric",
        "ALTER TABLE \"public\".\"items\" RENAME COLUMN \"name\" TO \"title\"",
      ])
    #expect(model.previewError == nil)
    #expect(model.canApply)
    #expect(model.changes.count == 4)

    let columns = model.workingColumns
    #expect(columns.map(\.column.name) == ["id", "title", "note"])
    #expect(columns.map(\.state) == [.edited, .edited, .added])
    #expect(columns[0].editedFields == [.type])
    #expect(columns[0].column.dataType == "numeric")
    #expect(columns[1].editedFields == [.name])
    #expect(columns[2].column.defaultExpression == "'x'")
    #expect(model.workingIndexes.map(\.state) == [.dropped])

    // Setting the loaded value back drops the change
    model.setType("integer", for: .loaded("id"))
    #expect(!model.changes.contains(.alterColumnType(column: "id", type: "numeric")))

    model.dropColumn(.loaded("name"))
    #expect(model.changes.contains(.dropColumn(column: "name")))
    #expect(!model.changes.contains(.renameColumn(column: "name", newName: "title")))
    #expect(model.workingColumns.first { $0.loadedName == "name" }?.state == .dropped)

    model.rename(.loaded("id"), to: "key")
    model.revertColumn(named: "id")
    #expect(model.workingColumns.first { $0.loadedName == "id" }?.state == .unchanged)

    let count = model.changes.count
    model.undoChange(at: count - 1)
    #expect(model.changes.count == count - 1)
    #expect(model.workingColumns.first { $0.loadedName == "name" }?.state == .unchanged)

    model.discardChanges()
    #expect(model.changes.isEmpty)
    #expect(model.previewStatements.isEmpty)
    #expect(!model.canApply)
  }

  @Test("Dropping a column also drops the indexes and constraints staged on it")
  func dropColumnDropsStagedKeys() async throws {
    let model = makeModel(FakeStructureDatabase(structure: Self.items))
    await model.load()
    model.addColumn(Self.newColumn("note", "text"))
    model.addIndex(
      StructureChange.NewIndex(name: "by_name", columns: ["name"], isUnique: false, method: nil))
    model.addIndex(
      StructureChange.NewIndex(name: "by_id", columns: ["id"], isUnique: true, method: nil))
    model.addIndex(
      StructureChange.NewIndex(name: "by_note", columns: ["note"], isUnique: false, method: nil))
    model.addConstraint(
      TableStructure.Constraint(name: "name_unique", kind: .unique, columns: ["name", "id"]))

    model.dropColumn(.loaded("name"))
    model.dropColumn(.added("note"))

    #expect(
      model.changes == [
        .createIndex(
          StructureChange.NewIndex(name: "by_id", columns: ["id"], isUnique: true, method: nil)),
        .dropColumn(column: "name"),
      ])
    #expect(model.previewError == nil)
  }

  @Test("An added row keeps its row id when renamed; undo and drop keep the others")
  func addedRowIDsAreStable() async throws {
    let model = makeModel(FakeStructureDatabase(structure: Self.items))
    await model.load()
    model.addColumn(Self.newColumn("a", "text"))
    model.addColumn(Self.newColumn("b", "text"))
    model.addIndex(
      StructureChange.NewIndex(name: "by_a", columns: ["a", "id"], isUnique: false, method: nil))
    let before = model.workingColumns.map(\.rowID)
    #expect(Set(before).count == 4)

    model.rename(.added("a"), to: "a2")
    #expect(model.workingColumns.map(\.rowID) == before)
    // An index staged on the added column follows the rename
    #expect(model.workingIndexes.last?.index.keys == [.column("a2"), .column("id")])

    model.dropColumn(.added("a2"))
    #expect(model.workingColumns.map(\.rowID) == [before[0], before[1], before[3]])

    model.addColumn(Self.newColumn("c", "text"))
    model.undoChange(at: 1)
    #expect(model.workingColumns.map(\.column.name) == ["id", "name", "b"])
    #expect(model.workingColumns.last?.rowID == before[3])
  }

  @Test("Constraint rows keep distinct ids when an earlier row is dropped or removed")
  func constraintRowIDsAreStable() async throws {
    let model = makeModel(FakeStructureDatabase(structure: Self.items))
    await model.load()
    let first = TableStructure.Constraint(name: "name_unique", kind: .unique, columns: ["name"])
    let second = TableStructure.Constraint(name: "id_check", kind: .check("id > 0"), columns: [])
    model.addConstraint(first)
    model.addConstraint(second)
    let before = model.workingConstraints.map(\.id)
    #expect(Set(before).count == 3)

    // Staging a drop on the loaded row keeps its id; removing an added row keeps the others
    model.dropConstraint(Self.items.constraints[0])
    model.dropConstraint(first)
    #expect(model.workingConstraints.map(\.state) == [.dropped, .added])
    #expect(model.workingConstraints.map(\.id) == [before[0], before[2]])
  }

  @Test("Index rows keep their ids when an earlier row is dropped, removed or its column renamed")
  func indexRowIDsAreStable() async throws {
    let model = makeModel(FakeStructureDatabase(structure: Self.items))
    await model.load()
    model.addColumn(Self.newColumn("a", "text"))
    model.addIndex(
      StructureChange.NewIndex(name: "by_id", columns: ["id"], isUnique: true, method: nil))
    model.addIndex(
      StructureChange.NewIndex(name: "by_a", columns: ["a"], isUnique: false, method: "hash"))
    let before = model.workingIndexes.map(\.id)
    #expect(Set(before).count == 3)

    // Renaming the column an added index uses keeps its id
    model.rename(.added("a"), to: "a2")
    #expect(model.workingIndexes.map(\.id) == before)

    model.dropIndex(named: "items_name")
    model.dropIndex(named: "by_id")
    #expect(model.workingIndexes.map(\.state) == [.dropped, .added])
    #expect(model.workingIndexes.map(\.id) == [before[0], before[2]])
    let kept = try #require(model.workingIndexes.last?.index)
    #expect(kept.name == "by_a")
    #expect(kept.keys == [.column("a2")])
    #expect(kept.method == "hash")
  }

  @Test("A builder error shows inline and disables Apply")
  func builderErrorDisablesApply() async throws {
    let model = makeModel(FakeStructureDatabase(structure: Self.items))
    await model.load()
    model.setDefault("1; DROP TABLE items", for: .loaded("name"))

    #expect(model.previewError != nil)
    #expect(model.previewStatements.isEmpty)
    #expect(!model.canApply)
  }

  // MARK: - Safe Mode

  @Test("Safe Mode asks first; Cancel sends nothing; Confirm sends the exact preview")
  func safeModeConfirmation() async throws {
    let database = FakeStructureDatabase(structure: Self.items)
    let model = makeModel(database, commitStyle: { .password })
    await model.load()
    model.addColumn(Self.newColumn("note", "text"))
    let preview = model.previewStatements

    await model.apply()
    #expect(model.pendingConfirmation?.count == 1)
    #expect(model.confirmationRequiresPassword)
    #expect(await database.sent.isEmpty)

    model.cancelConfirmation()
    #expect(model.pendingConfirmation == nil)
    #expect(await database.sent.isEmpty)

    await model.apply()
    await model.confirmApply()
    #expect(await database.sent == [preview])
    #expect(model.pendingConfirmation == nil)
  }

  @Test("An edit, Discard, Reload or Cancel after Safe Mode asked sends nothing")
  func changesAfterConfirmationSendNothing() async throws {
    let database = FakeStructureDatabase(structure: Self.items)
    let model = makeModel(database, commitStyle: { .password })
    await model.load()
    model.addColumn(Self.newColumn("note", "text"))

    await model.apply()
    model.setType("bigint", for: .loaded("id"))
    #expect(model.pendingConfirmation == nil)
    await model.confirmApply()

    await model.apply()
    model.discardChanges()
    await model.confirmApply()

    model.addColumn(Self.newColumn("note", "text"))
    await model.apply()
    await model.load()
    #expect(model.pendingConfirmation == nil)
    await model.confirmApply()

    await model.apply()
    model.cancelConfirmation()
    await model.confirmApply()

    #expect(await database.sent.isEmpty)
  }

  @Test("Safe Mode follows the commit style at Apply, not the one at open")
  func commitStyleReadAtApply() async throws {
    let database = FakeStructureDatabase(structure: Self.items)
    var style = CommitStyle.immediate
    let model = makeModel(database, commitStyle: { style })
    await model.load()
    model.addColumn(Self.newColumn("note", "text"))
    style = .password

    await model.apply()
    #expect(model.pendingConfirmation != nil)
    #expect(model.confirmationRequiresPassword)
    #expect(await database.sent.isEmpty)
  }

  @Test("Nothing can be staged while a change is being sent")
  func stagingRefusedWhileApplying() async throws {
    let database = FakeStructureDatabase(structure: Self.items)
    await database.holdApply()
    let model = makeModel(database)
    await model.load()
    model.addColumn(Self.newColumn("note", "text"))
    let applying = Task { await model.apply() }
    while !model.isApplying { await Task.yield() }

    let staged = model.changes
    model.addColumn(Self.newColumn("other", "text"))
    model.dropColumn(.loaded("name"))
    model.discardChanges()
    #expect(model.changes == staged)

    await database.releaseApply()
    await applying.value
    #expect(model.resultMessage == StructureEditorModel.appliedMessage)
  }

  // MARK: - Apply outcomes

  @Test("SQLite apply reloads, clears the staged changes, records History and notifies")
  func sqliteApplyReloadsAndRecordsHistory() async throws {
    for historyEnabled in [true, false] {
      let fixture = try await SQLiteFixture.make(historyEnabled: historyEnabled)
      defer { fixture.remove() }
      let model = try #require(
        StructureEditorModel(schema: "main", table: "t", tab: fixture.tab))
      var applied = 0
      model.onApplied = { applied += 1 }
      await model.load()
      #expect(model.workingColumns.map(\.column.name) == ["id"])

      model.addColumn(Self.newColumn("note", "TEXT"))
      #expect(model.previewStatements == ["ALTER TABLE \"main\".\"t\" ADD COLUMN \"note\" TEXT"])
      await model.apply()

      #expect(model.applyError == nil)
      #expect(model.resultMessage == StructureEditorModel.appliedMessage)
      #expect(model.changes.isEmpty)
      #expect(model.workingColumns.map(\.column.name) == ["id", "note"])
      #expect(applied == 1)
      let entries = await fixture.recorder.entries
      if historyEnabled {
        #expect(entries.map(\.sql) == ["ALTER TABLE \"main\".\"t\" ADD COLUMN \"note\" TEXT"])
        #expect(entries.map(\.source) == [.structure])
      } else {
        #expect(entries.isEmpty)
      }
      await fixture.manager.disconnect()
    }
  }

  @Test("Pending (Protected) does not reload; inside the user's transaction reloads")
  func pendingAndInsideTransactionMessages() async throws {
    let pendingDatabase = FakeStructureDatabase(structure: Self.items)
    await pendingDatabase.setOutcome(pending: true, insideUserTransaction: true)
    let pending = makeModel(pendingDatabase)
    await pending.load()
    pending.addColumn(Self.newColumn("note", "text"))
    await pending.apply()
    #expect(pending.resultMessage == StructureEditorModel.pendingMessage)
    #expect(pending.changes.isEmpty)
    #expect(await pendingDatabase.loads == 1)
    #expect(pending.disabledReason == StructureEditorModel.pausedMessage)

    let insideDatabase = FakeStructureDatabase(structure: Self.items)
    await insideDatabase.setOutcome(pending: false, insideUserTransaction: true)
    let inside = makeModel(insideDatabase)
    await inside.load()
    inside.addColumn(Self.newColumn("note", "text"))
    await inside.apply()
    #expect(inside.resultMessage == StructureEditorModel.insideTransactionMessage)
    #expect(await insideDatabase.loads == 2)
    #expect(inside.disabledReason == nil)
  }

  @Test("Apply outcomes toast by kind; a preview error toasts only when it is new")
  func toasts() async throws {
    func applyToasts(
      pending: Bool = false, inside: Bool = false, error: Error? = nil,
      type: DatabaseType = .postgresql
    ) async -> [ToastMessage.ToastType] {
      let database = FakeStructureDatabase(
        structure: Self.items,
        state: type == .mysql ? .init(mysqlServerInfo: Self.mysql80) : .init())
      await database.setOutcome(pending: pending, insideUserTransaction: inside)
      if let error { await database.setApplyError(error) }
      let model = makeModel(database, type: type)
      var toasts: [ToastMessage.ToastType] = []
      model.toastPresenter = { toasts.append($1) }
      await model.load()
      model.addColumn(Self.newColumn("note", "text"))
      await model.apply()
      return toasts
    }
    #expect(await applyToasts() == [.success])
    #expect(await applyToasts(pending: true, inside: true) == [.warning])
    #expect(await applyToasts(inside: true) == [.warning])
    #expect(await applyToasts(error: DatabaseError.queryFailed("boom", 0)) == [.error])
    let partial = DatabaseError.schemaChangePartiallyApplied(applied: 1, total: 2, reason: "boom")
    #expect(await applyToasts(error: partial, type: .mysql) == [.warning])

    let model = makeModel(FakeStructureDatabase(structure: Self.items))
    var messages: [String] = []
    model.toastPresenter = { message, _ in messages.append(message) }
    await model.load()
    model.setDefault("1; DROP TABLE items", for: .loaded("name"))
    model.addColumn(Self.newColumn("note", "text"))
    #expect(messages.count == 1)
    model.setDefault("2; DROP TABLE items", for: .loaded("name"))
    #expect(messages.count == 2)
    #expect(messages[0] != messages[1])
  }

  @Test("MySQL partial failure reports applied k of n, clears staged and reloads")
  func mysqlPartialFailure() async throws {
    let database = FakeStructureDatabase(
      structure: Self.items, state: .init(mysqlServerInfo: Self.mysql80))
    await database.setApplyError(
      DatabaseError.schemaChangePartiallyApplied(applied: 1, total: 2, reason: "boom"))
    let history = HistoryLog()
    let model = makeModel(database, type: .mysql, history: history)
    var applied = 0
    model.onApplied = { applied += 1 }
    await model.load()
    model.addColumn(Self.newColumn("note", "text"))
    await model.apply()

    #expect(model.applyError?.contains("Applied 1 of 2") == true)
    #expect(model.applyPartiallyFailed)
    #expect(model.changes.isEmpty)
    #expect(await database.loads == 2)
    #expect(applied == 1)
    #expect(history.outcomes.map(\.status) == [.error])
  }

  // MARK: - Table rename, comment and drop

  @Test("Table name and comment stage at most one change each; the loaded value removes it")
  func tableNameAndCommentStageOnce() async throws {
    var commented = Self.items
    commented.comment = "stock"
    let model = makeModel(FakeStructureDatabase(structure: commented))
    await model.load()

    model.renameTable(to: "goods")
    model.renameTable(to: "wares")
    model.setTableComment("all")
    model.setTableComment("every item")
    model.rename(.loaded("name"), to: "title")
    #expect(
      model.changes == [
        .renameTable(newName: "wares"), .setTableComment("every item"),
        .renameColumn(column: "name", newName: "title"),
      ])
    #expect(model.workingTableName == "wares")
    #expect(model.workingComment == "every item")
    // The table rename is sent last
    #expect(model.previewStatements.last == "ALTER TABLE \"public\".\"items\" RENAME TO \"wares\"")

    model.renameTable(to: "items")
    model.setTableComment("stock")
    #expect(model.changes == [.renameColumn(column: "name", newName: "title")])
    #expect(model.workingTableName == "items")
    #expect(model.workingComment == "stock")

    // A blank comment removes it
    model.setTableComment("  ")
    #expect(model.changes.last == .setTableComment(nil))
  }

  @Test("Drop Table needs the exact name, sends the drop DDL and reports the dropped table")
  func dropTableNeedsTypedName() async throws {
    let database = FakeStructureDatabase(structure: Self.items)
    let history = HistoryLog()
    let model = makeModel(database, commitStyle: { .confirm }, history: history)
    var reported: [(StructureEditorModel.TableChange, Bool)] = []
    model.onTableChange = { reported.append(($0, $1)) }
    await model.load()
    #expect(model.dropStatements == ["DROP TABLE \"public\".\"items\""])

    model.requestDropTable()
    #expect(model.isConfirmingDrop)
    await model.confirmDropTable(typedName: "item")
    #expect(model.pendingConfirmation == nil)
    await model.confirmDropTable(typedName: "items")
    #expect(!model.isConfirmingDrop)
    // Safe Mode (confirm style) still asks before anything is sent
    #expect(model.confirmsDrop)
    #expect(model.pendingConfirmation?.count == 1)
    #expect(await database.sent.isEmpty)
    await model.confirmApply()

    #expect(await database.sent == [["DROP TABLE \"public\".\"items\""]])
    #expect(reported.map(\.0) == [.dropped(schema: "public", table: "items")])
    #expect(reported.map(\.1) == [false])
    #expect(history.outcomes.map(\.status) == [.success])
    // The table is gone: no reload
    #expect(await database.loads == 1)
  }

  @Test("A rename retargets the editor; a pending one waits for the commit")
  func renameRetargetsEditor() async throws {
    let database = FakeStructureDatabase(structure: Self.items)
    let model = makeModel(database)
    var reported: [(StructureEditorModel.TableChange, Bool)] = []
    model.onTableChange = { reported.append(($0, $1)) }
    await model.load()
    model.renameTable(to: "goods")
    await model.apply()
    #expect(model.table == "goods")
    #expect(await database.loadedTables == ["items", "goods"])
    #expect(reported.map(\.0) == [.renamed(schema: "public", from: "items", to: "goods")])
    #expect(reported.map(\.1) == [false])

    let pendingDatabase = FakeStructureDatabase(structure: Self.items)
    await pendingDatabase.setOutcome(pending: true, insideUserTransaction: false)
    let pending = makeModel(pendingDatabase)
    var pendingReported: [Bool] = []
    pending.onTableChange = { pendingReported.append($1) }
    await pending.load()
    pending.renameTable(to: "goods")
    await pending.apply()
    #expect(pending.table == "items")
    #expect(pending.resultMessage == StructureEditorModel.pendingMessage)
    #expect(pendingReported == [true])
    pending.tableRenamed(to: "goods")
    await pending.transactionEnded()
    #expect(await pendingDatabase.loadedTables == ["items", "goods"])
  }

  @Test("A refused or rolled-back change keeps the staged changes and shows the error")
  func failureKeepsStagedChanges() async throws {
    let database = FakeStructureDatabase(structure: Self.items)
    await database.setApplyError(
      DatabaseError.batchStatementFailed(
        index: 0, sqlPrefix: "ALTER", reason: "boom", rolledBack: true))
    let model = makeModel(database)
    var applied = 0
    model.onApplied = { applied += 1 }
    await model.load()
    model.addColumn(Self.newColumn("note", "text"))
    await model.apply()

    #expect(model.applyError?.contains("boom") == true)
    #expect(model.changes.count == 1)
    #expect(!model.applyPartiallyFailed)
    #expect(await database.loads == 1)
    #expect(applied == 0)
  }
}

// MARK: - Test doubles

/// Outcomes passed to the model's history seam
@MainActor
private final class HistoryLog {
  var outcomes: [QueryHistoryOutcome] = []
}

private actor FakeStructureDatabase: StructureEditorDatabase {
  private let structure: TableStructure
  private let state: StructureEditorConnectionState
  private var loadError: Error?
  private var applyError: Error?
  private var pending = false
  private var holdsApply = false
  private var applyGate: CheckedContinuation<Void, Never>?
  private var insideUserTransaction = false
  private(set) var loads = 0
  private(set) var loadedTables: [String] = []
  private(set) var sent: [[String]] = []

  init(structure: TableStructure, state: StructureEditorConnectionState = .init()) {
    self.structure = structure
    self.state = state
  }

  func setLoadError(_ error: Error) { loadError = error }
  func setApplyError(_ error: Error) { applyError = error }
  /// The next apply waits for `releaseApply()`
  func holdApply() { holdsApply = true }
  func releaseApply() async {
    while applyGate == nil { await Task.yield() }
    applyGate?.resume()
    applyGate = nil
    holdsApply = false
  }
  func setOutcome(pending: Bool, insideUserTransaction: Bool) {
    self.pending = pending
    self.insideUserTransaction = insideUserTransaction
  }

  func fetchTableStructure(schema: String, table: String) async throws -> TableStructure {
    loads += 1
    loadedTables.append(table)
    if let loadError { throw loadError }
    return structure
  }

  func structureEditorState() async -> StructureEditorConnectionState { state }

  func executeGatedSchemaChange(
    _ statements: [String], policy: ProtectionPolicy, connectionEpoch: UInt64, caller: UUID?
  ) async throws -> SchemaChangeResult {
    if holdsApply { await withCheckedContinuation { applyGate = $0 } }
    sent.append(statements)
    if let applyError { throw applyError }
    return SchemaChangeResult(
      statements: statements, pending: pending, insideUserTransaction: insideUserTransaction,
      duration: 0)
  }
}

private actor StructureHistoryRecorder: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}

/// A real SQLite file behind a tab, as the sidebar entry point wires it
@MainActor
private struct SQLiteFixture {
  let manager: DatabaseConnectionManager
  let tab: NotebookViewModel
  let recorder: StructureHistoryRecorder
  let url: URL
  let suiteName: String

  static func make(historyEnabled: Bool) async throws -> SQLiteFixture {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-structure-editor-\(UUID().uuidString).sqlite")
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    _ = try await manager.executeInternal("CREATE TABLE t (id INTEGER PRIMARY KEY)")

    let suiteName = "StructureEditorModelTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = historyEnabled
    let recorder = StructureHistoryRecorder()
    let tab = NotebookViewModel()
    tab.notebook.connectionConfig = config
    tab.connectionManager = manager
    tab.historyRecorder = recorder
    tab.historySettings = settings
    return SQLiteFixture(
      manager: manager, tab: tab, recorder: recorder, url: url, suiteName: suiteName)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}
