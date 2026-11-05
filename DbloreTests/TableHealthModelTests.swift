// TableHealthModelTests.swift
// Table Health runs on a side connection, never the tab's session: refused with a message while a
// transaction is open (nothing is opened), the structure and statistics findings combined, and the
// side connection closed on every path, Cancel included.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Table Health model")
struct TableHealthModelTests {
  /// The PostgreSQL structure read's table lookup (`PostgresSchemaIntrospector.tableStructure`)
  nonisolated fileprivate static let tableLookupMarker = "c.relkind OPERATOR(pg_catalog.=) ANY"

  @Test("Inside an open transaction the run is refused with a message and opens no connection")
  func refusedInsideTransaction() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connect(factory)
    _ = try await manager.execute(
      userSQL: "BEGIN", policy: ProtectionPolicy(protectionLevel: .none))
    let model = makeModel(manager, tables: ["orders"])

    model.start()
    #expect(model.isLoading)

    #expect(await settled(model) == .failed(TableHealthError.transactionOpen.localizedDescription))
    #expect(factory.sessions.count == 1)
  }

  @Test("A run combines structure and statistics findings on a side connection, then closes it")
  func runCombinesFindingsOnSideConnection() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = try await connect(factory)
    let model = makeModel(manager, tables: ["orders"])

    model.start()

    #expect(await settled(model) == .loaded)
    #expect(
      model.report.findings.map { "\($0.kind) \($0.table) \($0.objectName ?? "-")" } == [
        "noPrimaryKey orders -", "unusedIndex orders orders_note_idx",
      ])
    let tab = try #require(factory.sessions.first)
    let side = try #require(factory.sessions.dropFirst().first)
    #expect(!tab.statements.contains { $0.contains(Self.tableLookupMarker) })
    #expect(!tab.statements.contains { $0.contains("pg_stat_user_indexes") })
    #expect(side.statements.contains { $0.contains("pg_stat_user_indexes") })
    #expect(await closed(side))
  }

  @Test("Cancel stops the reads: nothing more is read, the side closes and the sheet hides")
  func cancelStopsTheRun() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract(), slowQueries: true)
    let manager = try await connect(factory)
    let model = makeModel(manager, tables: (0..<10).map { "t\($0)" })
    var hidden = false
    model.onClose = { hidden = true }

    model.start()
    let side = try #require(await sideSession(factory))
    for _ in 0..<500 where lookups(side) < TableHealthModel.concurrency {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(lookups(side) == TableHealthModel.concurrency)
    model.cancel()
    // The reads in flight are parked in the fake: end them as the server would
    await side.interrupt()
    for _ in 0..<500 where !hidden { try? await Task.sleep(for: .milliseconds(10)) }

    #expect(hidden)
    #expect(lookups(side) == TableHealthModel.concurrency)
    #expect(!side.statements.contains { $0.contains("pg_stat") })
    #expect(await closed(side))
  }

  // MARK: - Helpers

  private func makeModel(
    _ manager: DatabaseConnectionManager, tables: [String]
  ) -> TableHealthModel {
    TableHealthModel(
      tables: tables.map { .init(schema: "public", name: $0) }, engine: .postgresql,
      databaseName: "db", connectionManager: manager)
  }

  private func connect(
    _ factory: FakeDatabaseSessionFactory
  ) async throws
    -> DatabaseConnectionManager
  {
    let manager = DatabaseConnectionManager(sessionFactory: HealthCatalogFactory(inner: factory))
    try await manager.connect(
      config: ConnectionConfig(
        host: "fake", port: 1, database: "db", username: "u", password: "p", sslMode: .disable,
        protectionLevel: .none, safeMode: .silent, protectedMode: false))
    return manager
  }

  /// The phase once the run ended, bounded
  private func settled(_ model: TableHealthModel) async -> TableHealthModel.Phase {
    for _ in 0..<500 where model.phase == .loading {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return model.phase
  }

  /// The second session made (the side connection), bounded
  private func sideSession(_ factory: FakeDatabaseSessionFactory) async -> FakeDatabaseSession? {
    for _ in 0..<500 where factory.sessions.count < 2 {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return factory.sessions.dropFirst().first
  }

  private func lookups(_ session: FakeDatabaseSession) -> Int {
    session.statements.filter { $0.contains(Self.tableLookupMarker) }.count
  }

  private func closed(_ session: FakeDatabaseSession) async -> Bool {
    for _ in 0..<200 where !session.didClose {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return session.didClose
  }
}

/// Sessions of `inner` whose PostgreSQL table lookup finds the table (it has no columns, indexes
/// or constraints) and whose unused-index read returns `public.orders.orders_note_idx`
private struct HealthCatalogFactory: DatabaseSessionFactory {
  let inner: FakeDatabaseSessionFactory

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    HealthCatalogSession(inner: inner.makeSession(config: config))
  }
}

private final class HealthCatalogSession: DatabaseSession {
  let inner: any DatabaseSession

  init(inner: any DatabaseSession) {
    self.inner = inner
  }

  var capabilities: DatabaseCapabilities { inner.capabilities }
  var closeEvents: AsyncStream<SessionCloseReason> { inner.closeEvents }

  func open() async throws { try await inner.open() }
  func close() async { await inner.close() }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    let source = try await inner.query(sql, binds: binds)
    let row: [CellValue]
    if sql.contains(TableHealthModelTests.tableLookupMarker) {
      row = [.int(16_400), .null]
    } else if sql.contains("pg_stat_user_indexes") {
      row = [.string("public"), .string("orders"), .string("orders_note_idx")]
    } else {
      return source
    }
    return SessionRowSource(
      columns: [],
      rows: AsyncThrowingStream { continuation in
        continuation.yield(row)
        continuation.finish()
      })
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    try await inner.command(sql, binds: binds)
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    try await inner.openCursor(sql, binds: binds)
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
