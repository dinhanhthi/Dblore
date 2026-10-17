// MongoGateTests.swift
// MongoDB commands through the manager's gate and statement routing, on a fake session with
// MongoDB capabilities: policies, Protected mode ignored, no named parameters, split pieces run
// as classified, reads capped by a rewritten limit (original text kept for display), writes sent
// unchanged as commands.

import Foundation
import Testing

@testable import Dblore

@Suite("MongoDB through the gate")
struct MongoGateTests {
  private static let maxRows = 3
  private let open = ProtectionPolicy(protectionLevel: .none)

  private static func config(
    level: ConnectionProtectionLevel = .none, protectedMode: Bool = false
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable, protectionLevel: level, safeMode: .silent, protectedMode: protectedMode)
  }

  private static let idColumn = [ColumnInfo(name: "_id", type: "objectId")]

  private static func rows(_ count: Int) -> [[CellValue]] {
    (0..<count).map { [.string(String(format: "%024x", $0))] }
  }

  private func connect(
    _ config: ConnectionConfig = Self.config(), rows: [[CellValue]] = []
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities, columns: Self.idColumn, rows: rows)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)
    return (manager, factory)
  }

  private func expectBlocked(
    _ text: String, kind: StatementKind, reason: String, manager: DatabaseConnectionManager,
    policy: ProtectionPolicy
  ) async {
    do {
      _ = try await manager.execute(userSQL: text, policy: policy, maxRows: Self.maxRows)
      Issue.record("\(text) should be blocked")
    } catch DatabaseError.blockedByProtection(let index, let blockedKind, let message) {
      #expect(index == 0)
      #expect(blockedKind == kind)
      #expect(message.contains(reason), "\(message)")
    } catch {
      Issue.record("Unexpected error \(error)")
    }
  }

  // MARK: - Policies

  @Test("Read-only allows find and blocks writes before anything is sent")
  func readOnlyPolicy() async throws {
    let config = Self.config(level: .readOnly)
    let (manager, factory) = try await connect(config)
    let policy = ProtectionPolicy(config: config)
    _ = try await manager.execute(userSQL: "db.c.find()", policy: policy, maxRows: Self.maxRows)
    #expect(factory.statements.count == 1)
    for write in ["db.c.insertOne({x: 1})", "db.c.deleteMany({})"] {
      await expectBlocked(
        write, kind: .dml, reason: "not allowed on a read-only connection", manager: manager,
        policy: policy)
    }
    #expect(factory.statements.count == 1)
  }

  @Test("Schema-only allows inserts, updates and deletes and blocks $out")
  func schemaOnlyPolicy() async throws {
    let config = Self.config(level: .schemaOnly)
    let (manager, factory) = try await connect(config)
    let policy = ProtectionPolicy(config: config)
    let writes = [
      "db.c.insertOne({x: 1})", "db.c.updateMany({}, {$set: {x: 2}})", "db.c.deleteOne({x: 2})",
    ]
    for write in writes {
      _ = try await manager.execute(userSQL: write, policy: policy, maxRows: Self.maxRows)
    }
    #expect(factory.statements == writes)
    #expect(factory.sessions.first?.queries.isEmpty == true)
    await expectBlocked(
      "db.c.aggregate([{$match: {}}, {$out: \"copy\"}])", kind: .ddl,
      reason: "blocked on a schema-protected connection", manager: manager, policy: policy)
    #expect(factory.statements == writes)
  }

  @Test("Protected mode is ignored: a write is sent on its own, no transaction opens")
  func protectedModeIgnored() async throws {
    let config = Self.config(protectedMode: true)
    let (manager, factory) = try await connect(config)
    let result = try await manager.execute(
      userSQL: "db.c.insertOne({x: 1})", policy: ProtectionPolicy(config: config),
      maxRows: Self.maxRows)
    #expect(factory.statements == ["db.c.insertOne({x: 1})"])
    #expect(result.columns.isEmpty)
    #expect(await manager.transactionSnapshot() == .idle)
  }

  // MARK: - Parameters and splitting

  @Test(
    "Key:value pairs are never planned as named parameters",
    arguments: ["db.c.find({a:b})", "db.c.updateOne({a:true}, {$set: {b:null}})"])
  func noNamedParameters(text: String) async throws {
    let (manager, factory) = try await connect()
    _ = try await manager.execute(
      userSQL: text, parameters: [:], policy: open, maxRows: Self.maxRows)
    let session = try #require(factory.sessions.first)
    let sent = try #require(session.statements.last)
    #expect(session.statementBinds.last?.isEmpty == true)
    #expect(!sent.contains("$1"))
    #expect(!sent.contains("?"))
  }

  @Test("A multi-command cell runs each split piece as classified, display keeps the original")
  func multiCommandCell() async throws {
    let (manager, factory) = try await connect(rows: Self.rows(Self.maxRows + 1))
    let find = "db['c'].find({a: 1}) // first"
    let insert = "db.c.insertOne({x: 1})"
    let run = try await manager.executeDetailed(
      userSQL: "\(find)\n\(insert)", policy: open, maxRows: Self.maxRows)
    let rewritten = try MongoCommandRewriter.withLimit(text: find, maxRows: Self.maxRows)
    #expect(factory.statements == [rewritten, insert])
    #expect(factory.sessions.first?.queries == [rewritten])
    #expect(run.results.map(\.queryText) == [find, insert])
    // The capped find does not reset the session or skip the insert
    let first = try #require(run.results.first?.result)
    #expect(first.truncated)
    #expect(!first.sessionReset)
    #expect(first.skippedStatements.isEmpty)
    #expect(factory.sessions.count == 1)
  }

  // MARK: - Row cap

  @Test(
    "A read is sent with a limit of maxRows + 1; history keeps the original text",
    arguments: [
      ("db['c'].find({a: 1}).limit(50) // all", ".limit(4)"),
      ("db.c.find()", ".limit(4)"),
      ("db.c.aggregate([{$match: {a: 1}}])", "$limit"),
    ])
  func readIsRewritten(original: String, cap: String) async throws {
    let (manager, factory) = try await connect()
    let run = try await manager.executeDetailed(
      userSQL: original, policy: open, maxRows: Self.maxRows)
    let rewritten = try MongoCommandRewriter.withLimit(text: original, maxRows: Self.maxRows)
    #expect(rewritten.contains(cap))
    #expect(factory.sessions.first?.queries == [rewritten])
    #expect(run.results.map(\.queryText) == [original])
  }

  @Test("Writes and $out/$merge aggregates are sent unchanged as commands")
  func writesAreNotRewritten() async throws {
    let (manager, factory) = try await connect()
    let writes = [
      "db['c'].insertOne({x: 1}) // keep",
      "db.c.aggregate([{$match: {}}, {$merge: {into: \"other\"}}])",
      "db.c.aggregate([{$out: \"copy\"}])",
    ]
    for write in writes {
      _ = try await manager.execute(userSQL: write, policy: open, maxRows: Self.maxRows)
    }
    #expect(factory.statements == writes)
    #expect(factory.sessions.first?.queries.isEmpty == true)
  }

  @Test("The truncated flag is set at maxRows + 1 rows, not at maxRows")
  func truncatedAtCapPlusOne() async throws {
    for (count, truncated) in [(Self.maxRows, false), (Self.maxRows + 1, true)] {
      let (manager, _) = try await connect(rows: Self.rows(count))
      let result = try await manager.execute(
        userSQL: "db.c.find()", policy: open, maxRows: Self.maxRows)
      #expect(result.truncated == truncated, "\(count) rows")
      #expect(result.rows.count == Self.maxRows)
      #expect(!result.sessionReset)
    }
  }

  @Test("An empty find keeps its _id column")
  func emptyFindKeepsIdColumn() async throws {
    let (manager, _) = try await connect()
    let result = try await manager.execute(
      userSQL: "db.c.find({missing: true})", policy: open, maxRows: Self.maxRows)
    #expect(result.rows.isEmpty)
    #expect(result.columns.map(\.name) == ["_id"])
  }

  // MARK: - Documents read

  @Test("A documents read of a $out pipeline under read-only is blocked before anything is sent")
  func documentsReadBlocksOut() async throws {
    let config = Self.config(level: .readOnly)
    let (manager, factory) = try await connect(config)
    do {
      _ = try await manager.executeMongoDocuments(
        userSQL: "db.c.aggregate([{$match: {}}, {$out: \"copy\"}])",
        policy: ProtectionPolicy(config: config), maxRows: Self.maxRows)
      Issue.record("$out should be blocked")
    } catch DatabaseError.blockedByProtection(let index, let kind, let message) {
      #expect(index == 0)
      #expect(kind == .ddl)
      #expect(message.contains("not allowed on a read-only connection"), "\(message)")
    }
    #expect(factory.statements.isEmpty)
  }

  @Test(
    "A documents read refuses anything but one find or aggregate, before anything is sent",
    arguments: [
      ("db.c.find()\ndb.c.find()", "one command"),
      ("db.c.aggregate([{$match: {}}, {$merge: {into: \"x\"}}])", "Only a read"),
      ("db.c.countDocuments({})", "Only a find or an aggregate"),
      // The fake session is not a MongoSession
      ("db.c.find()", "needs a MongoDB session"),
    ])
  func documentsReadRefusals(text: String, reason: String) async throws {
    let (manager, factory) = try await connect()
    do {
      _ = try await manager.executeMongoDocuments(
        userSQL: text, policy: open, maxRows: Self.maxRows)
      Issue.record("\(text) should be refused")
    } catch let error as MongoSessionError {
      #expect(error.message.contains(reason), "\(error.message)")
    }
    #expect(factory.statements.isEmpty)
  }

  // MARK: - Errors

  @Test("A failing Mongo read or write shows the session's formatError text; SQL does not")
  func failureUsesSessionFormatter() async throws {
    let formatted = "formatted by the session"
    let mongo = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities, columns: Self.idColumn,
      failingQuery: "find", errorFormatter: { _ in formatted })
    let manager = DatabaseConnectionManager(sessionFactory: mongo)
    try await manager.connect(config: Self.config())
    #expect(await failureMessage(manager, "db.c.find()") == formatted)
    mongo.sessions.first?.failNextCommand(containing: "insertOne")
    #expect(await failureMessage(manager, "db.c.insertOne({x: 1})") == formatted)

    let sql = FakeDatabaseSessionFactory(
      capabilities: .contract(), failingQuery: "SELECT", errorFormatter: { _ in formatted })
    let sqlManager = DatabaseConnectionManager(sessionFactory: sql)
    try await sqlManager.connect(
      config: ConnectionConfig(
        host: "fake", port: 5432, database: "db", username: "u", sslMode: .disable))
    #expect(
      await failureMessage(sqlManager, "SELECT 1") == FakeQueryError().localizedDescription)
  }

  /// The `queryFailed` message of `text`, nil when it ran or failed otherwise.
  private func failureMessage(
    _ manager: DatabaseConnectionManager, _ text: String
  ) async
    -> String?
  {
    do {
      _ = try await manager.execute(userSQL: text, policy: open, maxRows: Self.maxRows)
      Issue.record("\(text) should fail")
    } catch DatabaseError.queryFailed(let message, _) {
      return message
    } catch {
      Issue.record("Unexpected error \(error)")
    }
    return nil
  }

  // MARK: - Routing

  @Test("Mongo reads take the capped-read route without cursor, drain or reset")
  func routing() throws {
    let classify = { (text: String) in
      try #require(SQLStatementClassifier.classifyStatement(text, dialect: .mongodb))
    }
    let find = try classify("db.c.find()")
    #expect(StatementRoute.route(for: find, dialect: .mongodb) == .read)
    #expect(
      StatementRoute.route(for: try classify("db.c.insertOne({})"), dialect: .mongodb) == .command)
    #expect(
      StatementRoute.route(for: try classify("db.c.aggregate([{$out: \"x\"}])"), dialect: .mongodb)
        == .command)
    #expect(!DatabaseConnectionManager.usesCursor(find, dialect: .mongodb))
    #expect(!DatabaseConnectionManager.readsToEndAtCap(find, databaseType: .mongodb))
    #expect(!DatabaseType.mongodb.capabilities.supportsServerCursor)
    #expect(!DatabaseType.mongodb.capabilities.cappedReadResetsSession)
  }

  @Test("Mongo write tags give affected counts; AGGREGATE has none")
  func writeTags() throws {
    let tags: [(String, Int?)] = [
      ("INSERT 3", 3), ("UPDATE 2", 2), ("DELETE 0", 0), ("AGGREGATE", nil),
    ]
    for (tag, expected) in tags {
      let affected = tag == "AGGREGATE" ? 0 : expected ?? 0
      #expect(
        StatementRoute.commandAffectedRows(CommandResult(affectedRows: affected, tag: tag))
          == expected, "\(tag)")
    }
    let reply = MongoValue.document([.init("n", .int32(2)), .init("ok", .double(1))])
    let result = try MongoSession.commandResult(
      for: try MongoshParser.parse("db.c.deleteMany({a: 1})"), reply: reply)
    #expect(StatementRoute.commandAffectedRows(result) == 2)
  }
}
