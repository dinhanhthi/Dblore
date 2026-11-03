// WorkspaceConnectionLossReconnectTests.swift
// An ask-on-connect password lives in memory only: after a session loss the workspace holds the
// typed password for the banner's Reconnect, which connects without asking again; dismissing
// the banner drops it. It is never written to the Keychain. No server: fake sessions record the
// password a real session would send.

import Foundation
import Testing

@testable import Dblore

@Suite("Ask on connect: Reconnect after a session loss")
@MainActor
struct WorkspaceConnectionLossReconnectTests {
  private static func askConfig(password: String) -> ConnectionConfig {
    var config = ConnectionConfig(
      host: "ask-\(UUID().uuidString).example", port: 1, database: "db", username: "u",
      password: password)
    config.askPasswordOnConnect = true
    config.applyCommitStyle(.immediate)
    return config
  }

  @Test("Reconnect uses the held typed password with no prompt; dismissing the banner drops it")
  func reconnectUsesHeldPasswordAndDismissClears() async throws {
    let suite = "WorkspaceConnectionLossReconnectTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = RecordingConnectionPasswordStore()
    let factory = LossPasswordRecordingFactory()
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: nil), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(sessionFactory: factory),
      defaults: defaults, passwords: store, sanitizesFileConfig: false)

    try await manager.connect(
      config: Self.askConfig(password: "typed"), defaultCommitStyle: .immediate,
      hasPassword: false, hasTouchID: false)
    #expect(store.savedKeys.isEmpty)

    try #require(factory.inner.sessions.last).emit(.connectionLost)
    _ = await boundedWait("connection-lost banner") { @MainActor in
      await lossObserved { manager.connectionLostMessage != nil }
    }
    #expect(manager.activeTypedPassword == "typed")
    #expect(manager.workspace.connectionConfig?.password == "")

    await manager.reconnectAfterConnectionLoss()
    #expect(await manager.connectionManager.isConnected)
    #expect(factory.passwords == ["typed", "typed"])
    #expect(store.savedKeys.isEmpty)

    try #require(factory.inner.sessions.last).emit(.connectionLost)
    _ = await boundedWait("connection-lost banner") { @MainActor in
      await lossObserved { manager.connectionLostMessage != nil }
    }
    manager.dismissConnectionLost()
    #expect(manager.activeTypedPassword == nil)
    #expect(manager.workspace.connectionConfig?.password == "")
    #expect(manager.editingConnectionConfig.password == "")

    // With the held copy gone, a connect of the workspace config is refused, never sent empty
    let dropped = try #require(manager.workspace.connectionConfig)
    await #expect {
      try await manager.connect(
        config: dropped, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false)
    } throws: {
      if case .passwordRequiredOnConnect = $0 as? DatabaseError { return true }
      return false
    }
    #expect(factory.passwords == ["typed", "typed"])
    #expect(store.savedKeys.isEmpty)
  }

  @Test("A failed connect leaves no typed password in the workspace's configs")
  func failedConnectDropsTypedPassword() async throws {
    let suite = "WorkspaceConnectionLossReconnectTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: nil), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(sessionFactory: LossPasswordRecordingFactory()),
      defaults: defaults, passwords: RecordingConnectionPasswordStore(),
      sanitizesFileConfig: false)
    try await manager.connect(
      config: Self.askConfig(password: "typed"), defaultCommitStyle: .immediate,
      hasPassword: false, hasTouchID: false)
    #expect(manager.workspace.connectionConfig?.password == "typed")

    await #expect(throws: DatabaseError.self) {
      try await manager.connect(
        config: Self.askConfig(password: ""), defaultCommitStyle: .immediate,
        hasPassword: false, hasTouchID: false)
    }
    #expect(manager.connectionState == .disconnected)
    #expect(manager.workspace.connectionConfig?.password == "")
    #expect(manager.editingConnectionConfig.password == "")
  }
}

/// Records the password of every session it makes.
private final class LossPasswordRecordingFactory: DatabaseSessionFactory, @unchecked Sendable {
  let inner = FakeDatabaseSessionFactory(capabilities: .contract())
  private let lock = NSLock()
  private var recorded: [ConnectionConfig] = []

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    lock.withLock { recorded.append(config) }
    return inner.makeSession(config: config)
  }

  @MainActor var passwords: [String] { lock.withLock { recorded }.map(\.password) }
}

/// Returns once `condition` holds, re-checked on each observed change (no polling), or once
/// cancelled. Await it through `boundedWait`.
@MainActor
private func lossObserved(_ condition: () -> Bool) async {
  while !Task.isCancelled {
    let (changes, continuation) = AsyncStream<Void>.makeStream()
    let satisfied = withObservationTracking {
      condition()
    } onChange: {
      continuation.finish()
    }
    if satisfied { return }
    for await _ in changes {}
  }
}
