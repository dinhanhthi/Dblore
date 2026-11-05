// SQLRestoreSearchPathPinTests.swift
// Security: a PostgreSQL restore runs the dump's DDL with search_path pinned to
// `pg_catalog, pg_temp`, so a function or operator planted on the user's path never binds into a
// restored CHECK, DEFAULT, view or index. The user's value is read first and put back (bound)
// before RELEASE / COMMIT; a failing statement, an unreadable value or a failing put-back rolls
// the pin back with the batch. A SQLite restore sends none of it. The order of the plain
// BEGIN ... COMMIT and joined-transaction runs is checked in `SQLRestoreGateTests`.

import Foundation
import Testing

@testable import Dblore

@Suite("SQL restore search_path pin")
struct SQLRestoreSearchPathPinTests {
  private typealias Pin = DatabaseConnectionManager.SearchPathPin
  private let open = ProtectionPolicy(protectionLevel: .none)
  private static let savepoint = DatabaseConnectionManager.batchSavepoint

  /// A CHECK, a DEFAULT, a row, an index expression and a view, as the dump prints them
  private static let postgresDump = [
    SQLDumpAssembler.header(
      engine: .postgresql, created: Date(timeIntervalSince1970: 1_760_000_000)),
    "CREATE SCHEMA IF NOT EXISTS \"app\";",
    "CREATE TABLE \"app\".\"items\" (\"id\" integer NOT NULL, \"name\" text,"
      + " \"added\" timestamp with time zone DEFAULT now(), PRIMARY KEY (\"id\"));",
    "INSERT INTO \"app\".\"items\" (\"id\", \"name\", \"added\") VALUES\n('1', 'a', NULL);",
    "CREATE INDEX items_lower ON app.items USING btree (lower(name));",
    "ALTER TABLE \"app\".\"items\" ADD CONSTRAINT \"items_id_check\" CHECK ((id > 0)) NOT VALID;",
    "CREATE VIEW \"app\".\"named\" AS SELECT id FROM app.items WHERE (name = 'a'::text);",
  ].map { $0 + "\n" }.joined()

  private static let sqliteDump = [
    SQLDumpAssembler.header(engine: .sqlite, created: Date(timeIntervalSince1970: 1_760_000_000)),
    "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);",
    "INSERT INTO \"items\" (\"id\", \"name\") VALUES\n(1, 'a');",
  ].map { $0 + "\n" }.joined()

