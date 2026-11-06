// MySQLDumpRestoreIntegrationTests.swift
// A real mysqldump 8.4 file restored into MySQL 8.4 (3307) and a mariadb-dump 11.4 file into
// MariaDB 11.4 (3308) through `executeGatedRestore`: every row comes back (emoji, decimals,
// exponents, blobs, bits, a date and NULL), and the session's unique and foreign key checks,
// notes, character sets, time zone and sql_mode equal their values from before, with the
// dump's user variables cleared and no table left locked. The GTID file is refused before
// anything runs. Opt-in (`.requiresMySQL`, CI only). Tables use `rst_`.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MySQLDumpRestoreIntegrationTests {
  typealias Server = MySQLSessionTests.Server

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  private static let open = ProtectionPolicy(protectionLevel: .none)

  /// The session settings a dump changes, and the dump's user variables
  private static let settingsQuery = """
    SELECT @@SESSION.unique_checks, @@SESSION.sql_notes, @@SESSION.foreign_key_checks,
      @@character_set_client, @@character_set_connection, @@character_set_results,
      @@collation_connection, @@SESSION.time_zone, @@SESSION.sql_mode
    """
  private static let variablesQuery = """
    SELECT @OLD_UNIQUE_CHECKS IS NULL AND @OLD_SQL_MODE IS NULL AND @OLD_SQL_NOTES IS NULL
      AND @OLD_CHARACTER_SET_CLIENT IS NULL AND @OLD_TIME_ZONE IS NULL
      AND @saved_cs_client IS NULL
    """

  /// Runs `body` with a connected manager and the fixture's tables renamed to fresh `rst_`
  /// names; both are dropped and the manager disconnected on every path.
  private func withConnection(
    _ server: Server,
    _ body: (DatabaseConnectionManager, _ items: String, _ tags: String) async throws -> Void
  ) async throws {
    let suffix = UUID().uuidString.prefix(8).lowercased()
    let items = "rst_items_\(suffix)"
    let tags = "rst_tags_\(suffix)"
    var config = MySQLSessionTests.config(port: server.port)
    config.safeMode = .silent
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    do {
      try await body(manager, items, tags)
    } catch {
      await cleanup(manager, items, tags)
      throw error
    }
    await cleanup(manager, items, tags)
  }

  private func cleanup(_ manager: DatabaseConnectionManager, _ items: String, _ tags: String) async
  {
    _ = try? await manager.executeInternal("DROP TABLE IF EXISTS `\(items)`, `\(tags)`")
    await manager.disconnect()
  }

  private static func script(_ fixture: String, items: String, tags: String) -> String {
    fixture.replacingOccurrences(of: "`items`", with: "`\(items)`")
      .replacingOccurrences(of: "`tags`", with: "`\(tags)`")
  }

  private static func text(_ cell: CellValue) -> String {
    switch cell {
    case .string(let value): value
    case .int(let value): String(value)
    case .decimal(let value): value
    case .null: "NULL"
    default: "\(cell)"
    }
  }

  private static func row(
    _ manager: DatabaseConnectionManager, _ sql: String
  ) async throws
    -> [String]
  {
    try await manager.executeInternal(sql).rows.first.map { $0.map(text) } ?? []
  }

  @Test(
    "A real dump restores every row and leaves the session's settings as they were",
    .requiresMySQL, .timeLimit(.minutes(1)),
    arguments: [
      (Server.mysql, MySQLDumpFixtures.mysqlDump), (.mariadb, MySQLDumpFixtures.mariaDBDump),
    ])
  func restoresAndResets(server: Server, fixture: String) async throws {
    try await withConnection(server) { manager, items, tags in
      let before = try await Self.row(manager, Self.settingsQuery)
      #expect(before.count == 9)
      let summary = try await manager.executeGatedRestore(
        script: Self.script(fixture, items: items, tags: tags), policy: Self.open,
        connectionEpoch: await manager.connectionEpoch)
      #expect(summary.count(.data) == 2)
      #expect(try await Self.row(manager, Self.settingsQuery) == before)
      #expect(try await Self.row(manager, Self.variablesQuery) == ["1"])
      let rows = try await manager.executeInternal(
        """
        SELECT id, name, CAST(price AS CHAR), ratio IN (1.5e-10, -2.25e30), HEX(data),
          HEX(flags), CAST(made AS CHAR), note FROM `\(items)` ORDER BY id
        """
      ).rows.map { $0.map(Self.text) }
      #expect(
        rows == [
          ["1", "apple 🍎", "1234.567", "1", "00410A27", "21", "2026-11-05", "NULL"],
          ["2", "it's \"q\" \\ back", "-0.001", "1", "5C2241", "41", "1999-12-31", "n"],
        ])
      #expect(
        try await Self.row(manager, "SELECT COUNT(*), CAST(SUM(item_id) AS CHAR) FROM `\(tags)`")
          == ["2", "3"])
      // No table is left locked: another table of the database is readable on this session
      _ = try await manager.executeInternal("SELECT COUNT(*) FROM information_schema.TABLES")
    }
  }

  @Test(
    "A GTID dump is refused before anything runs", .requiresMySQL, .timeLimit(.minutes(1)))
  func gtidRefused() async throws {
    try await withConnection(.mysql) { manager, items, tags in
      let script = Self.script(MySQLDumpFixtures.mysqlDumpWithGTID, items: items, tags: tags)
      await #expect(throws: SQLRestoreError.self) {
        try await manager.executeGatedRestore(
          script: script, policy: Self.open, connectionEpoch: await manager.connectionEpoch)
      }
      let count = try await Self.row(
        manager,
        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() "
          + "AND TABLE_NAME = '\(items)'")
      #expect(count == ["0"])
    }
  }
}
