// SchemaChangeGateTests.swift
// Structure editor DDL goes through `executeGatedSchemaChange`: every statement is re-classified
// and refused before anything is sent. PostgreSQL and SQLite apply atomically (or join the
// Protected mode transaction); MySQL runs statements one by one only with no transaction open.

import Foundation
import Testing

@testable import Dblore

@Suite("SchemaChangeGateTests")
struct SchemaChangeGateTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)

  private func connect(
    _ databaseType: DatabaseType = .postgresql
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSession) {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: databaseType, host: "fake", port: 1, database: "db", username: "u",
        password: "p", sslMode: .disable, protectionLevel: .none, safeMode: .silent,
        protectedMode: false))
    return (manager, try #require(factory.sessions.first))
  }

  private func connectSQLite() async throws -> (DatabaseConnectionManager, URL) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-schema-change-\(UUID().uuidString).sqlite")
    let manager = DatabaseConnectionManager()
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
        rememberConnection: false, protectionLevel: .none, safeMode: .silent,
        protectedMode: false))
    _ = try await manager.executeInternal("CREATE TABLE t (id INTEGER PRIMARY KEY)")
    return (manager, url)
  }

  private func columnNames(_ manager: DatabaseConnectionManager) async throws -> [String] {
    let result = try await manager.executeInternal("SELECT name FROM pragma_table_info('t')")
    return result.rows.compactMap {
      if case .string(let name) = $0.first { return name }
      return nil
    }
  }

  // MARK: - Pure refusal

  @Test("Only single DDL statements are accepted; DML, scripts and unknown text are refused")
  func shapeRefusals() {
    func refusal(_ statements: [String]) -> String? {
      DatabaseConnectionManager.schemaChangeRefusal(
        statements, databaseType: .postgresql, transactionOpen: false)
    }
    #expect(
      refusal([
        "ALTER TABLE \"t\" ADD COLUMN \"a\" integer", "CREATE INDEX \"i\" ON \"t\" (\"a\")",
      ]) == nil)
    #expect(refusal(["ALTER TABLE t ADD COLUMN a int", "DELETE FROM t"])?.contains("2") == true)
    #expect(refusal(["ALTER TABLE t ADD COLUMN a int; DROP TABLE t"]) != nil)
    #expect(refusal(["FROBNICATE t"]) != nil)
    #expect(refusal(["-- nothing"]) != nil)
  }

  @Test("DuckDB is refused; MySQL is refused while a transaction is open")
  func engineRefusals() {
    let alter = ["ALTER TABLE t ADD COLUMN a int"]
    #expect(
      DatabaseConnectionManager.schemaChangeRefusal(
        alter, databaseType: .duckdb, transactionOpen: false) != nil)
    #expect(
      DatabaseConnectionManager.schemaChangeRefusal(
        alter, databaseType: .mysql, transactionOpen: true) != nil)
    #expect(
      DatabaseConnectionManager.schemaChangeRefusal(
        alter, databaseType: .mysql, transactionOpen: false) == nil)
    #expect(
      DatabaseConnectionManager.schemaChangeRefusal(
        alter, databaseType: .postgresql, transactionOpen: true) == nil)
  }

  // MARK: - PostgreSQL

  @Test("PostgreSQL under Protected mode joins the app transaction: no COMMIT, changes pending")
  func postgresProtectedJoinsTransaction() async throws {
    let (manager, session) = try await connect()
    let ddl = ["ALTER TABLE \"t\" ADD COLUMN \"a\" integer", "CREATE INDEX \"i\" ON \"t\" (\"a\")"]
    let epoch = await manager.connectionEpoch

    let result = try await manager.executeGatedSchemaChange(
      ddl, policy: protected, connectionEpoch: epoch)

    #expect(result.pending)
    #expect(result.statements == ddl)
    #expect(
      session.statements == [
        "BEGIN", DatabaseConnectionManager.suspendIdleTimeoutSQL, "SAVEPOINT dblore_batch",
      ] + ddl + ["RELEASE SAVEPOINT dblore_batch"])
    #expect(await manager.transactionSnapshot().pending.count == 2)
  }

  @Test("PostgreSQL outside Protected mode is atomic: BEGIN..COMMIT, ROLLBACK on failure")
  func postgresUnprotectedAtomic() async throws {
    let (manager, session) = try await connect()
    let ddl = ["ALTER TABLE t ADD COLUMN a integer", "ALTER TABLE t ADD COLUMN b integer"]
    let epoch = await manager.connectionEpoch

    let result = try await manager.executeGatedSchemaChange(
      ddl, policy: open, connectionEpoch: epoch)
    #expect(!result.pending)
    #expect(!result.insideUserTransaction)
    #expect(session.statements == ["BEGIN"] + ddl + ["COMMIT"])

    session.failNextCommand(containing: "ADD COLUMN b")
    do {
      _ = try await manager.executeGatedSchemaChange(ddl, policy: open, connectionEpoch: epoch)
      Issue.record("Expected the second statement to fail")
    } catch DatabaseError.batchStatementFailed(let index, _, _, let rolledBack) {
      #expect(index == 1)
      #expect(rolledBack)
    }
    #expect(Array(session.statements.suffix(4)) == ["BEGIN"] + ddl + ["ROLLBACK"])
    #expect(await manager.transactionSnapshot().isIdle)
  }

  @Test("PostgreSQL inside the user's open transaction runs behind a savepoint and says so")
  func postgresInsideUserTransaction() async throws {
    let (manager, session) = try await connect()
    let ddl = ["ALTER TABLE t ADD COLUMN a integer"]
    let epoch = await manager.connectionEpoch
    _ = try await manager.execute(userSQL: "BEGIN", policy: open)
    let sent = session.statements.count

    let result = try await manager.executeGatedSchemaChange(
      ddl, policy: open, connectionEpoch: epoch)

    #expect(!result.pending)
    #expect(result.insideUserTransaction)
    #expect(
      Array(session.statements.dropFirst(sent))
        == ["SAVEPOINT dblore_batch"] + ddl + ["RELEASE SAVEPOINT dblore_batch"])
  }

  @Test("Protected mode adopts the user's open transaction: pending and inside it, no BEGIN")
  func postgresProtectedAdoptsUserTransaction() async throws {
    let (manager, session) = try await connect()
    let ddl = ["ALTER TABLE t ADD COLUMN a integer"]
    let epoch = await manager.connectionEpoch
    _ = try await manager.execute(userSQL: "BEGIN", policy: open)
    let sent = session.statements.count

    let result = try await manager.executeGatedSchemaChange(
      ddl, policy: protected, connectionEpoch: epoch)

    #expect(result.pending)
    #expect(result.insideUserTransaction)
    let gateSent = Array(session.statements.dropFirst(sent))
    #expect(!gateSent.contains("BEGIN"))
    #expect(
      Array(gateSent.suffix(ddl.count + 2))
        == ["SAVEPOINT dblore_batch"] + ddl + ["RELEASE SAVEPOINT dblore_batch"])
  }

  @Test("Read-only and schema-only connections refuse before anything is sent")
  func policyRefusesBeforeSend() async throws {
    let (manager, session) = try await connect()
    let epoch = await manager.connectionEpoch
    for level in [ConnectionProtectionLevel.readOnly, .schemaOnly] {
      let error = await #expect(throws: DatabaseError.self) {
        _ = try await manager.executeGatedSchemaChange(
          ["ALTER TABLE t ADD COLUMN a int"], policy: ProtectionPolicy(protectionLevel: level),
          connectionEpoch: epoch)
      }
      #expect(isBlockedByProtection(error), "\(level)")
    }
    let mixed = await #expect(throws: DatabaseError.self) {
      _ = try await manager.executeGatedSchemaChange(
        ["ALTER TABLE t ADD COLUMN a int", "UPDATE t SET a = 1"], policy: open,
        connectionEpoch: epoch)
    }
    #expect(refusalReason(mixed)?.contains("2") == true)
    let stale = await #expect(throws: DatabaseError.self) {
      _ = try await manager.executeGatedSchemaChange(
        ["ALTER TABLE t ADD COLUMN a int"], policy: open, connectionEpoch: epoch &+ 1)
    }
    #expect(refusalReason(stale)?.contains("connection changed") == true)
    #expect(session.statements.isEmpty)
  }

  private func isBlockedByProtection(_ error: DatabaseError?) -> Bool {
    if case .blockedByProtection = error { return true }
    return false
  }

  private func refusalReason(_ error: DatabaseError?) -> String? {
    if case .schemaChangeRefused(let reason) = error { return reason }
    return nil
  }

  // MARK: - SQLite

  @Test("SQLite under Protected mode stays pending until Rollback undoes it")
  func sqliteProtectedPending() async throws {
    let (manager, url) = try await connectSQLite()
    defer { try? FileManager.default.removeItem(at: url) }
    let epoch = await manager.connectionEpoch

    let result = try await manager.executeGatedSchemaChange(
      ["ALTER TABLE \"t\" ADD COLUMN \"a\" INTEGER"], policy: protected, connectionEpoch: epoch)
    #expect(result.pending)
    #expect(await manager.transactionSnapshot().pending.count == 1)
    try await manager.rollbackAppTransaction()
    #expect(try await columnNames(manager) == ["id"])
    await manager.disconnect()
  }

  @Test("SQLite table drop and rename go through the gate: pending under Protected mode")
  func sqliteTableDropAndRenameThroughGate() async throws {
    let (manager, url) = try await connectSQLite()
    defer { try? FileManager.default.removeItem(at: url) }
    let epoch = await manager.connectionEpoch
    let structure = try await manager.fetchTableStructure(schema: "main", table: "t")
    let engine = StructureDDLBuilder.Engine.sqlite(libraryVersion: SQLiteLibraryVersion.current)
    let drop = try StructureDDLBuilder.dropTable(structure, engine: engine)
    let rename = try StructureDDLBuilder.build(
      changes: [.renameTable(newName: "u")], structure: structure, engine: engine)

    let refused = await #expect(throws: DatabaseError.self) {
      _ = try await manager.executeGatedSchemaChange(
        drop, policy: ProtectionPolicy(protectionLevel: .schemaOnly), connectionEpoch: epoch)
    }
    #expect(isBlockedByProtection(refused))

    let dropped = try await manager.executeGatedSchemaChange(
      drop, policy: protected, connectionEpoch: epoch)
    #expect(dropped.pending)
    try await manager.rollbackAppTransaction()
    #expect(try await columnNames(manager) == ["id"])

    let renamed = try await manager.executeGatedSchemaChange(
      rename, policy: protected, connectionEpoch: epoch)
    #expect(renamed.pending)
    try await manager.commitAppTransaction(
      expectedGeneration: await manager.transactionStatus().generation)
    let names = try await manager.executeInternal(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    #expect(
      names.rows.compactMap { row -> String? in
        if case .string(let name) = row.first { return name }
        return nil
      } == ["u"])
    await manager.disconnect()
  }

  @Test("SQLite outside Protected mode rolls back every statement when one fails")
  func sqliteUnprotectedAtomic() async throws {
    let (manager, url) = try await connectSQLite()
    defer { try? FileManager.default.removeItem(at: url) }
    let epoch = await manager.connectionEpoch

    do {
      _ = try await manager.executeGatedSchemaChange(
        ["ALTER TABLE \"t\" ADD COLUMN \"a\" INTEGER", "ALTER TABLE \"t\" ADD COLUMN \"a\" TEXT"],
        policy: open, connectionEpoch: epoch)
      Issue.record("Expected the duplicate column to fail")
    } catch DatabaseError.batchStatementFailed(let index, _, _, let rolledBack) {
      #expect(index == 1)
      #expect(rolledBack)
    }
    #expect(try await columnNames(manager) == ["id"])
    await manager.disconnect()
  }

  // MARK: - MySQL

  @Test("MySQL refuses under Protected mode, with pending changes, or a user transaction open")
  func mysqlRefusals() async throws {
    let (manager, session) = try await connect(.mysql)
    let alter = ["ALTER TABLE `t` ADD COLUMN `a` int"]
    let epoch = await manager.connectionEpoch

    let protectedError = await #expect(throws: DatabaseError.self) {
      _ = try await manager.executeGatedSchemaChange(
        alter, policy: protected, connectionEpoch: epoch)
    }
    #expect(isBlockedByProtection(protectedError))
    #expect(session.statements.isEmpty)

    _ = try await manager.execute(userSQL: "UPDATE t SET a = 1", policy: protected)
    let pendingSent = session.statements.count
    let pendingError = await #expect(throws: DatabaseError.self) {
      _ = try await manager.executeGatedSchemaChange(alter, policy: open, connectionEpoch: epoch)
    }
    #expect(refusalReason(pendingError)?.contains("transaction") == true)
    #expect(session.statements.count == pendingSent)
    try await manager.rollbackAppTransaction()

    _ = try await manager.execute(userSQL: "BEGIN", policy: open)
    let userTxSent = session.statements.count
    do {
      _ = try await manager.executeGatedSchemaChange(alter, policy: open, connectionEpoch: epoch)
      Issue.record("Expected the open user transaction to refuse the change")
    } catch DatabaseError.schemaChangeRefused(let reason) {
      #expect(reason.contains("transaction"))
    }
    #expect(session.statements.count == userTxSent)
  }

  @Test("MySQL runs each statement without a transaction and clears the edit caches")
  func mysqlRunsSequentially() async throws {
    let (manager, session) = try await connect(.mysql)
    let ddl = ["ALTER TABLE `t` ADD COLUMN `a` int", "ALTER TABLE `u` ADD COLUMN `b` int"]
    let epoch = await manager.connectionEpoch
    let generation = await manager.mysqlTableColumns.generation

    let result = try await manager.executeGatedSchemaChange(
      ddl, policy: open, connectionEpoch: epoch)

    #expect(!result.pending)
    #expect(session.statements == ddl)
    #expect(await manager.mysqlTableColumns.generation > generation)
    #expect(await manager.takeSchemaRefresh())
  }

  @Test("MySQL reports applied k of n when a later statement fails")
  func mysqlPartialFailure() async throws {
    let (manager, session) = try await connect(.mysql)
    let ddl = [
      "ALTER TABLE `t` ADD COLUMN `a` int", "ALTER TABLE `u` ADD COLUMN `b` int",
      "ALTER TABLE `v` ADD COLUMN `c` int",
    ]
    let epoch = await manager.connectionEpoch
    let generation = await manager.mysqlTableColumns.generation
    session.failNextCommand(containing: "`u`")

    do {
      _ = try await manager.executeGatedSchemaChange(ddl, policy: open, connectionEpoch: epoch)
      Issue.record("Expected the second statement to fail")
    } catch DatabaseError.schemaChangePartiallyApplied(let applied, let total, _) {
      #expect(applied == 1)
      #expect(total == 3)
    }
    #expect(session.statements == Array(ddl.prefix(2)))
    #expect(await manager.mysqlTableColumns.generation > generation)
    let message = DatabaseError.schemaChangePartiallyApplied(applied: 1, total: 3, reason: "x")
      .errorDescription
    #expect(message?.contains("1 of 3") == true)
  }

  @Test("MySQL: when the first statement fails nothing was applied; the server error is thrown")
  func mysqlFirstStatementFails() async throws {
    let (manager, session) = try await connect(.mysql)
    let ddl = ["ALTER TABLE `t` ADD COLUMN `a` int", "ALTER TABLE `u` ADD COLUMN `b` int"]
    let epoch = await manager.connectionEpoch
    session.failNextCommand(containing: "`t`")

    do {
      _ = try await manager.executeGatedSchemaChange(ddl, policy: open, connectionEpoch: epoch)
      Issue.record("Expected the first statement to fail")
    } catch DatabaseError.queryFailed {
      // Unwrapped: nothing was applied
    }
    #expect(session.statements == Array(ddl.prefix(1)))
  }

  @Test("MySQL: a transaction opened between statements stops the rest as partially applied")
  func mysqlTransactionOpenedMidway() async throws {
    let (manager, session) = try await connect(.mysql)
    let ddl = ["ALTER TABLE `t` ADD COLUMN `a` int", "ALTER TABLE `u` ADD COLUMN `b` int"]
    let epoch = await manager.connectionEpoch
    let policy = open
    await manager.setBatchCheckpointHook { index in
      if index == 0 { _ = try? await manager.execute(userSQL: "BEGIN", policy: policy) }
    }

    do {
      _ = try await manager.executeGatedSchemaChange(ddl, policy: open, connectionEpoch: epoch)
      Issue.record("Expected the open transaction to stop the second statement")
    } catch DatabaseError.schemaChangePartiallyApplied(let applied, let total, _) {
      #expect(applied == 1)
      #expect(total == 2)
    }
    #expect(session.statements == [ddl[0], "BEGIN"])
    await manager.setBatchCheckpointHook(nil)
  }
}
