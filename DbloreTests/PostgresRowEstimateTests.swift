// PostgresRowEstimateTests.swift
// Sidebar row estimate of a PostgreSQL table that was never analyzed: `reltuples` is -1
// (PG 14+), so `fetchTables` falls back to the statistics counter (`n_live_tup`).
// Fewer than 50 rows, so autoanalyze cannot fill `reltuples` first. Live tuple stats are
// flushed up to ~1s after commit, hence the short poll.
// Against the docker test database (TEST_DB_* env, port 5435).

import Foundation
import Testing

@testable import Dblore

@Suite("Row Estimate - Integration (Requires PostgreSQL)", .requiresPostgres, .serialized)
@MainActor
struct PostgresRowEstimateTests {
  private static let table = "re_unanalyzed"

  private static let config = ConnectionConfig(
    host: TestDatabase.host,
    port: TestDatabase.port,
    database: TestDatabase.database,
    username: TestDatabase.username,
    password: TestDatabase.password,
    sslMode: .disable,
    timeoutSeconds: 30,
    safeMode: .silent,
    protectedMode: false,
    statementTimeoutSeconds: 45
  )

  @Test("A never-analyzed table gets its row estimate from the stats counter")
  func unanalyzedTableHasEstimate() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config)
    _ = try await manager.executeInternal("DROP TABLE IF EXISTS \(Self.table)")
    _ = try await manager.executeInternal("CREATE TABLE \(Self.table) (id int)")
    _ = try await manager.executeInternal(
      "INSERT INTO \(Self.table) SELECT generate_series(1, 3)")

    var estimate: Int?
    for _ in 0..<25 where estimate != 3 {
      try await Task.sleep(for: .milliseconds(200))
      estimate = try await manager.fetchTables().first { $0.name == Self.table }?.rowCount
    }
    #expect(estimate == 3)

    _ = try? await manager.executeInternal("DROP TABLE IF EXISTS \(Self.table)")
    await manager.disconnect()
  }
}
