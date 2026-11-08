// SQLRestoreStreamLiveTests.swift
// A generated 50,000-row table dumped by `SQLDumpWriter` to a file, planned from that file (pass
// 1, in chunks) and restored from it (pass 2, re-read as it is sent) into an empty database:
// row count, sum of ids and sum of payload lengths equal the source. Every database and file is
// dropped on every path. Opt-in, CI only (`.requiresPostgres`, `.requiresMySQL`).

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct SQLRestoreStreamLiveTests {
  typealias Server = MySQLSessionTests.Server

  private let open = ProtectionPolicy(protectionLevel: .none)
  private static let rows = 50_000

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  @Test(
    "PostgreSQL: a 50k-row dump restores from its file with the same rows", .requiresPostgres,
    .timeLimit(.minutes(3)))
  func postgresStreamedRestore() async throws {
    let name = "stream_\(UUID().uuidString.prefix(8).lowercased())"
    let restored = name + "_restored"
    let admin = DatabaseConnectionManager()
    try await admin.connect(config: Self.postgresConfig(TestDatabase.database))
    let restorer = DatabaseConnectionManager()
    let directory = try Self.temporaryDirectory()
    do {
      _ = try await admin.executeInternal("CREATE DATABASE \(name)")
      _ = try await admin.executeInternal("CREATE DATABASE \(restored)")
      _ = try await Self.values(
        Self.postgresConfig(name),
        [
          "CREATE TABLE big (id bigint PRIMARY KEY, payload text, n numeric)",
          "INSERT INTO big SELECT g, md5(g::text), g / 7.0 FROM generate_series(1, \(Self.rows)) g",
        ])
      let check =
        "SELECT count(*)::text || ' ' || sum(id)::text || ' ' || sum(length(payload))::text FROM big"
      try await restoreFromFile(
        source: Self.postgresConfig(name), target: Self.postgresConfig(restored),
        engine: .postgresql, check: check, restorer: restorer, directory: directory)
    } catch {
      await restorer.disconnect()
      await Self.drop(admin, [name, restored], " WITH (FORCE)", directory)
      throw error
    }
    await Self.drop(admin, [name, restored], " WITH (FORCE)", directory)
  }

  @Test(
    "MySQL: a 50k-row dump restores from its file with the same rows", .requiresMySQL,
    .timeLimit(.minutes(3)), arguments: [Server.mysql, .mariadb])
  func mysqlStreamedRestore(server: Server) async throws {
    let name = "stream_\(UUID().uuidString.prefix(8).lowercased())"
    let restored = name + "_restored"
    let admin = DatabaseConnectionManager()
    try await admin.connect(config: MySQLManagerTests.rootConfig(server))
    let restorer = DatabaseConnectionManager()
    let directory = try Self.temporaryDirectory()
    do {
      _ = try await admin.executeInternal("CREATE DATABASE \(name) CHARACTER SET utf8mb4")
      _ = try await admin.executeInternal("CREATE DATABASE \(restored) CHARACTER SET utf8mb4")
      // 1,000 rows per INSERT, built here (no recursive CTE depth to raise)
      let inserts = stride(from: 1, through: Self.rows, by: 1_000).map { first in
        "INSERT INTO big VALUES "
          + (first..<(first + 1_000)).map { "(\($0), MD5('\($0)'), \($0) / 7)" }
          .joined(separator: ", ")
      }
      _ = try await Self.values(
        Self.mysqlConfig(server, name),
        ["CREATE TABLE big (id BIGINT PRIMARY KEY, payload VARCHAR(64), n DECIMAL(20,6))"]
          + inserts)
      let check = "SELECT CONCAT(COUNT(*), ' ', SUM(id), ' ', SUM(LENGTH(payload))) FROM big"
      try await restoreFromFile(
        source: Self.mysqlConfig(server, name), target: Self.mysqlConfig(server, restored),
        engine: .mysql, check: check, restorer: restorer, directory: directory)
    } catch {
      await restorer.disconnect()
      await Self.drop(admin, [name, restored], "", directory)
      throw error
    }
    await Self.drop(admin, [name, restored], "", directory)
  }

  // MARK: - Helpers

  /// Dumps `source` to a file, restores that file into `target` (both passes read it), then
  /// compares `check`'s answer on both
  private func restoreFromFile(
    source: ConnectionConfig, target: ConnectionConfig, engine: DatabaseType, check: String,
    restorer: DatabaseConnectionManager, directory: URL
  ) async throws {
    let file = directory.appendingPathComponent("dump.sql")
    _ = try await SQLDumpWriter(
      config: source, material: nil, sshCredential: nil,
      sshHostKeyPrompt: RejectingSSHHostKeyPrompt()
    ).write(to: file, options: SQLDumpOptions())
    let plan = try SQLRestorePlan(file: file, engine: engine)
    guard case .file = plan.source else {
      Issue.record("The plan is not file-backed")
      return
    }
    #expect(plan.summary.count(.data) > 1)
    try await restorer.connect(config: target)
    let summary = try await restorer.executeGatedRestore(
      plan, policy: open, connectionEpoch: await restorer.connectionEpoch)
    #expect(summary.statementsRun == summary.statementCount)
    await restorer.disconnect()
    let expected = try await Self.values(source, [check])
    // The source holds every generated row (md5 text is 32 characters)
    let text: String? =
      switch expected.first {
      case .string(let value): value
      case .data(let value): String(decoding: value, as: UTF8.self)
      default: nil
      }
    #expect(text == "\(Self.rows) \(Self.rows * (Self.rows + 1) / 2) \(32 * Self.rows)")
    #expect(try await Self.values(target, [check]) == expected)
  }

  private static func postgresConfig(_ database: String) -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host, port: TestDatabase.port, database: database,
      username: TestDatabase.username, password: TestDatabase.password, sslMode: .disable,
      timeoutSeconds: 30, safeMode: .silent, protectedMode: false)
  }

  private static func mysqlConfig(_ server: Server, _ database: String) -> ConnectionConfig {
    var config = MySQLManagerTests.rootConfig(server)
    config.database = database
    config.protectedMode = false
    return config
  }

  private static func drop(
    _ admin: DatabaseConnectionManager, _ databases: [String], _ suffix: String, _ directory: URL
  ) async {
    for database in databases {
      _ = try? await admin.executeInternal("DROP DATABASE IF EXISTS \(database)\(suffix)")
    }
    await admin.disconnect()
    try? FileManager.default.removeItem(at: directory)
  }

  /// The first value of each statement's result, on one new connection to `config`
  private static func values(
    _ config: ConnectionConfig, _ statements: [String]
  ) async throws -> [CellValue] {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    do {
      var values: [CellValue] = []
      for statement in statements {
        values.append(try await manager.executeInternal(statement).rows.first?.first ?? .null)
      }
      await manager.disconnect()
      return values
    } catch {
      await manager.disconnect()
      throw error
    }
  }

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-stream-restore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
