// WorkspaceConnectUnlockTests.swift
// Connecting again to the same database with weaker safety settings needs the Safe Mode unlock
// (same rule as a runtime change); a different database or strengthening connects immediately.

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Workspace Connect Unlock Tests")
@MainActor
struct WorkspaceConnectUnlockTests {
  private static func config(
    host: String = "db.example.com", database: String = "app", username: String = "admin",
    protectionLevel: ConnectionProtectionLevel = .none, safeMode: SafeMode? = nil,
    protectedMode: Bool = true
  ) -> ConnectionConfig {
    ConnectionConfig(
      host: host, port: 5432, database: database, username: username, password: "pw",
      protectionLevel: protectionLevel, safeMode: safeMode, protectedMode: protectedMode)
  }

  private static let strict = config(protectionLevel: .readOnly, safeMode: .safeAll)
  private static let weak = config(protectionLevel: .none, safeMode: .silent, protectedMode: false)

  // MARK: - Decision (pure)

  @Test("Same target, readOnly + safeAll -> none + silent needs the unlock")
  func sameTargetWeakeningNeedsUnlock() {
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.strict, new: Self.weak, globalSafeMode: .silent))
  }

  @Test("Same target compared case-insensitively and ignoring surrounding spaces")
  func sameTargetCaseInsensitive() {
    let weakUpper = Self.config(
      host: " DB.Example.COM ", database: "APP", username: "Admin", safeMode: .silent)
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.strict, new: weakUpper, globalSafeMode: .silent))
  }

  @Test("Global safeAll fallback counts as the current effective Safe Mode")
  func globalFallbackNeedsUnlock() {
    let current = Self.config(protectionLevel: .readOnly, safeMode: nil)
    let new = Self.config(protectionLevel: .none, safeMode: nil)
    #expect(
      WorkspaceManager.connectRequiresUnlock(current: current, new: new, globalSafeMode: .safeRead))
  }

  @Test("Strengthening connects immediately")
  func strengtheningNoUnlock() {
    let current = Self.config(protectionLevel: .schemaOnly, safeMode: .safeRead)
    let new = Self.config(protectionLevel: .readOnly, safeMode: .safeAll)
    #expect(
      !WorkspaceManager.connectRequiresUnlock(current: current, new: new, globalSafeMode: .silent))
  }

  @Test("A different database, host or user is a new connection: no unlock")
  func differentTargetNoUnlock() {
    for new in [
      Self.config(database: "other", safeMode: .silent),
      Self.config(host: "other.example.com", safeMode: .silent),
      Self.config(username: "reader", safeMode: .silent),
    ] {
      #expect(
        !WorkspaceManager.connectRequiresUnlock(
          current: Self.strict, new: new, globalSafeMode: .safeAll))
    }
    var otherPort = Self.weak
    otherPort.port = 6543
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.strict, new: otherPort, globalSafeMode: .safeAll))
  }

  @Test("Current effective Safe Mode without a password: no unlock")
  func nonPasswordModeNoUnlock() {
    let current = Self.config(protectionLevel: .readOnly, safeMode: .alertAll)
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: current, new: Self.weak, globalSafeMode: .safeAll))
  }

  @Test("No current config: no unlock")
  func noCurrentNoUnlock() {
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: nil, new: Self.weak, globalSafeMode: .safeAll))
  }

  // MARK: - Deferred connect (no database needed)

  @Test("Weakening connect is deferred: not connected, config unchanged, pending set")
  func weakeningConnectDeferred() async {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.strict), restoreTabs: false)
    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.connect(config: Self.weak, globalSafeMode: .silent)
    }
    #expect(manager.pendingWeakeningConnect == Self.weak)
    #expect(manager.workspace.connectionConfig == Self.strict)
    #expect(manager.connectionState == .disconnected)
    #expect(await !manager.connectionManager.isConnected)
    #expect(await manager.connectionManager.connectedPolicy.protectionLevel == .none)
  }

  @Test("Cancelling the unlock drops the pending connect and connects nothing")
  func cancelPendingConnect() async {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.strict), restoreTabs: false)
    _ = try? await manager.connect(config: Self.weak, globalSafeMode: .silent)
    manager.cancelPendingWeakeningConnect()
    #expect(manager.pendingWeakeningConnect == nil)
    #expect(manager.workspace.connectionConfig == Self.strict)
    #expect(await !manager.connectionManager.isConnected)
  }

  @Test("Completing without a pending connect does nothing")
  func completeWithoutPending() async throws {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.strict), restoreTabs: false)
    try await manager.completePendingWeakeningConnect()
    #expect(manager.workspace.connectionConfig == Self.strict)
    #expect(await !manager.connectionManager.isConnected)
  }
}

