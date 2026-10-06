// WorkspaceConnectUnlockTests.swift
// Reconnecting to the same database with a weaker resolved commit style needs the Safe Mode
// unlock when the old style is review or password and a password or Touch ID is configured.
// confirm → immediate does not. A different database or a stronger style connects immediately.
// Turning protectedMode off without applyCommitStyle is not a user-facing path.

import Foundation
import Testing

@testable import Dblore

@Suite("Workspace Connect Unlock Tests")
@MainActor
struct WorkspaceConnectUnlockTests {
  private static func styled(
    _ style: CommitStyle, host: String = "db.example.com", database: String = "app",
    username: String = "admin", protectionLevel: ConnectionProtectionLevel = .none
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      host: host, port: 5432, database: database, username: username, password: "pw",
      protectionLevel: protectionLevel)
    config.applyCommitStyle(style)
    return config
  }

  private static let strict = styled(.review, protectionLevel: .readOnly)
  private static let weak = styled(.immediate)

  // MARK: - Decision (pure)

  @Test("Same target, lowering review or password needs the unlock")
  func sameTargetWeakeningNeedsUnlock() {
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.password), new: Self.styled(.review),
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.strict, new: Self.weak,
        defaultCommitStyle: .review, hasPassword: false, hasTouchID: true))
  }

  @Test("Same target, password style, lowering the protection level needs the unlock")
  func sameTargetProtectionLevelNeedsUnlock() {
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.password, protectionLevel: .readOnly),
        new: Self.styled(.password, protectionLevel: .none),
        defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.review, protectionLevel: .readOnly),
        new: Self.styled(.review, protectionLevel: .none),
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: true))
  }

  @Test("Same target compared case-insensitively and ignoring surrounding spaces")
  func sameTargetCaseInsensitive() {
    let weakUpper = Self.styled(
      .confirm, host: " DB.Example.COM ", database: "APP", username: "Admin")
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.password), new: weakUpper,
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
  }

  @Test("Same target ignores one trailing dot on the host")
  func sameTargetTrailingDot() {
    let weakDot = Self.styled(.immediate, host: "db.example.com.")
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.review), new: weakDot,
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
  }

  @Test("Legacy unprotected nil safe mode uses the default commit style")
  func defaultStyleFallbackNeedsUnlock() {
    let current = ConnectionConfig(
      host: "db.example.com", port: 5432, database: "app", username: "admin", password: "pw",
      protectionLevel: .none, safeMode: nil, protectedMode: false)
    #expect(
      WorkspaceManager.connectRequiresUnlock(
        current: current, new: Self.styled(.confirm),
        defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
  }

  @Test("confirm → immediate connects without unlock")
  func confirmToImmediateNoUnlock() {
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.confirm, protectionLevel: .readOnly),
        new: Self.styled(.immediate),
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
  }

  @Test("Strengthening connects immediately")
  func strengtheningNoUnlock() {
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.confirm, protectionLevel: .schemaOnly),
        new: Self.styled(.password, protectionLevel: .readOnly),
        defaultCommitStyle: .review, hasPassword: true, hasTouchID: false))
  }

  @Test("A different database, host or user is a new connection: no unlock")
  func differentTargetNoUnlock() {
    for new in [
      Self.styled(.immediate, database: "other"),
      Self.styled(.immediate, host: "other.example.com"),
      Self.styled(.immediate, username: "reader"),
    ] {
      #expect(
        !WorkspaceManager.connectRequiresUnlock(
          current: Self.styled(.password), new: new,
          defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
    }
    var otherPort = Self.weak
    otherPort.port = 6543
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.password), new: otherPort,
        defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
  }

  @Test("No password and no Touch ID: a weaker style is not gated")
  func noUnlockConfiguredNoUnlock() {
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: Self.styled(.password), new: Self.weak,
        defaultCommitStyle: .review, hasPassword: false, hasTouchID: false))
  }

  @Test("No current config: no unlock")
  func noCurrentNoUnlock() {
    #expect(
      !WorkspaceManager.connectRequiresUnlock(
        current: nil, new: Self.weak,
        defaultCommitStyle: .password, hasPassword: true, hasTouchID: false))
  }

  // MARK: - Deferred connect (no database needed)

  @Test("Weakening connect is deferred: not connected, config unchanged, pending set")
  func weakeningConnectDeferred() async {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.strict), restoreTabs: false)
    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.connect(
        config: Self.weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
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
    _ = try? await manager.connect(
      config: Self.weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
    manager.cancelPendingWeakeningConnect()
    #expect(manager.pendingWeakeningConnect == nil)
    #expect(manager.workspace.connectionConfig == Self.strict)
    #expect(await !manager.connectionManager.isConnected)
  }

  @Test("Cancelling an unlock also drops its pending private key")
  func cancelPendingCertificate() async {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.strict), restoreTabs: false)
    let material = ClientCertificateMaterial(certificatePEM: "draft", privateKeyPEM: "draft-key")
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(
      account: ClientCertificateStoreFactory.account(for: Self.weak), material: material)
    await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      await #expect(throws: WorkspaceConnectError.unlockRequired) {
        try await manager.connect(
          config: Self.weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
      }
    }
    scoped.clear()
    #expect(manager.pendingWeakeningCertificate == material)
    manager.cancelPendingWeakeningConnect()
    #expect(manager.pendingWeakeningCertificate == nil)
    #expect(scoped.material == nil)
  }

  @Test("Closing a lost workspace releases its ephemeral certificate")
  func closingLostWorkspaceReleasesCertificate() {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.weak), restoreTabs: false)
    let material = ClientCertificateMaterial(certificatePEM: "draft", privateKeyPEM: "draft-key")
    manager.activeUnrememberedCertificate = .init(
      account: ClientCertificateStoreFactory.account(for: Self.weak), material: material)
    manager.releaseFileAccess()
    #expect(manager.activeUnrememberedCertificate == nil)
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