  private func connect(
    _ type: DatabaseType = .postgresql, protectedMode: Bool = false,
    queryAnswer: FakeQueryAnswer.Script? = nil
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSession) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: type.capabilities, queryAnswer: queryAnswer)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: type, host: "fake", port: 5432, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent,
        protectedMode: protectedMode))
    return (manager, try #require(factory.sessions.last))
  }

  private func restore(
    _ manager: DatabaseConnectionManager, _ plan: SQLRestorePlan
  ) async throws -> SQLRestoreSummary {
    try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch)
  }

  /// The restore's error, nil when it succeeded
  private func restoreError(
    _ manager: DatabaseConnectionManager, _ plan: SQLRestorePlan
  ) async -> Error? {
    do {
      _ = try await restore(manager, plan)
      return nil
    } catch {
      return error
    }
  }

  @Test("Protected mode: read, pin, dump, the read value put back bound, then RELEASE")
  func protectedModeOrder() async throws {
    let userPath = "a, public"
    let (manager, session) = try await connect(protectedMode: true) { sql, _ in
      sql == Pin.readSQL
        ? FakeQueryAnswer(
          columns: [ColumnInfo(name: "current_setting", type: "text")],
          rows: [[.string(userPath)]])
        : nil
    }
    let plan = try SQLRestorePlan(script: Self.postgresDump, engine: .postgresql)
    let summary = try await restore(manager, plan)
    #expect(summary.pending)
    let sent = session.statements
    #expect(
      Array(sent.suffix(plan.statements.count + 5))
        == ["SAVEPOINT \(Self.savepoint)", Pin.readSQL, Pin.pinSQL] + plan.statements.map(\.text)
        + [Pin.putBackSQL, "RELEASE SAVEPOINT \(Self.savepoint)"])
    let putBack = try #require(sent.firstIndex(of: Pin.putBackSQL))
    #expect(session.statementBinds[putBack] == [.text(userPath)])
  }

  @Test("A SQLite restore sends no search_path read, pin or put-back")
  func sqliteSendsNoPin() async throws {
    let (manager, session) = try await connect(.sqlite)
    let plan = try SQLRestorePlan(script: Self.sqliteDump, engine: .sqlite)
    _ = try await restore(manager, plan)
    let sent = session.statements
    #expect(Array(sent.dropFirst().dropLast()) == plan.statements.map(\.text))
    #expect(!sent.contains { [Pin.readSQL, Pin.pinSQL, Pin.putBackSQL].contains($0) })
  }

  @Test("A failing statement in the user's transaction rolls back to the savepoint, no put-back")
  func failingStatementInUserTransaction() async throws {
    let (manager, session) = try await connect()
    _ = try await manager.execute(userSQL: "BEGIN", policy: open)
    let plan = try SQLRestorePlan(script: Self.postgresDump, engine: .postgresql)
    let failing = try #require(
      plan.statements.firstIndex { $0.text.hasPrefix("CREATE INDEX items_lower") })
    session.failNextCommand(containing: "CREATE INDEX items_lower")
    let error = await restoreError(manager, plan)
    guard case .batchStatementFailed(let index, _, _, _)? = error as? DatabaseError else {
      Issue.record("Expected batchStatementFailed, got \(String(describing: error))")
      return
    }
    #expect(index == failing)
    let sent = session.statements
    #expect(
      Array(sent.suffix(failing + 6))
        == ["SAVEPOINT \(Self.savepoint)", Pin.readSQL, Pin.pinSQL]
        + plan.statements[...failing].map(\.text)
        + ["ROLLBACK TO SAVEPOINT \(Self.savepoint)", "RELEASE SAVEPOINT \(Self.savepoint)"])
    #expect(!sent.contains(Pin.putBackSQL))
    #expect(await manager.userTxOpen)
  }

  @Test("An unreadable search_path fails the restore before the pin and the first statement")
  func unreadableSearchPathFailsClosed() async throws {
    let (manager, session) = try await connect { sql, _ in
      sql == Pin.readSQL
        ? FakeQueryAnswer(columns: [ColumnInfo(name: "current_setting", type: "text")], rows: [])
        : nil
    }
    let plan = try SQLRestorePlan(script: Self.postgresDump, engine: .postgresql)
    let error = await restoreError(manager, plan)
    guard case .queryFailed(let message, _)? = error as? DatabaseError else {
      Issue.record("Expected queryFailed, got \(String(describing: error))")
      return
    }
    #expect(message.contains("could not read the session's search_path"))
    #expect(session.statements == ["BEGIN", Pin.readSQL, "ROLLBACK"])
    #expect(await manager.transactionSnapshot() == .idle)
  }

  @Test("A failing put-back rolls back to the savepoint instead of releasing the pin")
  func failingPutBackRollsBack() async throws {
    let (manager, session) = try await connect(protectedMode: true)
    session.failNextCommand(containing: "set_config")
    let plan = try SQLRestorePlan(script: Self.postgresDump, engine: .postgresql)
    #expect(await restoreError(manager, plan) != nil)
    let sent = session.statements
    let putBack = try #require(sent.firstIndex(of: Pin.putBackSQL))
    #expect(
      Array(sent[putBack...])
        == [
          Pin.putBackSQL, "ROLLBACK TO SAVEPOINT \(Self.savepoint)",
          "RELEASE SAVEPOINT \(Self.savepoint)", "ROLLBACK",
        ])
    #expect(await manager.transactionSnapshot() == .idle)
  }
}
