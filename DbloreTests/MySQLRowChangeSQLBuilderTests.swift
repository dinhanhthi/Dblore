// MySQLRowChangeSQLBuilderTests.swift
// MySQL staged edits and inline cell saves: backtick quoting, `?` binds, no `UPDATE ONLY`, no
// statement without a primary key, `() VALUES ()` for an empty insert, MySQL bind text for
// booleans, dates and bytes (`UNHEX(?)`), unchanged-value UPDATEs skipped, and the row check
// that tells a same-value UPDATE (0 affected: CLIENT_FOUND_ROWS is off) from a deleted row.
// BIGINT / BIGINT UNSIGNED / DECIMAL keys bound as text hit exactly their row (no double
// comparison above 2^53).
// Server cases run on MySQL 8.4 (3307) and MariaDB 11.4 (3308), opt-in (`.requiresMySQL`).
// Tables use the `Mrc_` prefix.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MySQLRowChangeSQLBuilderTests {
  typealias Server = MySQLSessionTests.Server

  private static let database = TestMySQLDatabase.database

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  // MARK: - Builder (no server)

  @Test("Statements quote with backticks, bind with ?, and never use ONLY")
  func mysqlStatements() throws {
    let editTarget = target(updateOnly: true)
    var set = RowChangeSet(target: editTarget)
    set.stageDelete(row: RowChangeSet.RowKey(values: [.int(1)]))
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(2)]), column: "na`me", value: .string("b"),
      original: .string("a"))
    set.stageInsert(values: ["id": .int(3), "na`me": .string("c")])

    let statements = RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns, dialect: .mysql)
    #expect(
      statements.map(\.sql) == [
        "DELETE FROM `db`.`t` WHERE `id` = ?",
        "UPDATE `db`.`t` SET `na``me` = ? WHERE `id` = ?",
        "INSERT INTO `db`.`t` (`id`, `na``me`) VALUES (?, ?)",
      ])
    #expect(statements.map(\.values) == [["1"], ["b", "2"], ["3", "c"]])
    #expect(statements.allSatisfy { $0.expectedRows == 1 })
    #expect(
      RowChangeSQLBuilder.previewText(
        for: set, target: editTarget, columns: columns, dialect: .mysql
      )
      .contains("UPDATE `db`.`t` SET `na``me` = 'b' WHERE `id` = 2;"))
  }

  @Test("Only an UPDATE carries the row check, with the key binds")
  func updateCarriesRowCheck() throws {
    let editTarget = target(primaryKeyColumns: ["id", "na`me"])
    var set = RowChangeSet(target: editTarget)
    let key = RowChangeSet.RowKey(values: [.int(2), .string("k")])
    try set.stageEdit(row: key, column: "v", value: .int(5), original: .int(4))
    set.stageDelete(row: RowChangeSet.RowKey(values: [.int(1), .string("j")]))
    set.stageInsert(values: ["v": .int(1)])
    let tableColumns = columns + [ColumnInfo(name: "v", type: "INT")]

    let statements = RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: tableColumns, dialect: .mysql)
    #expect(statements.count == 3)
    #expect(statements[0].rowCheck == nil)
    #expect(
      statements[1].rowCheck
        == RowExistenceCheck(
          sql: "SELECT 1 FROM `db`.`t` WHERE `id` = ? AND `na``me` = ? FOR UPDATE",
          values: ["2", "k"]))
    #expect(statements[2].rowCheck == nil)

    // PostgreSQL reports matched rows: no check.
    let postgres = RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: tableColumns, dialect: .postgresql)
    #expect(postgres.allSatisfy { $0.rowCheck == nil })
  }

  @Test("An empty insert is () VALUES ()")
  func emptyInsert() {
    let editTarget = target()
    var set = RowChangeSet(target: editTarget)
    set.stageInsert(values: [:])
    let statements = RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns, dialect: .mysql)
    #expect(statements.map(\.sql) == ["INSERT INTO `db`.`t` () VALUES ()"])
    #expect(statements.first?.values == [])
  }

  @Test("A column whose bind text equals the loaded value is not updated")
  func unchangedValueIsSkipped() throws {
    let editTarget = target()
    let tableColumns = columns + [ColumnInfo(name: "v", type: "INT")]
    var set = RowChangeSet(target: editTarget)
    let key = RowChangeSet.RowKey(values: [.int(1)])
    // Typed text "5" for the loaded integer 5: a different CellValue, the same bind text.
    try set.stageEdit(row: key, column: "v", value: .string("5"), original: .int(5))
    #expect(
      RowChangeSQLBuilder.statements(
        for: set, target: editTarget, columns: tableColumns, dialect: .mysql
      ).isEmpty)

    try set.stageEdit(row: key, column: "na`me", value: .string("z"), original: .string("a"))
    let statements = RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: tableColumns, dialect: .mysql)
    #expect(statements.map(\.sql) == ["UPDATE `db`.`t` SET `na``me` = ? WHERE `id` = ?"])
    #expect(statements.first?.values == ["z", "1"])
  }

  @Test("Without a primary key no UPDATE or DELETE is built")
  func noPrimaryKeyNoStatement() throws {
    let editTarget = target(primaryKeyColumns: [])
    var edit = RowChangeSet(target: editTarget)
    try edit.stageEdit(
      row: RowChangeSet.RowKey(values: []), column: "na`me", value: .string("b"),
      original: .string("a"))
    var delete = RowChangeSet(target: editTarget)
    delete.stageDelete(row: RowChangeSet.RowKey(values: []))
    for set in [edit, delete] {
      for dialect in [SQLDialect.mysql, .postgresql] {
        let statements = RowChangeSQLBuilder.statements(
          for: set, target: editTarget, columns: columns, dialect: dialect)
        #expect(statements.isEmpty, "\(dialect)")
      }
    }
  }

  @Test("Booleans, dates and bytes bind as MySQL text; bytes through UNHEX")
  func mysqlBindText() {
    let editTarget = target(primaryKeyColumns: ["id"])
    var set = RowChangeSet(target: editTarget)
    let date = Date(timeIntervalSince1970: 1_704_164_645.5)  // 2024-01-02 03:04:05.5 UTC
    set.stageDelete(row: RowChangeSet.RowKey(values: [.data(Data([0xDE, 0xAD]))]))
    set.stageInsert(values: ["id": .date(date), "na`me": .bool(true)])

    let statements = RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns, dialect: .mysql)
    #expect(statements.map(\.sql).first == "DELETE FROM `db`.`t` WHERE `id` = UNHEX(?)")
    #expect(statements.map(\.values) == [["dead"], ["2024-01-02 03:04:05.500000", "1"]])
  }

  @Test("A name with a NUL falls back to backticks, never a double-quoted string")
  func nulNameUsesBackticks() throws {
    let editTarget = target()
    var set = RowChangeSet(target: editTarget)
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(1)]), column: "a\0b", value: .string("x"),
      original: .string("y"))
    let statements = RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: [ColumnInfo(name: "a\0b", type: "TEXT")],
      dialect: .mysql)
    #expect(statements.map(\.sql) == ["UPDATE `db`.`t` SET `a\0b` = ? WHERE `id` = ?"])
    #expect(CellUpdateStatement.quoteIdentifier("a\0`b", dialect: .mysql) == "`a\0``b`")
  }

  // MARK: - Inline cell update, integer key, lookup, empty result (no server)

  @Test("An inline cell UPDATE is backtick-quoted with ? binds and a row check")
  func inlineCellUpdate() throws {
    let statement = try CellUpdateStatement.make(
      qualifiedName: "`db`.`t`", columnName: "na`me", newValue: "x",
      primaryKeyColumns: ["id", "b"],
      rowData: ["id": .int(7), "b": .data(Data([0x01, 0xFF]))], updateOnly: true,
      dialect: .mysql)
    #expect(statement.sql == "UPDATE `db`.`t` SET `na``me` = ? WHERE `id` = ? AND `b` = UNHEX(?)")
    #expect(statement.values == ["x", "7", "01ff"])
    #expect(
      statement.rowCheck
        == RowExistenceCheck(
          sql: "SELECT 1 FROM `db`.`t` WHERE `id` = ? AND `b` = UNHEX(?) FOR UPDATE",
          values: ["7", "01ff"]))

    // The PostgreSQL name grammar is not a MySQL name.
    #expect(throws: DatabaseError.self) {
      try CellUpdateStatement.make(
        qualifiedName: "public.t", columnName: "a", newValue: "1", primaryKeyColumns: ["id"],
        rowData: ["id": .int(1)], dialect: .mysql)
    }
    let postgres = try CellUpdateStatement.make(
      qualifiedName: "public.t", columnName: "a", newValue: "1", primaryKeyColumns: ["id"],
      rowData: ["id": .int(1)], updateOnly: true)
    #expect(postgres.sql == #"UPDATE ONLY public.t SET "a" = $1 WHERE "id" = $2"#)
    #expect(postgres.rowCheck == nil)
  }

  @Test("The integer-key lookup reads AUTO_INCREMENT from COLUMNS.EXTRA")
  func integerKeyLookupSQL() throws {
    let sql = try #require(
      StagedIntegerKey.lookupSQL(schema: "db", table: "t`x", column: "id", dialect: .mysql))
    #expect(
      sql
        == "SELECT (c.COLUMN_DEFAULT IS NOT NULL OR c.EXTRA LIKE '%auto_increment%') AS has_default, "
        + "(SELECT MAX(`id`) FROM `db`.`t``x`) AS max_id FROM information_schema.COLUMNS AS c "
        + "WHERE c.TABLE_SCHEMA = 'db' AND c.TABLE_NAME = 't`x' AND c.COLUMN_NAME = 'id'")
  }

  @Test("The referenced-row lookup binds bytes through UNHEX")
  func lookupBindsBytes() {
    let key = ForeignKey(
      constraintName: "fk", sourceSchema: "db", sourceTable: "child", sourceColumns: ["p"],
      targetSchema: "db", targetTable: "parent", targetColumns: ["b"])
    let query = ForeignKeyLookup.lookupSQL(
      for: key, values: ["p": .data(Data([0xAB]))], dialect: .mysql)
    #expect(query?.sql == "SELECT * FROM `db`.`parent` WHERE `b` = UNHEX(:fk1) LIMIT 2")
    #expect(query?.parameters == ["fk1": .text("ab")])
  }

  // MARK: - Server

  @Test(
    "Staged insert (AUTO_INCREMENT key), update and delete commit", .requiresMySQL,
    arguments: [Server.mysql, .mariadb], [false, true])
  func stagedCommit(server: Server, protectedMode: Bool) async throws {
    try await withViewer(server, protectedMode: protectedMode) { viewModel, manager, observer in
      #expect(await viewModel.addStagedRow() == nil)
      let inserts = try #require(viewModel.dataViewer?.changeSet?.inserts)
      // The server fills an AUTO_INCREMENT key, so + Row leaves it unset.
      #expect(inserts.count == 1 && inserts[0].values["id"] == nil)
      let loaded = try #require(viewModel.editorResult?.rows.count)
      #expect(viewModel.stageEdit(row: loaded, column: "name", value: .string("c")) == nil)
      #expect(
        viewModel.stageEdit(row: try rowIndex(1, viewModel), column: "name", value: .string("A"))
          == nil)
      #expect(viewModel.stageDelete(rows: [try rowIndex(2, viewModel)]) == nil)

      await viewModel.commitStaged()

      #expect(viewModel.dataViewer?.changeSet == nil)
      let expected: [[CellValue]] = [[.int(1), .string("A")], [.int(3), .string("c")]]
      if protectedMode {
        #expect(try await rows(observer) == Self.seedRows)
        let status = await manager.transactionStatus()
        #expect(!status.state.isIdle)
        try await manager.commitAppTransaction(expectedGeneration: status.generation)
      }
      #expect(try await rows(observer) == expected)
    }
  }

  @Test(
    "A same-value UPDATE (0 affected) is not a conflict", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func sameValueUpdateSucceeds(server: Server) async throws {
    try await withViewer(server, protectedMode: false) { viewModel, _, observer in
      #expect(
        viewModel.stageEdit(row: try rowIndex(1, viewModel), column: "name", value: .string("z"))
          == nil)
      // Another connection writes the same value first: the UPDATE changes nothing.
      _ = try await observer.executeInternal("UPDATE Mrc_Items SET name = 'z' WHERE id = 1")

      await viewModel.commitStaged()

      #expect(viewModel.dataViewer?.changeSet == nil)
      #expect(try await rows(observer) == [[.int(1), .string("z")], [.int(2), .string("b")]])
    }
  }

  @Test(
    "Commit with only unchanged values sends nothing and clears the staged set", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func unchangedOnlyCommitClears(server: Server) async throws {
    try await withViewer(
      server, protectedMode: false,
      ddl: "CREATE TABLE Mrc_Items (id INT PRIMARY KEY, name VARCHAR(20), n INT)",
      seed: "INSERT INTO Mrc_Items VALUES (1, 'a', 5), (2, 'b', 6)"
    ) { viewModel, _, observer in
      // Typed "5" over the loaded integer 5: staged, then skipped by the builder.
      let row = try rowIndex(1, viewModel)
      #expect(viewModel.stageEdit(row: row, column: "n", value: .string("5")) == nil)
      #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)

      await viewModel.commitStaged()

      #expect(viewModel.dataViewer?.changeSet == nil)
      let stored = try await rows(observer)
      #expect(stored == Self.seedRows)
    }
  }

  @Test(
    "A row deleted by another connection is a conflict", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func deletedRowConflicts(server: Server) async throws {
    try await withViewer(server, protectedMode: false) { viewModel, _, observer in
      #expect(
        viewModel.stageEdit(row: try rowIndex(1, viewModel), column: "name", value: .string("z"))
          == nil)
      #expect(
        viewModel.stageEdit(row: try rowIndex(2, viewModel), column: "name", value: .string("y"))
          == nil)
      _ = try await observer.executeInternal("DELETE FROM Mrc_Items WHERE id = 1")

      await viewModel.commitStaged()

      // The batch is rolled back and stays staged.
      #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)
      #expect(try await rows(observer) == [[.int(2), .string("b")]])
    }
  }

  @Test(
    "A table without a primary key refuses edits", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func noPrimaryKeyRefusesEdits(server: Server) async throws {
    try await withViewer(
      server, protectedMode: false, ddl: "CREATE TABLE Mrc_Items (id INT, name VARCHAR(20))"
    ) { viewModel, _, observer in
      let result = try #require(viewModel.editorResult)
      #expect(result.error == nil)
      #expect(result.editTarget == nil)
      #expect(
        viewModel.stageEdit(row: 0, column: "name", value: .string("z"))
          == NotebookViewModel.tableHasNoPrimaryKey)
      #expect(try await rows(observer) == Self.seedRows)
    }
  }

  @Test(
    "An inline cell edit saves; same value is not a mismatch; a deleted row is", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func inlineCellEdit(server: Server) async throws {
    try await withViewer(server, protectedMode: false) { viewModel, manager, observer in
      let sql = "SELECT * FROM Mrc_Items"
      let epoch = await manager.connectionEpoch
      let result = try await manager.execute(userSQL: sql, policy: Self.policy)
      let targets = await viewModel.resultTargets(
        for: sql, result: result, connectionManager: manager, epoch: epoch)
      let target = try #require(targets.editTarget)
      func update(_ id: Int, _ value: String) async throws -> Int {
        let statement = try CellUpdateStatement.make(
          qualifiedName: target.qualifiedName, columnName: "name", newValue: value,
          primaryKeyColumns: target.primaryKeyColumns, rowData: ["id": .int(id)],
          dialect: .mysql)
        return try await manager.executeGatedUpdate(
          statement, policy: Self.policy, connectionEpoch: target.connectionEpoch)
      }

      #expect(try await update(1, "x") == 1)
      #expect(try await update(1, "x") == 1)
      #expect(try await rows(observer) == [[.int(1), .string("x")], [.int(2), .string("b")]])
      _ = try await observer.executeInternal("DELETE FROM Mrc_Items WHERE id = 2")
      await #expect(throws: DatabaseError.self) { try await update(2, "y") }
    }
  }

  /// Keys whose neighbours share a double (2^63 - 1 / 2^63 - 2, 2^64 - 1 / 2^64 - 2, 2^53 + 1 /
  /// 2^53): every key is bound as text, so a double comparison would hit the neighbour.
  static let bigKeys: [(type: String, ids: [String])] = [
    (
      "BIGINT",
      ["9223372036854775807", "9223372036854775806", "9007199254740993", "9007199254740992"]
    ),
    (
      "BIGINT UNSIGNED",
      ["18446744073709551615", "18446744073709551614", "9007199254740993", "9007199254740992"]
    ),
    (
      "DECIMAL(20,2)",
      ["9007199254740993.02", "9007199254740993.01", "9007199254740993.00", "9007199254740992.00"]
    ),
  ]

  @Test(
    "Big integer and DECIMAL keys hit exactly their row: inline save, row check, staged edits",
    .requiresMySQL, arguments: [Server.mysql, .mariadb], 0..<3)
  func bigKeysHitTheirRow(server: Server, keyIndex: Int) async throws {
    let (type, ids) = Self.bigKeys[keyIndex]
    try await withViewer(
      server, protectedMode: false,
      ddl: "CREATE TABLE Mrc_Items (id \(type) PRIMARY KEY, name VARCHAR(20))",
      seed: "INSERT INTO Mrc_Items VALUES "
        + ids.enumerated().map { "(\($1), 'n\($0)')" }.joined(separator: ", ")
    ) { viewModel, manager, observer in
      @MainActor func stored() async throws -> [String: String] {
        let rows = try await observer.executeInternal(
          "SELECT CAST(id AS CHAR), name FROM Mrc_Items"
        ).rows
        var map: [String: String] = [:]
        for row in rows {
          if case .string(let id) = row[0], case .string(let name) = row[1] { map[id] = name }
        }
        return map
      }
      @MainActor func row(named name: String) throws -> Int {
        let result = try #require(viewModel.editorResult)
        let column = try #require(result.columns.firstIndex { $0.name == "name" })
        return try #require(result.rows.firstIndex { $0[column] == .string(name) })
      }
      @MainActor func statement(_ name: String, set value: String) throws -> CellUpdateStatement {
        let result = try #require(viewModel.editorResult)
        let target = try #require(result.editTarget)
        return try CellUpdateStatement.make(
          qualifiedName: target.qualifiedName, columnName: "name", newValue: value,
          primaryKeyColumns: target.primaryKeyColumns,
          rowData: CellResult.rowData(columns: result.columns, row: result.rows[row(named: name)]),
          updateOnly: target.updateOnly, dialect: .mysql)
      }
      #expect(try await stored().count == 4)

      // Inline save through the view model: only n1 changes.
      let target = try #require(viewModel.editorResult?.editTarget)
      await viewModel.sendInlineEdit(
        PendingInlineEdit(
          statement: try statement("n1", set: "inline"), columnName: "name",
          tableName: target.qualifiedName, cellId: nil, connectionManager: manager),
        target: target)
      #expect(
        try await stored() == [ids[0]: "n0", ids[1]: "inline", ids[2]: "n2", ids[3]: "n3"])

      // Same value: 0 affected, the row check finds that row (not a conflict).
      let current = try #require(viewModel.editorResult?.editTarget)
      #expect(
        try await manager.executeGatedUpdate(
          try statement("n2", set: "n2"), policy: Self.policy,
          connectionEpoch: current.connectionEpoch) == 1)

      // Staged edit of n2 and delete of n0.
      #expect(
        viewModel.stageEdit(row: try row(named: "n2"), column: "name", value: .string("s")) == nil)
      #expect(viewModel.stageDelete(rows: [try row(named: "n0")]) == nil)
      await viewModel.commitStaged()
      #expect(viewModel.dataViewer?.changeSet == nil)
      #expect(try await stored() == [ids[1]: "inline", ids[2]: "s", ids[3]: "n3"])

      // A row deleted elsewhere is a conflict; its double-equal neighbour stays untouched.
      let update = try statement("s", set: "late")
      _ = try await observer.executeInternal("DELETE FROM Mrc_Items WHERE id = \(ids[2])")
      await #expect(throws: DatabaseError.self) {
        try await manager.executeGatedUpdate(
          update, policy: Self.policy,
          connectionEpoch: try #require(viewModel.editorResult?.editTarget).connectionEpoch)
      }
      #expect(try await stored() == [ids[1]: "inline", ids[3]: "n3"])
    }
  }

  // MARK: - Helpers

  private static let policy = ProtectionPolicy(protectionLevel: .none)
  private static let seedRows: [[CellValue]] = [[.int(1), .string("a")], [.int(2), .string("b")]]

  private let columns = [
    ColumnInfo(name: "id", type: "INT"),
    ColumnInfo(name: "na`me", type: "VARCHAR"),
  ]

  private func target(
    primaryKeyColumns: [String] = ["id"], updateOnly: Bool = false
  )
    -> EditTarget
  {
    EditTarget(
      qualifiedName: "`db`.`t`", tableID: .mysql(database: "db", table: "t"),
      primaryKeyColumns: primaryKeyColumns, updateOnly: updateOnly)
  }

  /// A data viewer on `Mrc_Items` holding (1, 'a') and (2, 'b'), plus an unprotected observer.
  /// The table is dropped and both connections close on every path.
  private func withViewer(
    _ server: Server, protectedMode: Bool,
    ddl: String = "CREATE TABLE Mrc_Items (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(20))",
    seed: String = "INSERT INTO Mrc_Items VALUES (1, 'a'), (2, 'b')",
    _ body: (NotebookViewModel, DatabaseConnectionManager, DatabaseConnectionManager) async throws
      -> Void
  ) async throws {
    let observer = DatabaseConnectionManager()
    let manager = DatabaseConnectionManager()
    do {
      try await observer.connect(config: MySQLManagerTests.config(server))
      _ = try await observer.executeInternal("DROP TABLE IF EXISTS Mrc_Items")
      _ = try await observer.executeInternal(ddl)
      _ = try await observer.executeInternal(seed)
      var config = MySQLManagerTests.config(server, protectedMode: protectedMode)
      config.safeMode = .silent
      try await manager.connect(config: config)
      let viewModel = NotebookViewModel(
        notebook: DbloreNotebook(cells: [], connectionConfig: config))
      viewModel.viewMode = .editor
      viewModel.connectionState = .connected
      viewModel.connectionManager = manager
      viewModel.dataViewer = DataViewerState(
        schema: Self.database, name: "Mrc_Items", orderColumns: ["id"], databaseType: .mysql)
      await viewModel.loadDataViewerPage()
      try await body(viewModel, manager, observer)
    } catch {
      await Self.tearDown(manager, observer)
      throw error
    }
    await Self.tearDown(manager, observer)
  }

  private static func tearDown(
    _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager
  ) async {
    try? await manager.rollbackAppTransaction()
    await manager.disconnect()
    _ = try? await observer.executeInternal("DROP TABLE IF EXISTS Mrc_Items")
    await observer.disconnect()
  }

  private func rowIndex(_ id: Int, _ viewModel: NotebookViewModel) throws -> Int {
    let result = try #require(viewModel.editorResult)
    #expect(result.error == nil)
    let column = try #require(result.columns.firstIndex { $0.name == "id" })
    return try #require(result.rows.firstIndex { $0[column] == .int(id) })
  }

  private func rows(_ observer: DatabaseConnectionManager) async throws -> [[CellValue]] {
    try await observer.executeInternal("SELECT id, name FROM Mrc_Items ORDER BY id").rows
  }
}
