// SchemaChangeIntegrationTests.swift
// Structure editor round trips against the docker servers: load the table
// (`fetchTableStructure`), build DDL (`StructureDDLBuilder`), apply it through
// `executeGatedSchemaChange`, reload and compare.
// PostgreSQL (TEST_DB_*, 5435): column, constraint and index changes; Protected mode keeps the
// change pending (another session does not see it) until Commit, and Rollback undoes it; a type
// change that needs a cast fails without USING and rolls the whole batch back.
// MySQL 8.4 (3307) and MariaDB 11.4 (3308): MODIFY keeps every attribute it did not edit
// (charset, collation, comment, ON UPDATE, AUTO_INCREMENT, expression defaults, generated
// columns, string literals in either loaded as SQL and kept by MODIFY); RENAME COLUMN + ADD
// INDEX on the new name in one ALTER; CHECK and FOREIGN KEY add /
// drop; refusal while DML is pending (Protected mode or a user BEGIN) leaves the DML
// uncommitted; a failing second statement is reported as partially applied.
// Fixtures use unique `sc_` names and are dropped on every path. Opt-in per engine
// (`.requiresPostgres`, `.requiresMySQL`).

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct SchemaChangeIntegrationTests {
  typealias Server = MySQLSessionTests.Server

  private static let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private static let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  // MARK: - PostgreSQL

  @Test(
    "PostgreSQL: column, constraint and index changes round trip", .requiresPostgres,
    .timeLimit(.minutes(1)))
  func postgresRoundTrip() async throws {
    try await withPostgres { manager, _, schema in
      // Columns
      var table = try await Self.apply(
        [
          .addColumn(
            .init(name: "flag", type: "boolean", isNullable: false, defaultExpression: "true")),
          .alterColumnType(column: "note", type: "varchar(40)"),
          .dropDefault(column: "name"),
          .dropNotNull(column: "name"),
          .setDefault(column: "qty", expression: "5"),
          .setNotNull(column: "note"),
          .renameColumn(column: "code", newName: "sku"),
          .dropColumn(column: "obsolete"),
        ], schema: schema, table: "items", manager: manager, engine: .postgresql)
      #expect(
        table.columns.map(\.name) == ["id", "name", "qty", "sku", "note", "parent_id", "flag"])
      let byName = Dictionary(uniqueKeysWithValues: table.columns.map { ($0.name, $0) })
      #expect(byName["flag"]?.dataType == "boolean")
      #expect(byName["flag"]?.isNullable == false)
      #expect(byName["flag"]?.defaultExpression == "true")
      #expect(byName["note"]?.dataType == "character varying(40)")
      #expect(byName["note"]?.isNullable == false)
      #expect(byName["name"]?.defaultExpression == nil)
      #expect(byName["name"]?.isNullable == true)
      #expect(byName["qty"]?.defaultExpression == "5")
      #expect(byName["sku"]?.dataType == "text")

      // Constraints and indexes (names as loaded after the rename)
      let foreignKey = TableStructure.Constraint(
        name: "items_parent_fk",
        kind: .foreignKey(
          .init(
            schema: schema, table: "parent", columns: ["id"], onUpdate: .noAction,
            onDelete: .setNull)),
        columns: ["parent_id"])
      table = try await Self.apply(
        [
          .addConstraint(.init(name: "items_sku_key", kind: .unique, columns: ["sku"])),
          .addConstraint(.init(name: "items_qty_ck", kind: .check("qty >= 0"), columns: [])),
          .addConstraint(foreignKey),
          .createIndex(.init(name: "ix_qty", columns: ["qty"], isUnique: false, method: "btree")),
          .dropIndex(name: "ix_note"),
        ], schema: schema, table: "items", manager: manager, engine: .postgresql)
      #expect(
        table.constraints.contains(.init(name: "items_sku_key", kind: .unique, columns: ["sku"])))
      #expect(table.constraints.contains(foreignKey))
      #expect(
        table.constraints.contains {
          guard case .check(let expression) = $0.kind else { return false }
          return $0.name == "items_qty_ck" && expression.contains("qty >= 0")
        })
      #expect(
        table.indexes.contains(
          .init(
            name: "ix_qty", keys: [.column("qty")], isUnique: false, isPrimary: false,
            method: "btree", isPartial: false, predicate: nil)))
      #expect(!table.indexes.contains { $0.name == "ix_note" })

      // Drop them again
      table = try await Self.apply(
        [
          .dropConstraint(name: "items_sku_key", kind: .unique),
          .dropConstraint(name: "items_qty_ck", kind: .check),
          .dropConstraint(name: "items_parent_fk", kind: .foreignKey),
          .dropIndex(name: "ix_qty"),
        ], schema: schema, table: "items", manager: manager, engine: .postgresql)
      #expect(table.constraints.map(\.name) == ["items_pkey"])
      #expect(table.indexes.map(\.name) == ["items_pkey"])
    }
  }

  @Test(
    "PostgreSQL Protected mode: the change stays pending until Commit; Rollback undoes it",
    .requiresPostgres, .timeLimit(.minutes(1)))
  func postgresProtected() async throws {
    try await withPostgres { manager, observer, schema in
      func committedColumns() async throws -> [CellValue] {
        // Catalog only: a pending ALTER holds an ACCESS EXCLUSIVE lock on the table
        try await observer.executeInternal(
          """
          SELECT attname::text FROM pg_attribute
          WHERE attrelid = '\(schema).items'::regclass AND attnum > 0 AND NOT attisdropped
          ORDER BY attnum
          """
        ).rows.map { $0[0] }
      }
      let before = try await committedColumns()
      let structure = try await manager.fetchTableStructure(schema: schema, table: "items")
      let epoch = await manager.connectionEpoch
      let add = { (name: String) in
        try StructureDDLBuilder.build(
          changes: [.addColumn(.init(name: name, type: "integer", isNullable: true))],
          structure: structure, engine: .postgresql)
      }

      let result = try await manager.executeGatedSchemaChange(
        try add("pending_col"), policy: Self.protected, connectionEpoch: epoch)
      #expect(result.pending)
      #expect(await manager.transactionSnapshot().pending.count == 1)
      #expect(try await committedColumns() == before)

      let generation = await manager.transactionStatus().generation
      try await manager.commitAppTransaction(expectedGeneration: generation)
      #expect(try await committedColumns() == before + [.string("pending_col")])

      _ = try await manager.executeGatedSchemaChange(
        try add("rolled_back"), policy: Self.protected, connectionEpoch: epoch)
      #expect(try await committedColumns() == before + [.string("pending_col")])
      try await manager.rollbackAppTransaction()
      #expect(await manager.transactionSnapshot().isIdle)
      let reloaded = try await manager.fetchTableStructure(schema: schema, table: "items")
      #expect(reloaded.columns.map(\.name) == before.compactMap(Self.string) + ["pending_col"])
    }
  }

  @Test(
    "PostgreSQL: a type change that needs a cast fails without USING and rolls back the batch",
    .requiresPostgres, .timeLimit(.minutes(1)))
  func postgresCastFailure() async throws {
    try await withPostgres { manager, _, schema in
      let before = try await manager.fetchTableStructure(schema: schema, table: "items")
      let statements = try StructureDDLBuilder.build(
        changes: [.dropIndex(name: "ix_note"), .alterColumnType(column: "code", type: "integer")],
        structure: before, engine: .postgresql)
      #expect(statements.count == 2)
      let epoch = await manager.connectionEpoch
      do {
        _ = try await manager.executeGatedSchemaChange(
          statements, policy: Self.open, connectionEpoch: epoch)
        Issue.record("Expected the type change to fail")
      } catch DatabaseError.batchStatementFailed(let index, _, let reason, let rolledBack) {
        #expect(index == 1)
        #expect(rolledBack)
        #expect(reason.contains("cast") || reason.contains("USING"), "\(reason)")
      }
      #expect(await manager.transactionSnapshot().isIdle)
      #expect(try await manager.fetchTableStructure(schema: schema, table: "items") == before)
    }
  }

  // MARK: - MySQL / MariaDB

  @Test(
    "MySQL: MODIFY keeps every attribute it did not edit, generated columns restated",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func mysqlModifyKeepsAttributes(server: Server) async throws {
    try await withMySQL(server) { manager, _, names in
      let before = try await manager.fetchTableStructure(
        schema: Self.mysqlDatabase, table: names.child)
      let typeEdits = [
        "id": "bigint unsigned", "name": "varchar(30)", "u": "varchar(40)", "g": "bigint",
        "s": "bigint",
      ]
      var changes: [StructureChange] = typeEdits.keys.sorted().map {
        .alterColumnType(column: $0, type: typeEdits[$0]!)
      }
      changes += [.setNotNull(column: "ts"), .setNotNull(column: "d"), .dropDefault(column: "m")]
      let after = try await Self.apply(
        changes, schema: Self.mysqlDatabase, table: names.child, manager: manager,
        engine: try await Self.mysqlEngine(manager))

      let reloaded = Dictionary(uniqueKeysWithValues: after.columns.map { ($0.name, $0) })
      let expected = try before.columns.map { column -> TableStructure.Column in
        var column = column
        let now = try #require(reloaded[column.name])
        if let type = typeEdits[column.name] {
          // The server normalizes type text (`bigint(20)` on MariaDB)
          #expect(now.columnType?.hasPrefix(type.prefix { $0 != "(" && $0 != " " }) == true)
          #expect(
            now.columnType?.hasSuffix("unsigned") == type.hasSuffix("unsigned"), "\(column.name)")
          column.dataType = now.dataType
          column.columnType = now.columnType
        }
        switch column.name {
        case "ts", "d": column.isNullable = false
        case "m": column.defaultExpression = nil
        default: break
        }
        return column
      }
      #expect(after.columns == expected)
      #expect(reloaded["name"]?.columnType == "varchar(30)")
      #expect(reloaded["u"]?.columnType == "varchar(40)")
      #expect(after.indexes == before.indexes)
      #expect(after.constraints == before.constraints)
    }
  }

  @Test(
    "MySQL: expression defaults and generated columns with string literals round-trip",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func mysqlStringLiteralExpressions(server: Server) async throws {
    try await withMySQL(server) { manager, observer, names in
      let before = try await manager.fetchTableStructure(
        schema: Self.mysqlDatabase, table: names.child)
      let after = try await Self.apply(
        [.setNotNull(column: "cq"), .dropNotNull(column: "gq")], schema: Self.mysqlDatabase,
        table: names.child, manager: manager, engine: try await Self.mysqlEngine(manager))

      let old = Dictionary(uniqueKeysWithValues: before.columns.map { ($0.name, $0) })
      let new = Dictionary(uniqueKeysWithValues: after.columns.map { ($0.name, $0) })
      let defaultText = try #require(old["cq"]?.defaultExpression)
      let generatedText = try #require(old["gq"]?.generated?.expression)
      // Loaded as SQL, not MySQL's escaped display form (with a backslash before each quote)
      #expect(defaultText.contains("'x'"), "\(defaultText)")
      #expect(generatedText.contains("'x'"), "\(generatedText)")
      #expect(new["cq"]?.defaultExpression == defaultText)
      #expect(new["gq"]?.generated == old["gq"]?.generated)
      // MariaDB allows no NOT NULL on a generated column: `gq` is restated as it was
      #expect(new["cq"]?.isNullable == false && new["gq"]?.isNullable == true)

      _ = try await observer.executeInternal(
        "INSERT INTO \(names.child) (name) VALUES ('n')")
      let rows = try await observer.executeInternal("SELECT cq, gq FROM \(names.child)").rows
      #expect(
        rows.first?.compactMap(Self.string) == [#"it's a\bx"#, #"n it's a\bx"#], "\(rows)")
    }
  }

  @Test(
    "MySQL: RENAME COLUMN and ADD INDEX on the new name in one ALTER", .requiresMySQL,
    .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func mysqlRenameAndIndex(server: Server) async throws {
    try await withMySQL(server) { manager, _, names in
      let before = try await manager.fetchTableStructure(
        schema: Self.mysqlDatabase, table: names.child)
      let engine = try await Self.mysqlEngine(manager)
      let changes: [StructureChange] = [
        .renameColumn(column: "n", newName: "n2"),
        .createIndex(.init(name: "ix_n2", columns: ["n"], isUnique: false, method: nil)),
      ]
      let statements = try StructureDDLBuilder.build(
        changes: changes, structure: before, engine: engine)
      #expect(statements.count == 1)
      #expect(statements.first?.contains("RENAME COLUMN `n` TO `n2`") == true)
      let after = try await Self.apply(
        changes, schema: Self.mysqlDatabase, table: names.child, manager: manager, engine: engine)
      #expect(after.columns.map(\.name) == before.columns.map { $0.name == "n" ? "n2" : $0.name })
      let renamed = try #require(after.columns.first { $0.name == "n2" })
      var original = try #require(before.columns.first { $0.name == "n" })
      original.name = "n2"
      #expect(renamed == original)
      #expect(after.indexes.first { $0.name == "ix_n2" }?.keys == [.column("n2")])
    }
  }

  @Test(
    "MySQL: CHECK and FOREIGN KEY add and drop (DROP CHECK / DROP CONSTRAINT per flavor)",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func mysqlConstraints(server: Server) async throws {
    try await withMySQL(server) { manager, _, names in
      let engine = try await Self.mysqlEngine(manager)
      let foreignKey = TableStructure.Constraint(
        name: "sc_fk",
        kind: .foreignKey(
          .init(
            schema: Self.mysqlDatabase, table: names.parent, columns: ["id"],
            onUpdate: .cascade, onDelete: .setNull)),
        columns: ["pid"])
      var table = try await Self.apply(
        [
          .addConstraint(.init(name: "sc_ck", kind: .check("`m` >= 0"), columns: [])),
          .addConstraint(foreignKey),
        ], schema: Self.mysqlDatabase, table: names.child, manager: manager, engine: engine)
      #expect(table.constraints.contains(foreignKey))
      #expect(
        table.constraints.contains {
          guard case .check(let expression) = $0.kind else { return false }
          return $0.name == "sc_ck" && expression.contains("`m` >= 0")
        })

      let drops: [StructureChange] = [
        .dropConstraint(name: "sc_ck", kind: .check),
        .dropConstraint(name: "sc_fk", kind: .foreignKey),
      ]
      let statements = try StructureDDLBuilder.build(
        changes: drops, structure: table, engine: engine)
      let dropCheck = server == .mysql ? "DROP CHECK `sc_ck`" : "DROP CONSTRAINT `sc_ck`"
      #expect(statements.first?.contains(dropCheck) == true, "\(statements)")
      table = try await Self.apply(
        drops, schema: Self.mysqlDatabase, table: names.child, manager: manager, engine: engine)
      #expect(!table.constraints.contains { $0.name == "sc_ck" || $0.name == "sc_fk" })
    }
  }

  @Test(
    "MySQL Protected mode with a pending INSERT: refused, nothing sent, the INSERT stays pending",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func mysqlRefusedWithPendingChanges(server: Server) async throws {
    try await withMySQL(server, protectedMode: true) { manager, observer, names in
      let before = try await manager.fetchTableStructure(
        schema: Self.mysqlDatabase, table: names.child)
      let statements = try StructureDDLBuilder.build(
        changes: [.addColumn(.init(name: "extra", type: "int", isNullable: true))],
        structure: before, engine: try await Self.mysqlEngine(manager))
      _ = try await manager.execute(
        userSQL: "INSERT INTO \(names.child) (name) VALUES ('pending')", policy: Self.protected)
      #expect(await manager.transactionSnapshot().pending.count == 1)

      try await Self.expectRefused(statements, manager: manager, policy: Self.protected)
      #expect(await manager.transactionSnapshot().pending.count == 1)
      #expect(try await Self.count(names.child, observer) == 0)
      #expect(try await Self.count(names.child, manager) == 1)
      #expect(
        try await observer.fetchTableStructure(schema: Self.mysqlDatabase, table: names.child)
          == before)

      try await manager.rollbackAppTransaction()
      #expect(try await Self.count(names.child, manager) == 0)
      #expect(try await Self.count(names.child, observer) == 0)
    }
  }

  @Test(
    "MySQL with a user BEGIN and an uncommitted INSERT: refused, the INSERT stays uncommitted",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func mysqlRefusedWithUserTransaction(server: Server) async throws {
    try await withMySQL(server) { manager, observer, names in
      let before = try await manager.fetchTableStructure(
        schema: Self.mysqlDatabase, table: names.child)
      let statements = try StructureDDLBuilder.build(
        changes: [.addColumn(.init(name: "extra", type: "int", isNullable: true))],
        structure: before, engine: try await Self.mysqlEngine(manager))
      _ = try await manager.execute(userSQL: "BEGIN", policy: Self.open)
      _ = try await manager.execute(
        userSQL: "INSERT INTO \(names.child) (name) VALUES ('pending')", policy: Self.open)

      try await Self.expectRefused(statements, manager: manager, policy: Self.open)
      #expect(try await Self.count(names.child, observer) == 0)
      #expect(try await Self.count(names.child, manager) == 1)
      #expect(
        try await observer.fetchTableStructure(schema: Self.mysqlDatabase, table: names.child)
          == before)

      _ = try await manager.execute(userSQL: "ROLLBACK", policy: Self.open)
      #expect(try await Self.count(names.child, manager) == 0)
      #expect(try await Self.count(names.child, observer) == 0)
    }
  }

  @Test(
    "MySQL: a failing second statement reports 1 of 2 applied and the first change stays",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func mysqlPartiallyApplied(server: Server) async throws {
    try await withMySQL(server) { manager, _, names in
      let table = try SQLDialect.mysql.quoteIdentifier(names.child)
      let epoch = await manager.connectionEpoch
      do {
        _ = try await manager.executeGatedSchemaChange(
          [
            "ALTER TABLE \(table) ADD COLUMN `first_col` int",
            "ALTER TABLE \(table) ADD COLUMN `id` int",
          ], policy: Self.open, connectionEpoch: epoch)
        Issue.record("Expected the second statement to fail")
      } catch DatabaseError.schemaChangePartiallyApplied(let applied, let total, _) {
        #expect(applied == 1)
        #expect(total == 2)
      }
      let after = try await manager.fetchTableStructure(
        schema: Self.mysqlDatabase, table: names.child)
      #expect(after.columns.last?.name == "first_col")
    }
  }

  // MARK: - Helpers

  private static let mysqlDatabase = TestMySQLDatabase.database

  /// `build` + `executeGatedSchemaChange` (open policy, applied at once) + reload
  private static func apply(
    _ changes: [StructureChange], schema: String, table: String,
    manager: DatabaseConnectionManager, engine: StructureDDLBuilder.Engine
  ) async throws -> TableStructure {
    let structure = try await manager.fetchTableStructure(schema: schema, table: table)
    let statements = try StructureDDLBuilder.build(
      changes: changes, structure: structure, engine: engine)
    let result = try await manager.executeGatedSchemaChange(
      statements, policy: open, connectionEpoch: await manager.connectionEpoch)
    #expect(!result.pending)
    #expect(result.statements == statements)
    return try await manager.fetchTableStructure(schema: schema, table: table)
  }

  private static func mysqlEngine(
    _ manager: DatabaseConnectionManager
  ) async throws -> StructureDDLBuilder.Engine {
    .mysql(try #require(await manager.mysqlServerInfo))
  }

  private static func expectRefused(
    _ statements: [String], manager: DatabaseConnectionManager, policy: ProtectionPolicy
  ) async throws {
    let epoch = await manager.connectionEpoch
    do {
      _ = try await manager.executeGatedSchemaChange(
        statements, policy: policy, connectionEpoch: epoch)
      Issue.record("Expected the schema change to be refused")
    } catch DatabaseError.schemaChangeRefused(let reason) {
      #expect(reason.contains("transaction"), "\(reason)")
    }
  }

  private static func count(
    _ table: String, _ manager: DatabaseConnectionManager
  ) async throws -> Int {
    let rows = try await manager.executeInternal("SELECT COUNT(*) FROM \(table)").rows
    guard case .int(let count) = rows.first?.first else {
      Issue.record("Unexpected count result \(rows)")
      return -1
    }
    return count
  }

  private static func string(_ value: CellValue) -> String? {
    if case .string(let text) = value { return text }
    return nil
  }

  // MARK: - PostgreSQL fixture

  private static func postgresConfig() -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host, port: TestDatabase.port, database: TestDatabase.database,
      username: TestDatabase.username, password: TestDatabase.password, sslMode: .disable,
      timeoutSeconds: 30, safeMode: .silent, protectedMode: false, statementTimeoutSeconds: 45)
  }

  /// A unique schema with `parent (id)` and `items`, a manager and an observer. The manager
  /// rolls back and disconnects before the observer drops the schema (a pending ALTER would
  /// block the DROP), on every path.
  private func withPostgres(
    _ body: (
      _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager,
      _ schema: String
    ) async throws -> Void
  ) async throws {
    let schema = "sc_\(UUID().uuidString.prefix(8).lowercased())"
    let observer = DatabaseConnectionManager()
    let manager = DatabaseConnectionManager()
    try await observer.connect(config: Self.postgresConfig())
    do {
      for statement in [
        "CREATE SCHEMA \(schema)",
        "CREATE TABLE \(schema).parent (id integer PRIMARY KEY)",
        """
        CREATE TABLE \(schema).items (id integer PRIMARY KEY, name text NOT NULL DEFAULT 'x',
          qty integer NOT NULL DEFAULT 0, code text, note varchar(10), obsolete integer,
          parent_id integer)
        """,
        "CREATE INDEX ix_note ON \(schema).items (note)",
        "INSERT INTO \(schema).parent VALUES (1)",
        "INSERT INTO \(schema).items (id, name, qty, code, note) VALUES (1, 'a', 1, 'abc', 'n')",
      ] {
        _ = try await observer.executeInternal(statement)
      }
      try await manager.connect(config: Self.postgresConfig())
      try await body(manager, observer, schema)
    } catch {
      await Self.tearDownPostgres(manager, observer, schema)
      throw error
    }
    await Self.tearDownPostgres(manager, observer, schema)
  }

  private static func tearDownPostgres(
    _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager, _ schema: String
  ) async {
    try? await manager.rollbackAppTransaction()
    await manager.disconnect()
    _ = try? await observer.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
    await observer.disconnect()
  }

  // MARK: - MySQL fixture

  private struct MySQLNames {
    let child: String
    let parent: String
  }

  /// `parent (id)` and `child` with every attribute a MODIFY must keep, a manager (per
  /// `protectedMode`) and an unprotected observer. Both tables are dropped and both
  /// connections close on every path.
  private func withMySQL(
    _ server: Server, protectedMode: Bool = false,
    _ body: (DatabaseConnectionManager, DatabaseConnectionManager, MySQLNames) async throws -> Void
  ) async throws {
    let suffix = UUID().uuidString.prefix(6).lowercased()
    let names = MySQLNames(child: "sc_child_\(suffix)", parent: "sc_parent_\(suffix)")
    let observer = DatabaseConnectionManager()
    let manager = DatabaseConnectionManager()
    var observerConfig = MySQLManagerTests.config(server)
    observerConfig.safeMode = .silent
    try await observer.connect(config: observerConfig)
    do {
      for statement in [
        "CREATE TABLE \(names.parent) (id INT PRIMARY KEY)",
        """
        CREATE TABLE \(names.child) (
          id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY COMMENT 'the id',
          name VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL DEFAULT 'it''s'
            COMMENT 'the name',
          ts TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
          u VARCHAR(36) DEFAULT (uuid()),
          d DATETIME NULL DEFAULT CURRENT_TIMESTAMP,
          m INT NOT NULL DEFAULT 0 COMMENT 'm''s',
          g INT AS (m * 2) VIRTUAL COMMENT 'twice',
          s INT AS (m + 1) STORED,
          n INT,
          pid INT,
          cq VARCHAR(40) DEFAULT (concat('it''s', ' ', 'a\\\\b', _utf8mb4'x')),
          gq VARCHAR(80) AS (concat(name, ' it''s ', 'a\\\\b', _utf8mb4'x')) VIRTUAL,
          INDEX ix_m (m)
        )
        """,
      ] {
        _ = try await observer.executeInternal(statement)
      }
      var config = MySQLManagerTests.config(server, protectedMode: protectedMode)
      config.safeMode = .silent
      try await manager.connect(config: config)
      try await body(manager, observer, names)
    } catch {
      await Self.tearDownMySQL(manager, observer, names)
      throw error
    }
    await Self.tearDownMySQL(manager, observer, names)
  }

  private static func tearDownMySQL(
    _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager,
    _ names: MySQLNames
  ) async {
    try? await manager.rollbackAppTransaction()
    await manager.disconnect()
    for table in [names.child, names.parent] {
      _ = try? await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    }
    await observer.disconnect()
  }
}