@Suite("Workspace Connect Unlock - Integration (Requires PostgreSQL)", .requiresPostgres)
@MainActor
struct WorkspaceConnectUnlockIntegrationTests {
  private static func styled(
    _ style: CommitStyle, protectionLevel: ConnectionProtectionLevel,
    database: String = TestDatabase.database
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      rememberConnection: false,
      timeoutSeconds: 30,
      protectionLevel: protectionLevel
    )
    config.applyCommitStyle(style)
    return config
  }

  @Test("Same DB weakened: deferred until unlock, then connects with the new config")
  func deferredThenConnects() async throws {
    let strict = Self.styled(.password, protectionLevel: .readOnly)
    let weak = Self.styled(.review, protectionLevel: .readOnly)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: strict), restoreTabs: false)
    defer { Task { await manager.disconnect() } }

    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.connect(
        config: weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
    }
    #expect(await !manager.connectionManager.isConnected)
    #expect(manager.workspace.connectionConfig == strict)

    try await manager.completePendingWeakeningConnect()
    #expect(manager.pendingWeakeningConnect == nil)
    #expect(await manager.connectionManager.isConnected)
    #expect(manager.workspace.connectionConfig == weak)
    #expect(await manager.connectionManager.connectedPolicy.protectionLevel == .readOnly)
  }

  @Test("Strengthening the same DB connects immediately")
  func strengtheningConnectsImmediately() async throws {
    let current = Self.styled(.confirm, protectionLevel: .schemaOnly)
    let stronger = Self.styled(.password, protectionLevel: .readOnly)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: current), restoreTabs: false)
    defer { Task { await manager.disconnect() } }

    try await manager.connect(config: stronger, defaultCommitStyle: .immediate)
    #expect(manager.pendingWeakeningConnect == nil)
    #expect(await manager.connectionManager.isConnected)
    #expect(await manager.connectionManager.connectedPolicy.protectionLevel == .readOnly)
  }

  @Test("confirm → immediate connects immediately even when a password is configured")
  func confirmToImmediateConnectsImmediately() async throws {
    let current = Self.styled(.confirm, protectionLevel: .readOnly)
    let weak = Self.styled(.immediate, protectionLevel: .none)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: current), restoreTabs: false)
    defer { Task { await manager.disconnect() } }

    try await manager.connect(
      config: weak, defaultCommitStyle: .immediate, hasPassword: true, hasTouchID: false)
    #expect(await manager.connectionManager.isConnected)
    #expect(manager.workspace.connectionConfig == weak)
  }

  @Test("A different database connects immediately even when weaker")
  func differentDatabaseConnectsImmediately() async throws {
    let current = Self.styled(
      .password, protectionLevel: .readOnly, database: "some_other_database")
    let weak = Self.styled(.immediate, protectionLevel: .none)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: current), restoreTabs: false)
    defer { Task { await manager.disconnect() } }

    try await manager.connect(
      config: weak, defaultCommitStyle: .immediate, hasPassword: true, hasTouchID: false)
    #expect(await manager.connectionManager.isConnected)
    #expect(manager.workspace.connectionConfig == weak)
  }
}
