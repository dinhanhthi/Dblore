// MCPConnectionPool.swift
// One `DatabaseConnectionManager` per saved connection MCP uses, on read-only sessions
// (`MCPReadOnlySessionFactory`), never the workspace's manager. Nothing here prompts: a
// connection that would need the user (no saved client certificate or SSH secret, or an SSH
// host key not pinned yet) is refused. An empty password is sent as is (trust or
// passwordless auth works; a wrong one fails with the server's error). Statements stop after
// at most `statementTimeoutSeconds` (the session brake). Managers unused for `idleTimeout`
// are disconnected, and so is one that lost its session or whose connection was edited (once
// its running reads finish). A failed connect is reported as `MCPConnectionError.connectFailed`,
// without the server's text.

import Foundation

actor MCPConnectionPool {
  /// The saved connection for an id, its password loaded from the Keychain; nil when unknown.
  typealias EntryLookup = @Sendable (UUID) async -> ConnectionHistoryEntry?

  /// Server-side statement timeout of MCP sessions; a shorter one of the connection is kept
  static let statementTimeoutSeconds = 30
  /// What an MCP read keeps: cells cut for the encoder as rows arrive, at most 4 MiB of cells
  static let readLimits = CappedReadLimits(
    maxCellCharacters: MCPResultEncoder.maxCellCharacters, maxResultBytes: 4 * 1_024 * 1_024)

  private nonisolated struct Pooled: Sendable {
    /// Tells this manager apart from a later one for the same id
    let token = UUID()
    /// The saved config this manager was built from (before the MCP timeout), to spot edits
    let config: ConnectionConfig
    let connecting: Task<DatabaseConnectionManager, Error>
    var inUse = 0
    var lastUsed: ContinuousClock.Instant
  }

  private let entry: EntryLookup
  private let sessionFactory: any DatabaseSessionFactory
  private let certificates: any ClientCertificateStore
  private let sshCredentials: any SSHCredentialStore
  private let knownHosts: any SSHKnownHostStore
  private let idleTimeout: Duration
  private let now: @Sendable () -> ContinuousClock.Instant
  private var pooled: [UUID: Pooled] = [:]
  /// Managers replaced while in use (connection edited), by token; disconnected when the last
  /// caller releases them
  private var retired: [UUID: Pooled] = [:]
  private var sweep: Task<Void, Never>?
  /// Set by `closeAll`: the pool refuses new callers (a restarted server builds a new pool)
  private var closed = false

  /// `sessionFactory` nil: the app's sessions, where an SSH host key that is not pinned in
  /// `knownHosts` is rejected without a prompt.
  init(
    entry: @escaping EntryLookup,
    sessionFactory: (any DatabaseSessionFactory)? = nil,
    certificates: any ClientCertificateStore = ClientCertificateStoreFactory.shared,
    sshCredentials: any SSHCredentialStore = SSHCredentialStoreFactory.shared,
    knownHosts: any SSHKnownHostStore = SSHKnownHostStoreFactory.shared,
    idleTimeout: Duration = .seconds(300),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.entry = entry
    self.sessionFactory = MCPReadOnlySessionFactory(
      inner: sessionFactory
        ?? AppDatabaseSessionFactory(
          hostKeyValidator: SSHHostKeyPolicy(store: knownHosts, prompt: RejectingSSHHostKeyPrompt())
        ))
    self.certificates = certificates
    self.sshCredentials = sshCredentials
    self.knownHosts = knownHosts
    self.idleTimeout = idleTimeout
    self.now = now
  }

  deinit {
    sweep?.cancel()
  }

  /// Runs `body` with the connection's manager, connecting it first when needed. Concurrent
  /// callers share one manager; it is not closed as idle while a `body` runs. A connection
  /// edited since it connected is reconnected with its new settings (a reader of the old
  /// manager finishes first); one that lost its session is rebuilt.
  /// - Throws: `MCPConnectionError` when the connection is unknown or would need a prompt,
  ///   `.connectFailed`, or `.stopped` after `closeAll`.
  func withManager<T: Sendable>(
    for entryID: UUID, _ body: @Sendable (DatabaseConnectionManager) async throws -> T
  ) async throws -> T {
    let (manager, token) = try await acquire(entryID)
    do {
      let result = try await body(manager)
      await release(entryID, token: token)
      return result
    } catch {
      await release(entryID, token: token)
      throw error
    }
  }

  /// Disconnect every manager unused for `idleTimeout`.
  func closeIdle() async {
    let instant = now()
    let idle = pooled.filter { $0.value.inUse == 0 && instant - $0.value.lastUsed >= idleTimeout }
    for id in idle.keys { pooled[id] = nil }
    for item in idle.values { await Self.disconnect(item) }
  }

  /// Disconnect the connection's manager (removed from the allowlist); one in use is retired
  /// and closes when its last caller is done. A later caller connects again.
  func close(id: UUID) async {
    guard let open = pooled.removeValue(forKey: id) else { return }
    if open.inUse > 0 {
      retired[open.token] = open
    } else {
      await Self.disconnect(open)
    }
  }

  /// Disconnect every manager and refuse new callers (MCP server stopped).
  func closeAll() async {
    closed = true
    sweep?.cancel()
    sweep = nil
    let all = Array(pooled.values) + Array(retired.values)
    pooled.removeAll()
    retired.removeAll()
    for item in all { await Self.disconnect(item) }
  }

  private func acquire(_ id: UUID) async throws -> (DatabaseConnectionManager, UUID) {
    guard !closed else { throw MCPConnectionError.stopped }
    guard let entry = await entry(id) else { throw MCPConnectionError.unknownConnection }
    if let open = pooled[id], open.config != entry.config {
      pooled[id] = nil
      if open.inUse > 0 {
        retired[open.token] = open
      } else {
        await Self.disconnect(open)
      }
    }
    // Checked after the awaits above: a manager built now would outlive `closeAll`
    guard !closed else { throw MCPConnectionError.stopped }
    if pooled[id] == nil {
      try refuseUnattended(entry.config)
      var config = entry.config
      config.statementTimeoutSeconds = min(
        config.statementTimeoutSeconds ?? Self.statementTimeoutSeconds,
        Self.statementTimeoutSeconds)
      let factory = sessionFactory
      pooled[id] = Pooled(
        config: entry.config,
        connecting: Task {
          let manager = DatabaseConnectionManager(
            sessionFactory: factory, readLimits: Self.readLimits)
          try await manager.connect(config: config)
          return manager
        }, lastUsed: now())
      startSweep()
    }
    guard var item = pooled[id] else { throw MCPConnectionError.unknownConnection }
    item.inUse += 1
    item.lastUsed = now()
    pooled[id] = item
    let manager: DatabaseConnectionManager
    do {
      manager = try await item.connecting.value
    } catch {
      await release(id, token: item.token)
      if pooled[id]?.token == item.token { pooled[id] = nil }
      throw (error as? MCPConnectionError) ?? MCPConnectionError.connectFailed
    }
    guard await manager.isConnected else {
      // The session was lost (server closed it, a reset failed): build a new manager. One
      // still used by another caller (maybe mid-reset) is retired, not closed under it. A
      // fresh connect either throws or is connected, so this recursion ends.
      await release(id, token: item.token)
      if let open = pooled[id], open.token == item.token {
        pooled[id] = nil
        if open.inUse > 0 {
          retired[open.token] = open
        } else {
          await manager.disconnect()
        }
      }
      return try await acquire(id)
    }
    return (manager, item.token)
  }

  /// One caller is done with the manager `token`. A retired manager is disconnected once its
  /// last caller is done.
  private func release(_ id: UUID, token: UUID) async {
    if var item = pooled[id], item.token == token {
      item.inUse -= 1
      item.lastUsed = now()
      pooled[id] = item
    } else if var item = retired[token] {
      item.inUse -= 1
      retired[token] = item.inUse > 0 ? item : nil
      if item.inUse == 0 { await Self.disconnect(item) }
    }
  }

  /// Refuses what would otherwise fail on a missing secret or wait for a trust prompt, and a
  /// password command: an MCP client must not run the user's scripts.
  /// Reads the Keychain stores here, off the main actor.
  private func refuseUnattended(_ config: ConnectionConfig) throws {
    if config.passwordCommandScript != nil, config.databaseType.capabilities.usesPassword {
      throw MCPConnectionError.passwordCommand
    }
    if config.clientCertificate != nil,
      certificates.load(account: ClientCertificateStoreFactory.account(for: config)) == nil
    {
      throw MCPConnectionError.certificateNotSaved
    }
    if let tunnel = config.sshTunnel {
      guard let account = SSHCredentialStoreFactory.account(for: config),
        sshCredentials.load(account: account) != nil
      else { throw MCPConnectionError.sshCredentialNotSaved }
      guard (try? knownHosts.lookup(host: tunnel.host, port: tunnel.port)) != nil else {
        throw MCPConnectionError.sshHostKeyNotTrusted
      }
    }
  }

  private func startSweep() {
    guard sweep == nil else { return }
    let interval = idleTimeout / 5
    sweep = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self else { return }
        await self.closeIdle()
      }
    }
  }

  private static func disconnect(_ item: Pooled) async {
    guard let manager = try? await item.connecting.value else { return }
    await manager.disconnect()
  }
}
