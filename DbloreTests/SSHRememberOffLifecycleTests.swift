// SSHRememberOffLifecycleTests.swift
// A remember-off SSH secret lives only in memory: it is re-supplied to every internal reconnect
// (Cancel, capped read, banner Reconnect, Safe Mode unlock), cleared on every disconnect or loss
// path, and never written to the credential store. No server: fake sessions record the secret
// a real session would read when it opens.

import Foundation
import Testing

@testable import Dblore

@Suite("SSH remember-off secret lifecycle")
@MainActor
struct SSHRememberOffLifecycleTests {
  private static let secret = SSHStoredCredential.password("held-only-in-memory")
  private static let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  /// A unique bastion per test: the test-host credential store is shared by the process.
  private static func config(
    style: CommitStyle = .immediate, protectionLevel: ConnectionProtectionLevel = .none
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      host: "fake", port: 1, database: "db", username: "u", password: "p",
      protectionLevel: protectionLevel)
    config.rememberConnection = false
    config.sshTunnel = SSHTunnelConfig(
      host: "bastion-\(UUID().uuidString).example", username: "jump")
    config.applyCommitStyle(style)
    return config
  }

  private static func scoped(
    _ config: ConnectionConfig
  ) -> SSHCredentialStoreFactory.ScopedSSHCredential {
    SSHCredentialStoreFactory.scoped(secret, for: config)!
  }

  private static func held(
    _ config: ConnectionConfig
  ) -> SSHCredentialStoreFactory.ConnectionCredential {
    .init(account: SSHCredentialStoreFactory.account(for: config)!, credential: secret)
  }

  private static func stored(_ config: ConnectionConfig) -> SSHStoredCredential? {
    SSHCredentialStoreFactory.shared.load(account: SSHCredentialStoreFactory.account(for: config)!)
  }

  /// Connects `manager` with the form's secret in scope, the way Connect does.
  private static func connect(
    _ manager: DatabaseConnectionManager, _ config: ConnectionConfig
  ) async throws {
    let scoped = Self.scoped(config)
    defer { scoped.clear() }
    try await SSHCredentialStoreFactory.$operationCredential.withValue(scoped) {
      try await manager.connect(config: config)
    }
  }

  // MARK: - Connection actor

  @Test("Connect holds the secret in memory only; disconnect drops it")
  func connectHoldsThenDisconnectClears() async throws {
    let factory = SSHCredentialRecordingFactory(.init(capabilities: .contract()))
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = Self.config()
    try await Self.connect(manager, config)

    #expect(factory.credentials == [Self.secret])
    #expect(await manager.activeUnrememberedSSHCredential == Self.held(config))
    #expect(Self.stored(config) == nil)

    await manager.disconnect()
    #expect(await manager.activeUnrememberedSSHCredential == nil)
  }

  @Test("Cancel reconnects with the held secret")
  func cancelReSupplies() async throws {
    let fake = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: .reconnect), slowQueries: true)
    let factory = SSHCredentialRecordingFactory(fake)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = Self.config()
    try await Self.connect(manager, config)
    let session = try #require(fake.sessions.first)

    let running = Task { try await manager.execute(userSQL: "SELECT 1", policy: Self.open) }
    await session.waitUntilQueryStarted()
    let status = await manager.runningStatementStatus()
    let outcome = await manager.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    // The fake's slow read ends only on interrupt (a real server ends it with the closed session).
    await session.interrupt()
    _ = try? await running.value

    #expect(outcome == .cancelled)
    #expect(factory.credentials == [Self.secret, Self.secret])
    #expect(await manager.isConnected)
    #expect(await manager.activeUnrememberedSSHCredential == Self.held(config))
    #expect(Self.stored(config) == nil)
    await manager.disconnect()
  }

  @Test("A capped read reconnects with the held secret")
  func cappedReadReSupplies() async throws {
    let fake = FakeDatabaseSessionFactory(
      capabilities: .contract(), columns: [ColumnInfo(name: "id", type: "INTEGER")],
      rows: (1...5).map { [CellValue.int($0)] })
    let factory = SSHCredentialRecordingFactory(fake)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = Self.config()
    try await Self.connect(manager, config)

    let read = try await manager.execute(
      userSQL: "SELECT * FROM t", policy: Self.open, maxRows: 2)

    #expect(read.sessionReset)
    #expect(factory.credentials == [Self.secret, Self.secret])
    #expect(await manager.activeUnrememberedSSHCredential == Self.held(config))
    await manager.disconnect()
  }

  @Test("A session the server closed drops the held secret")
  func sessionLossClears() async throws {
    let fake = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(
      sessionFactory: SSHCredentialRecordingFactory(fake))
    try await Self.connect(manager, Self.config())
    let session = try #require(fake.sessions.first)

    session.emit(.connectionLost)
    try await waitUntil { await !manager.isConnected }
    #expect(await manager.activeUnrememberedSSHCredential == nil)
  }

  // MARK: - Workspace

  private static func workspace(
    _ factory: SSHCredentialRecordingFactory, config: ConnectionConfig? = nil
  ) -> WorkspaceManager {
    WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(sessionFactory: factory))
  }

  /// Workspace connect with the form's secret in scope.
  private static func connect(_ manager: WorkspaceManager, _ config: ConnectionConfig) async throws
  {
    let scoped = Self.scoped(config)
    defer { scoped.clear() }
    try await SSHCredentialStoreFactory.$operationCredential.withValue(scoped) {
      try await manager.connect(
        config: config, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false)
    }
  }

  @Test("Workspace connect holds the secret; Disconnect drops it and nothing is stored")
  func workspaceDisconnectClears() async throws {
    let factory = SSHCredentialRecordingFactory(.init(capabilities: .contract()))
    let manager = Self.workspace(factory)
    let config = Self.config()
    try await Self.connect(manager, config)

    #expect(manager.activeUnrememberedSSHCredential == Self.held(config))
    #expect(Self.stored(config) == nil)
    await manager.performDisconnect()
    #expect(manager.activeUnrememberedSSHCredential == nil)
    #expect(await manager.connectionManager.activeUnrememberedSSHCredential == nil)
  }

  @Test("A lost connection keeps the secret for banner Reconnect; dismissing drops it")
  func lossReconnectAndDismiss() async throws {
    let fake = FakeDatabaseSessionFactory(capabilities: .contract())
    let factory = SSHCredentialRecordingFactory(fake)
    let manager = Self.workspace(factory)
    let config = Self.config()
    try await Self.connect(manager, config)

    try #require(fake.sessions.last).emit(.connectionLost)
    try await waitUntil { manager.connectionLostMessage != nil }
    #expect(manager.activeUnrememberedSSHCredential == Self.held(config))

    await manager.reconnectAfterConnectionLoss()
    #expect(await manager.connectionManager.isConnected)
    #expect(factory.credentials == [Self.secret, Self.secret])
    #expect(manager.activeUnrememberedSSHCredential == Self.held(config))

    try #require(fake.sessions.last).emit(.connectionLost)
    try await waitUntil { manager.connectionLostMessage != nil }
    manager.dismissConnectionLost()
    #expect(manager.activeUnrememberedSSHCredential == nil)
    #expect(Self.stored(config) == nil)
  }

  @Test("Closing the workspace drops the active and the pending secret")
  func releaseFileAccessClears() {
    let config = Self.config()
    let manager = Self.workspace(SSHCredentialRecordingFactory(.init(capabilities: .contract())))
    manager.activeUnrememberedSSHCredential = Self.held(config)
    manager.pendingWeakeningSSHCredential = Self.secret
    manager.releaseFileAccess()
    #expect(manager.activeUnrememberedSSHCredential == nil)
    #expect(manager.pendingWeakeningSSHCredential == nil)
  }

  @Test("The Safe Mode unlock connects with the held secret; cancelling the unlock drops it")
  func safeModeUnlockReSupplies() async throws {
    let strict = Self.config(style: .review, protectionLevel: .readOnly)
    var weak = strict
    weak.protectionLevel = .none
    weak.applyCommitStyle(.immediate)
    let factory = SSHCredentialRecordingFactory(.init(capabilities: .contract()))
    let manager = Self.workspace(factory, config: strict)

    let scoped = Self.scoped(weak)
    await SSHCredentialStoreFactory.$operationCredential.withValue(scoped) {
      await #expect(throws: WorkspaceConnectError.unlockRequired) {
        try await manager.connect(
          config: weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
      }
    }
    scoped.clear()
    #expect(manager.pendingWeakeningSSHCredential == Self.secret)
    manager.cancelPendingWeakeningConnect()
    #expect(manager.pendingWeakeningSSHCredential == nil)

    let again = Self.scoped(weak)
    await SSHCredentialStoreFactory.$operationCredential.withValue(again) {
      _ = try? await manager.connect(
        config: weak, defaultCommitStyle: .review, hasPassword: true, hasTouchID: false)
    }
    again.clear()
    try await manager.completePendingWeakeningConnect()

    #expect(factory.credentials == [Self.secret])
    #expect(manager.pendingWeakeningSSHCredential == nil)
    #expect(manager.activeUnrememberedSSHCredential == Self.held(weak))
    #expect(Self.stored(weak) == nil)
    await manager.performDisconnect()
  }
}

/// Records the SSH secret a session would read (`SSHCredentialStoreFactory.load(for:)`) each
/// time one is made; `makeSession` runs inside the connect's task-local scope.
private final class SSHCredentialRecordingFactory: DatabaseSessionFactory, @unchecked Sendable {
  private let inner: FakeDatabaseSessionFactory
  private let lock = NSLock()
  private var loaded: [SSHStoredCredential?] = []

  init(_ inner: FakeDatabaseSessionFactory) {
    self.inner = inner
  }

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    let credential = SSHCredentialStoreFactory.load(for: config)
    lock.withLock { loaded.append(credential) }
    return inner.makeSession(config: config)
  }

  var credentials: [SSHStoredCredential?] { lock.withLock { loaded } }
}

/// Polls until `condition` holds (fails after 5 s).
@MainActor
private func waitUntil(_ condition: () async -> Bool) async throws {
  let end = ContinuousClock.now + .seconds(5)
  while await !condition() {
    guard ContinuousClock.now < end else {
      Issue.record("condition not met in time")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}
