// WriteUnlockTests.swift
// Timed write unlock of a Read-only connection (session only): after the authentication the gate
// lowers Read-only to Schema only (data writes run, schema changes stay refused) until the
// expiry, Lock now or a relock. MCP managers never get it. A DuckDB row with Read-only
// protection and a SQLite read-only file are refused the unlock. Fake clock and fake sessions.

import Foundation
import Testing
import os

@testable import Dblore

/// A clock the test moves by hand
private final class FakeClock: Sendable {
  private let date = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))

  var now: Date { date.withLock { $0 } }

  func advance(by seconds: TimeInterval) {
    date.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}

@Suite("Write unlock")
@MainActor
struct WriteUnlockTests {
  private let insert = "INSERT INTO t VALUES (1)"
  private let createTable = "CREATE TABLE u (a integer)"

  private static func config(
    _ databaseType: DatabaseType = .postgresql, level: ConnectionProtectionLevel = .readOnly,
    readOnlyFile: Bool = false
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: databaseType, host: "fake", port: 1,
      database: databaseType == .postgresql ? "db" : DuckDBSession.inMemoryPath,
      username: "u", password: "p", sslMode: .disable, protectionLevel: level, safeMode: .silent,
      protectedMode: false, readOnlyFile: readOnlyFile)
  }

  private func connect(
    _ config: ConnectionConfig, clock: FakeClock, registry: LockRegistry = LockRegistry(),
    servesMCP: Bool = false
  ) async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager(
      sessionFactory: FakeDatabaseSessionFactory(capabilities: .contract()),
      lockSource: registry, servesMCP: servesMCP, now: { clock.now })
    try await manager.connect(config: config)
    return manager
  }

  /// A tab of the workspace: its caller policy follows `controller`
  private func tab(
    _ config: ConnectionConfig, manager: DatabaseConnectionManager,
    controller: WriteUnlockController
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel(notebook: .newDocument())
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.notebook.connectionConfig = config
    viewModel.writeUnlock = controller
    return viewModel
  }

  private func isBlocked(
    _ sql: String, on manager: DatabaseConnectionManager, policy: ProtectionPolicy
  ) async -> Bool {
    do {
      _ = try await manager.execute(userSQL: sql, policy: policy)
      return false
    } catch DatabaseError.blockedByProtection {
      return true
    } catch {
      Issue.record("Unexpected error: \(error)")
      return false
    }
  }

  @Test("Unlock lowers Read-only to Schema only: INSERT runs, CREATE TABLE is refused")
  func unlockAllowsDataWritesOnly() async throws {
    let clock = FakeClock()
    let config = Self.config()
    let manager = try await connect(config, clock: clock)
    defer { Task { await manager.disconnect() } }
    let controller = WriteUnlockController(connectionManager: manager) { _ in true }
    let viewModel = tab(config, manager: manager, controller: controller)

    #expect(await isBlocked(insert, on: manager, policy: viewModel.protectionPolicy))

    #expect(await controller.requestUnlock(.oneMinute, config: config) == .started)
    #expect(viewModel.protectionPolicy.protectionLevel == .schemaOnly)
    #expect(await manager.connectedPolicy.protectionLevel == .schemaOnly)
    #expect(!(await isBlocked(insert, on: manager, policy: viewModel.protectionPolicy)))
    #expect(await isBlocked(createTable, on: manager, policy: viewModel.protectionPolicy))
    // Nothing is written to the connected config
    #expect(await manager.config?.protectionLevel == .readOnly)
  }

  @Test("Expiry restores Read-only, at the gate first and in the countdown at its next tick")
  func expiryRestoresReadOnly() async throws {
    let clock = FakeClock()
    let config = Self.config()
    let manager = try await connect(config, clock: clock)
    defer { Task { await manager.disconnect() } }
    let controller = WriteUnlockController(connectionManager: manager) { _ in true }
    let viewModel = tab(config, manager: manager, controller: controller)
    #expect(await controller.start(.oneMinute))
    #expect(controller.remainingSeconds == 60)

    clock.advance(by: 59)
    #expect(!(await isBlocked(insert, on: manager, policy: viewModel.protectionPolicy)))
    clock.advance(by: 1)
    #expect(viewModel.protectionPolicy.protectionLevel == .readOnly)
    #expect(await manager.connectedPolicy.protectionLevel == .readOnly)
    // Even a caller that still claims the unlock is refused by the connected config
    #expect(
      await isBlocked(insert, on: manager, policy: ProtectionPolicy(protectionLevel: .schemaOnly))
    )

    controller.tick()
    #expect(controller.expiry == nil)
    #expect(!controller.isActive)
  }

  @Test("Lock now and a relock end the unlock")
  func lockNowAndRelockEndIt() async throws {
    let clock = FakeClock()
    let registry = LockRegistry()
    let config = Self.config()
    let manager = try await connect(config, clock: clock, registry: registry)
    defer { Task { await manager.disconnect() } }
    let controller = WriteUnlockController(connectionManager: manager) { _ in true }
    let viewModel = tab(config, manager: manager, controller: controller)

    #expect(await controller.start(.fiveMinutes))
    await controller.lockNow()
    #expect(controller.expiry == nil)
    #expect(!(await manager.isWriteUnlocked))
    #expect(await isBlocked(insert, on: manager, policy: viewModel.protectionPolicy))

    #expect(await controller.start(.fiveMinutes))
    registry.relockAll()
    var ended = false
    for _ in 0..<500 {
      if controller.expiry == nil, await !manager.isWriteUnlocked {
        ended = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ended)
    #expect(viewModel.protectionPolicy.protectionLevel == .readOnly)
    #expect(await isBlocked(insert, on: manager, policy: viewModel.protectionPolicy))
  }

  @Test("A disconnect and a level change end the actor's unlock")
  func disconnectAndLevelChangeEndIt() async throws {
    let clock = FakeClock()
    let config = Self.config()
    let manager = try await connect(config, clock: clock)
    defer { Task { await manager.disconnect() } }

    #expect(await manager.unlockWrites(for: 60) != nil)
    await manager.updateConnectedProtection(from: Self.config(level: .none))
    await manager.updateConnectedProtection(from: config)
    #expect(!(await manager.isWriteUnlocked))

    #expect(await manager.unlockWrites(for: 60) != nil)
    await manager.disconnect()
    #expect(await manager.writeUnlockExpiry == nil)
    try await manager.connect(config: config)
    #expect(await manager.connectedPolicy.protectionLevel == .readOnly)
  }

  @Test("The MCP manager and policy of the same connection stay Read-only during an unlock")
  func mcpUnaffected() async throws {
    let clock = FakeClock()
    let config = Self.config()
    let app = try await connect(config, clock: clock)
    let mcp = try await connect(config, clock: clock, servesMCP: true)
    defer {
      Task {
        await app.disconnect()
        await mcp.disconnect()
      }
    }
    let controller = WriteUnlockController(connectionManager: app) { _ in true }
    #expect(await controller.start(.fiveMinutes))

    // MCP builds its policy from the saved row (`ProtectionPolicy(config:)`)
    let mcpPolicy = ProtectionPolicy(config: config)
    #expect(mcpPolicy.protectionLevel == .readOnly)
    #expect(await mcp.connectedPolicy.protectionLevel == .readOnly)
    #expect(await mcp.unlockWrites(for: 60) == nil)
    #expect(await isBlocked(insert, on: mcp, policy: mcpPolicy))
    // Even a caller that claims Schema only is held by the MCP manager's connected config
    #expect(
      await isBlocked(insert, on: mcp, policy: ProtectionPolicy(protectionLevel: .schemaOnly)))
  }

  @Test("A Read-only DuckDB row and a SQLite read-only file are refused the unlock")
  func duckDBAndReadOnlySQLiteRefused() async throws {
    let duckDB = Self.config(.duckdb)
    let sqliteFile = Self.config(.sqlite, readOnlyFile: true)
    #expect(ProtectionPolicy.writeUnlockRefusal(for: duckDB) != nil)
    #expect(ProtectionPolicy.writeUnlockRefusal(for: sqliteFile) != nil)
    // Only Read-only rows are offered it; a plain SQLite and a MongoDB Read-only row may
    #expect(ProtectionPolicy.writeUnlockRefusal(for: Self.config(level: .schemaOnly)) != nil)
    #expect(ProtectionPolicy.writeUnlockRefusal(for: Self.config(level: .none)) != nil)
    #expect(ProtectionPolicy.writeUnlockRefusal(for: Self.config(.sqlite)) == nil)
    #expect(ProtectionPolicy.writeUnlockRefusal(for: Self.config(.mongodb)) == nil)

    let clock = FakeClock()
    for config in [duckDB, sqliteFile] {
      let manager = try await connect(config, clock: clock)
      var authenticated = false
      let controller = WriteUnlockController(connectionManager: manager) { _ in
        authenticated = true
        return true
      }
      #expect(await controller.requestUnlock(.oneMinute, config: config) == .refused)
      #expect(!authenticated, "refused before any prompt")
      // The actor refuses it too, whatever the caller asks
      #expect(await !controller.start(.oneMinute))
      #expect(await manager.unlockWrites(for: 60) == nil)
      #expect(await manager.connectedPolicy.protectionLevel == .readOnly)
      await manager.disconnect()
    }
  }

  @Test("A failed authentication does not unlock")
  func failedAuthenticationKeepsReadOnly() async throws {
    let clock = FakeClock()
    let config = Self.config()
    let manager = try await connect(config, clock: clock)
    defer { Task { await manager.disconnect() } }
    let controller = WriteUnlockController(connectionManager: manager) { _ in false }
    let viewModel = tab(config, manager: manager, controller: controller)

    #expect(await controller.requestUnlock(.oneMinute, config: config) == .needsPassword)
    #expect(controller.expiry == nil)
    #expect(!(await manager.isWriteUnlocked))
    #expect(viewModel.protectionPolicy.protectionLevel == .readOnly)
    #expect(await isBlocked(insert, on: manager, policy: viewModel.protectionPolicy))
  }
}
