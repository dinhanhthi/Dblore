// MongoRoutingTests.swift
// MongoDB never takes a SQL route by accident: sessions, catalog, gate dialect, history
// classification and the capability guards in front of PostgreSQL-shaped SQL paths. Pins the
// silent routes of the batch-5 blast radius (q1) and the Phase 4/5 fail-closed arms.

import Foundation
import Testing

@testable import Dblore

@Suite("MongoDB routing")
struct MongoRoutingTests {
  private let mongoConfig = ConnectionConfig(
    databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
    sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
  private let sentinel = "-- dblore: MongoDB has no transactions"
  private let open = ProtectionPolicy(protectionLevel: .none)

  private func connectFake() async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory)
  {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: mongoConfig)
    return (manager, factory)
  }

  // MARK: - Sessions and catalog

  @Test("The app factory opens a MongoSession for MongoDB, never a SQL session")
  func appFactoryMakesMongoSession() async throws {
    let session = try await AppDatabaseSessionFactory().makeSession(config: mongoConfig)
    #expect(session is MongoSession)
    #expect(!(session is PostgresSession))
    #expect(!(session is MySQLSession))
    #expect(!(session is SQLiteSession))
  }

  @Test("A MongoDB connection reads its catalog through MongoSchemaIntrospector")
  func introspectorIsMongo() async throws {
    let (manager, _) = try await connectFake()
    #expect(await manager.introspector is MongoSchemaIntrospector)
  }

  @Test("MCP refuses MongoDB before the inner factory opens anything")
  func mcpFactoryRefusesMongo() async throws {
    let inner = FakeDatabaseSessionFactory(capabilities: .contract())
    do {
      _ = try await MCPReadOnlySessionFactory(inner: inner).makeSession(config: mongoConfig)
      Issue.record("MCP should refuse MongoDB")
    } catch DatabaseError.engineUnavailable(let type) {
      #expect(type == .mongodb)
    }
    #expect(inner.sessions.isEmpty)
  }

  // MARK: - Gate dialect and silent routes

  @Test("The gate classifies MongoDB text with the mongosh classifier")
  func gateUsesMongoDialect() {
    #expect(DatabaseConnectionManager.dialect(of: mongoConfig) == .mongodb)
    let kinds = DatabaseConnectionManager.classifyUserSQL(
      "db.users.find({}); db.users.deleteMany({})", config: mongoConfig
    ).map(\.kind)
    #expect(kinds == [.read, .dml])
  }

  @Test("Mongo operators and key:value pairs are never SQL parameters")
  func parameterRewriterSkipsMongo() {
    let text = "db.c.updateOne({a:b}, {$set: {n: $1, m: ?}})"
    let rewritten = SQLParameterRewriter.rewrite(statement: text, dialect: .mongodb)
    #expect(rewritten.text == text)
    #expect(rewritten.names.isEmpty)
    #expect(SQLParameterRewriter.parameterNames(in: text, dialect: .mongodb).isEmpty)
    #expect(!SQLParameterRewriter.containsPositionalPlaceholder(in: text, dialect: .mongodb))
  }

  @Test("A MongoDB| history key backfills kinds with the mongosh classifier")
  func historyKeyMapsToMongo() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-history-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
      }
    }
    let mongo = "MongoDB|fake|27017|db|u"
    let postgres = "PostgreSQL|fake|5432|db|u"
    let rows: [(sql: String, key: String, kind: QueryHistoryEntry.Kind?)] = [
      ("db.users.find({})", mongo, .read),
      ("db.users.deleteMany({})", mongo, .write),
      ("db.users.deleteMany({})", postgres, .other),
    ]
    try seedVersion1(at: url, rows: rows.map { ($0.sql, $0.key) })

    let loaded = try await QueryHistoryStore(url: url).search(
      text: "", scope: .all, limit: 10, offset: 0)
    let actual = loaded.map { "\($0.connectionKey)|\($0.sql)|\($0.kind?.rawValue ?? "nil")" }
    let wanted = rows.map { "\($0.key)|\($0.sql)|\($0.kind?.rawValue ?? "nil")" }
    #expect(actual.sorted() == wanted.sorted())
  }

  // MARK: - Capability guards

  @Test("Capability guards keep PostgreSQL-shaped SQL paths off for MongoDB")
  func capabilityGuards() {
    let capabilities = DatabaseType.mongodb.capabilities
    // Import (ImportSQLBuilder, TableImportModel, ImportTypeInference)
    #expect(!capabilities.supportsDataImport)
    // Staged SQL edits (RowChangeSQLBuilder, CellUpdateStatement quoting)
    #expect(!capabilities.supportsRowStaging)
    // Foreign key lookup
    #expect(!capabilities.supportsForeignKeyLookup)
    // Explain Analyze
    #expect(!capabilities.supportsExplainAnalyze)
    #expect(!capabilities.supportsExplainJSON)
    // Hidden until Phase 12
    #expect(!capabilities.isAvailable)
    #expect(!DatabaseType.connectionPickerTypes(showExperimental: false).contains(.mongodb))
    for type in DatabaseType.allCases {
      #expect(
        (type.capabilities.queryLanguage == .mongosh) == (type.dialect == .mongodb),
        "\(type.rawValue)")
    }
  }

  // MARK: - No transactions

  @Test("The app BEGIN refuses MongoDB and sends nothing")
  func beginAppTransactionRefused() async throws {
    let (manager, factory) = try await connectFake()
    let before = factory.statements.count
    do {
      try await manager.beginAppTransaction(caller: nil)
      Issue.record("MongoDB has no transactions")
    } catch DatabaseError.transactionAborted(let message) {
      #expect(message.contains("no transactions"))
    }
    #expect(factory.statements.count == before)
    #expect(await manager.transactionSnapshot() == .idle)
  }

  @Test("The BEGIN sentinel is no mongosh command and a MongoSession refuses it unsent")
  func sentinelIsRejected() async throws {
    let (manager, _) = try await connectFake()
    #expect(await manager.appOwnedBeginSQL == sentinel)
    #expect(throws: MongoshParser.ParseError.self) { try MongoshParser.parse(sentinel) }
    #expect(MongoCommandClassifier.classify(sentinel).map(\.kind) == [.unknown])
    // Parsed before any connection is used: an unopened session throws without a network
    await #expect(throws: (any Error).self) {
      _ = try await MongoSession(config: mongoConfig).command(sentinel, binds: [])
    }
  }

  // MARK: - Unprotected edits and batches

  private var update: CellUpdateStatement {
    CellUpdateStatement(
      sql: "UPDATE \"public\".\"t\" SET \"v\" = $1 WHERE \"id\" = $2", values: ["2", "1"])
  }

  private var batch: [BoundStatement] {
    [BoundStatement(sql: "DELETE FROM \"public\".\"t\" WHERE \"id\" = $1", values: ["1"])]
  }

  @Test("Protected mode and Read-only refuse SQL edits and batches on MongoDB, nothing sent")
  func gatedEditsRefusedUnderProtection() async throws {
    let (manager, factory) = try await connectFake()
    let before = factory.statements.count
    let epoch = await manager.connectionEpoch
    for policy in [
      ProtectionPolicy(protectionLevel: .none, protectedMode: true),
      ProtectionPolicy(protectionLevel: .readOnly),
    ] {
      await #expect(throws: DatabaseError.self) {
        _ = try await manager.executeGatedUpdate(update, policy: policy, connectionEpoch: epoch)
      }
      await #expect(throws: DatabaseError.self) {
        _ = try await manager.executeGatedBatch(batch, policy: policy, connectionEpoch: epoch)
      }
    }
    #expect(factory.statements.count == before)
  }

  /// With no protection the gate would reach `runUnprotectedEdit` / `runUnprotectedBatch`
  /// (BEGIN sentinel and SQL sent to the session); the `supportsRowStaging` guard refuses
  /// both first, before the owner is claimed or anything is sent.
  @Test("Unprotected SQL edits and batches never reach a MongoDB session")
  func unprotectedEditsNeverReachSession() async throws {
    let (manager, factory) = try await connectFake()
    let before = factory.statements.count
    let epoch = await manager.connectionEpoch
    do {
      _ = try await manager.executeGatedUpdate(update, policy: open, connectionEpoch: epoch)
      Issue.record("MongoDB inline edits should be refused")
    } catch DatabaseError.notEditable(let reason) {
      #expect(reason.contains("not available for MongoDB"))
    }
    do {
      _ = try await manager.executeGatedBatch(batch, policy: open, connectionEpoch: epoch)
      Issue.record("MongoDB staged batches should be refused")
    } catch DatabaseError.notEditable(let reason) {
      #expect(reason.contains("not available for MongoDB"))
    }
    let sent = Array(factory.statements.dropFirst(before))
    #expect(sent.isEmpty, "sent: \(sent)")
  }

  // MARK: - Structure editor

  @Test("Structure changes are refused for MongoDB, even an aggregate that creates a collection")
  func schemaChangeRefused() async throws {
    let out = ["db.a.aggregate([{$out: \"b\"}])"]
    #expect(
      DatabaseConnectionManager.schemaChangeRefusal(
        out, databaseType: .mongodb, transactionOpen: false) != nil)

    let (manager, factory) = try await connectFake()
    let before = factory.statements.count
    do {
      _ = try await manager.executeGatedSchemaChange(
        out, policy: open, connectionEpoch: await manager.connectionEpoch)
      Issue.record("MongoDB structure changes should be refused")
    } catch DatabaseError.schemaChangeRefused {}
    #expect(factory.statements.count == before)
  }

  // MARK: - Helpers

  /// Version-1 history file (no `kind` column) with just the tables the migration touches.
  private func seedVersion1(at url: URL, rows: [(String, String)]) throws {
    let database = try SQLiteHandle(url: url)
    try database.transaction {
      try database.execute(
        """
        CREATE TABLE history (
          id INTEGER PRIMARY KEY, sql TEXT NOT NULL, executed_at REAL NOT NULL,
          duration_ms INTEGER NOT NULL, row_count INTEGER, status TEXT NOT NULL,
          error_message TEXT, connection_key TEXT NOT NULL, connection_label TEXT NOT NULL,
          workspace_id TEXT, workspace_name TEXT, source TEXT NOT NULL
        )
        """
      )
      try database.execute(
        """
        CREATE VIRTUAL TABLE history_fts USING fts5(
          sql, error_message, connection_label, workspace_name,
          content='history', content_rowid='id'
        )
        """
      )
      try database.execute("PRAGMA user_version = 1")
    }
    for (offset, (sql, key)) in rows.enumerated() {
      let statement = try database.prepare(
        """
        INSERT INTO history (
          sql, executed_at, duration_ms, status, connection_key, connection_label, source
        ) VALUES (?, ?, 1, 'success', ?, 'label', 'cell')
        """
      )
      try statement.bind(1, .string(sql))
      try statement.bind(2, .double(Double(1_700_000_000 + offset)))
      try statement.bind(3, .string(key))
      while try statement.step() {}
    }
  }
}