@Suite("Workspace Connect Unlock - Integration (Requires PostgreSQL)")
@MainActor
struct WorkspaceConnectUnlockIntegrationTests {
  private static func config(
    protectionLevel: ConnectionProtectionLevel, safeMode: SafeMode, protectedMode: Bool = true
  ) -> ConnectionConfig {
    let env = ProcessInfo.processInfo.environment
    return ConnectionConfig(
      host: env["TEST_DB_HOST"] ?? "localhost",
      port: Int(env["TEST_DB_PORT"] ?? "5432") ?? 5432,
      database: env["TEST_DB_NAME"] ?? "postgres",
      username: env["TEST_DB_USER"] ?? "postgres",
      password: env["TEST_DB_PASSWORD"] ?? "",
      sslMode: .disable,
      rememberConnection: false,
      timeoutSeconds: 30,
      protectionLevel: protectionLevel,
      safeMode: safeMode,
      protectedMode: protectedMode
    )
  }

  @Test("Same DB weakened: deferred until unlock, then connects with the new config")
  func deferredThenConnects() async throws {
    let strict = Self.config(protectionLevel: .readOnly, safeMode: .safeAll)
    let weak = Self.config(protectionLevel: .none, safeMode: .silent, protectedMode: false)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: strict), restoreTabs: false)
    defer { Task { await manager.disconnect() } }

    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.connect(config: weak, globalSafeMode: .silent)
    }
    #expect(await !manager.connectionManager.isConnected)
    #expect(manager.workspace.connectionConfig == strict)

    try await manager.completePendingWeakeningConnect()
    #expect(manager.pendingWeakeningConnect == nil)
    #expect(await manager.connectionManager.isConnected)
    #expect(manager.workspace.connectionConfig == weak)
    #expect(await manager.connectionManager.connectedPolicy.protectionLevel == .none)
  }

  @Test("Strengthening the same DB connects immediately")
  func strengtheningConnectsImmediately() async throws {
    let current = Self.config(protectionLevel: .schemaOnly, safeMode: .safeRead)
    let stronger = Self.config(protectionLevel: .readOnly, safeMode: .safeAll)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: current), restoreTabs: false)
    defer { Task { await manager.disconnect() } }

    try await manager.connect(config: stronger, globalSafeMode: .silent)
    #expect(manager.pendingWeakeningConnect == nil)
    #expect(await manager.connectionManager.isConnected)
    #expect(await manager.connectionManager.connectedPolicy.protectionLevel == .readOnly)
  }

  @Test("Weakening from a non-password Safe Mode connects immediately")
  func nonPasswordModeConnectsImmediately() async throws {
    let current = Self.config(protectionLevel: .readOnly, safeMode: .alertAll)
    let weak = Self.config(protectionLevel: .none, safeMode: .silent)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: current), restoreTabs: false)
    defer { Task { await manager.disconnect() } }

    try await manager.connect(config: weak, globalSafeMode: .silent)
    #expect(await manager.connectionManager.isConnected)
    #expect(manager.workspace.connectionConfig == weak)
  }

  @Test("A different database connects immediately even when weaker")
  func differentDatabaseConnectsImmediately() async throws {
    var current = Self.config(protectionLevel: .readOnly, safeMode: .safeAll)
    current.database = "some_other_database"
    let weak = Self.config(protectionLevel: .none, safeMode: .silent)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: current), restoreTabs: false)
    defer { Task { await manager.disconnect() } }

    try await manager.connect(config: weak, globalSafeMode: .silent)
    #expect(await manager.connectionManager.isConnected)
    #expect(manager.workspace.connectionConfig == weak)
  }
}
