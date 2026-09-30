// ProtectionMergeIntegrationTests.swift
// The actor enforces the stricter of the caller's policy and the connected config
// (docker test database, TEST_DB_* env, port 5435 in autopilot).

import Foundation
import Testing

@testable import Dblore

@Suite("Protection Merge - Integration (Requires PostgreSQL)", .requiresPostgres)
struct ProtectionMergeIntegrationTests {
  private static func config(_ level: ConnectionProtectionLevel) -> ConnectionConfig {
    return ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      protectionLevel: level
    )
  }

  private let open = ProtectionPolicy(protectionLevel: .none)
  private let delete = "DELETE FROM s9_merge_missing_table WHERE id = 1"

  private func isBlocked(_ operation: () async throws -> Void) async -> Bool {
    do {
      try await operation()
      return false
    } catch DatabaseError.blockedByProtection {
      return true
    } catch {
      return false
    }
  }

  @Test("Connected .readOnly config blocks every gated entry even with a .none caller")
  func connectedReadOnlyBlocks() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config(.readOnly))
    defer { Task { await manager.disconnect() } }

    #expect(await isBlocked { _ = try await manager.execute(userSQL: delete, policy: open) })
    #expect(
      await isBlocked { _ = try await manager.executeDetailed(userSQL: delete, policy: open) })
    let update = try CellUpdateStatement.make(
      qualifiedName: "public.s9_merge_missing_table", columnName: "name", newValue: "x",
      primaryKeyColumns: ["id"], rowData: ["id": .int(1)])
    #expect(
      await isBlocked {
        _ = try await manager.executeGatedUpdate(
          update, policy: open, connectionEpoch: await manager.connectionEpoch)
      })
  }

  @Test("Runtime protection change on the connected config takes effect (both directions)")
  func runtimeChange() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config(.none))
    defer { Task { await manager.disconnect() } }

    // Allowed: reaches the server and fails there (missing table), not at the gate
    #expect(!(await isBlocked { _ = try await manager.execute(userSQL: delete, policy: open) }))

    await manager.updateConnectedProtection(from: Self.config(.readOnly))
    #expect(await isBlocked { _ = try await manager.execute(userSQL: delete, policy: open) })

    await manager.updateConnectedProtection(from: Self.config(.none))
    #expect(!(await isBlocked { _ = try await manager.execute(userSQL: delete, policy: open) }))
  }

  @Test("A stricter caller policy is never weakened by a looser connected config")
  func callerStricterWins() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config(.none))
    defer { Task { await manager.disconnect() } }

    let readOnly = ProtectionPolicy(protectionLevel: .readOnly)
    #expect(await isBlocked { _ = try await manager.execute(userSQL: delete, policy: readOnly) })
  }
}
