// MCPServerController.swift
// Runs the MCP server from the settings: started at launch only while `mcpEnabled`, restarted
// on a port change or a new token, stopped when disabled and on quit. Each start builds a new
// pool, tool service and listener (a closed pool refuses, the listener's handler is fixed).
// Transitions run one at a time. An allowlist or write settings change needs no restart: the
// service reads them on every call, and the pool closes the managers of removed connections and
// the writable managers of connections that lost their write scope (or all of them when write
// tools are turned off). Write approvals go to `MCPWriteApprovalCenter`; the waiting ones of
// those connections are denied (all of them when write tools or MCP are turned off and when the
// server stops or restarts, as for a new token), and the service checks the settings again
// after an approval.
// A locked connection is never served, even after the user unlocked it in the app: the pool's
// lookup does not know it and the service does not list it (`lockSource`).
// Nothing here blocks the main actor: the Keychain (token, passwords) is read off main; the
// main actor is used only to read the settings and the saved connections.

import Foundation
import NIOCore

@MainActor
@Observable
final class MCPServerController {
  enum Status: Equatable {
    case stopped
    case starting
    case running(port: Int)
    /// Why the server could not start (a port in use); never holds the token
    case failed(String)
  }

  static let shared = MCPServerController()

  private(set) var status = Status.stopped

  private nonisolated struct Running: Sendable {
    let server: MCPHTTPServer
    let pool: MCPConnectionPool
    let port: Int
    let token: String
  }

  @ObservationIgnored private let settings: AppSettings
  @ObservationIgnored private let tokens: any MCPTokenStore
  @ObservationIgnored private let savedConnections:
    @MainActor @Sendable () -> [ConnectionHistoryEntry]
  @ObservationIgnored private let password: @Sendable (ConnectionConfig) -> String?
  @ObservationIgnored private let recorder: any QueryHistoryRecording
  @ObservationIgnored private let sessionFactory: (any DatabaseSessionFactory)?
  @ObservationIgnored private let requestTimeout: Duration
  @ObservationIgnored private let approver: any MCPWriteApproving
  @ObservationIgnored private let lockSource: LockRegistry
  @ObservationIgnored private var running: Running?
  @ObservationIgnored private var cachedToken: String?
  /// The allowlist the running pool was last told about
  @ObservationIgnored private var allowed: Set<UUID> = []
  /// Ids the running pool may keep a writable manager for (write tools on, a write scope)
  @ObservationIgnored private var writable: Set<UUID> = []
  @ObservationIgnored private var transition: Task<Void, Never>?
  @ObservationIgnored private var isActive = false
  /// Bumped by `activate`, so an observation armed before a stop never re-arms
  @ObservationIgnored private var observation = 0

  /// `savedConnections`: the saved connections without passwords. `password`: a connection's
  /// saved password, called off the main actor (nothing under the test host).
  /// `sessionFactory`: the pool's sessions, nil for the app's.
  init(
    settings: AppSettings = .shared,
    tokens: any MCPTokenStore = MCPTokenStoreFactory.shared,
    savedConnections: @escaping @MainActor @Sendable () -> [ConnectionHistoryEntry] = {
      SessionManager.loadHistory(passwords: NoPasswordStore())
    },
    password: @escaping @Sendable (ConnectionConfig) -> String? = { config in
      SessionManager.isRunningAsTestHost
        ? nil
        : KeychainConnectionPasswordStore.loadPassword(
          forKey: ConnectionKeychainKey.password(for: config))
    },
    recorder: any QueryHistoryRecording = NotebookViewModel.defaultHistoryRecorder(),
    requestTimeout: Duration = MCPJSONRPC.defaultTimeout,
    sessionFactory: (any DatabaseSessionFactory)? = nil,
    approver: any MCPWriteApproving = MCPWriteApprovalCenter.shared,
    lockSource: LockRegistry = .shared
  ) {
    self.settings = settings
    self.tokens = tokens
    self.savedConnections = savedConnections
    self.password = password
    self.recorder = recorder
    self.requestTimeout = requestTimeout
    self.sessionFactory = sessionFactory
    self.approver = approver
    self.lockSource = lockSource
  }

  /// Follows the settings from now on: starts the server when enabled.
  func activate() {
    guard !isActive else { return }
    isActive = true
    observation += 1
    observeSettings(observation)
  }

  /// The bearer token clients send, created on first use.
  func token() async -> String {
    if let cachedToken { return cachedToken }
    let tokens = self.tokens
    let token = await Task.detached { tokens.loadOrCreate() }.value
    // A regenerate during the load wins
    if let cachedToken { return cachedToken }
    cachedToken = token
    return token
  }

  /// A new token; a running server restarts with it (clients need the new one).
  func regenerateToken() async {
    let tokens = self.tokens
    cachedToken = await Task.detached { tokens.regenerate() }.value
    await enqueue(restart: true).value
  }

  /// After the saved token was deleted: a running server restarts with a new one, saved then.
  func forgetToken() async {
    cachedToken = nil
    await enqueue(restart: true).value
  }

  /// Stops the server and stops following the settings (`activate` resumes).
  func stop() async {
    isActive = false
    let previous = transition
    let task = Task {
      await previous?.value
      await stopRunning()
      status = .stopped
    }
    transition = task
    await task.value
  }

  /// On quit: stops the listener and closes the pool, waiting at most `timeout` so quitting
  /// never hangs on a slow handler or database.
  func stopForQuit(timeout: Duration = .seconds(2)) {
    isActive = false
    guard let running else { return }
    self.running = nil
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      async let stopped: Void = running.server.stop()
      async let closed: Void = running.pool.closeAll()
      _ = await (stopped, closed)
      done.signal()
    }
    _ = done.wait(timeout: .now() + .milliseconds(Int(timeout / .milliseconds(1))))
  }

  private func observeSettings(_ generation: Int) {
    guard isActive, generation == observation else { return }
    withObservationTracking {
      _ = (
        settings.mcpEnabled, settings.mcpPort, settings.mcpAllowedConnectionIDs,
        settings.mcpWriteToolsEnabled, settings.mcpWriteScopes
      )
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeSettings(generation) }
    }
    enqueue(restart: false)
  }

  @discardableResult
  private func enqueue(restart: Bool) -> Task<Void, Never> {
    let previous = transition
    let task = Task {
      await previous?.value
      await apply(restart: restart)
    }
    transition = task
    return task
  }

  /// Brings the server in line with the settings.
  private func apply(restart: Bool) async {
    guard isActive else { return }
    let enabled = settings.mcpEnabled
    let port = settings.mcpPort
    let allowlist = settings.mcpAllowedConnectionIDs
    let writableNow = Self.writableIDs(settings: settings)
    if let running {
      for id in allowed.subtracting(allowlist) { await running.pool.close(id: id) }
      for id in writable.subtracting(writableNow) { await running.pool.closeWritable(id: id) }
    }
    // A waiting approval never outlives the scope it was asked under
    if !enabled || !settings.mcpWriteToolsEnabled {
      await approver.denyAllWaiting()
    } else {
      let narrowed = allowed.subtracting(allowlist).union(writable.subtracting(writableNow))
      if !narrowed.isEmpty { await approver.denyWaiting(connections: narrowed) }
    }
    allowed = allowlist
    writable = writableNow
    if let running, restart || !enabled || running.port != port {
      await stopRunning()
    }
    guard enabled else {
      status = .stopped
      return
    }
    guard running == nil else { return }
    status = .starting
    let token = await token()
    let pool = MCPConnectionPool(
      entry: Self.entryLookup(
        settings: settings, savedConnections: savedConnections, password: password,
        lockSource: lockSource),
      sessionFactory: sessionFactory, lockSource: lockSource)
    let service = Self.makeService(
      pool: pool, settings: settings, savedConnections: savedConnections, recorder: recorder,
      approver: approver, lockSource: lockSource)
    let server = MCPHTTPServer(
      handler: MCPJSONRPC.handler(tools: service, timeout: requestTimeout))
    do {
      let bound = try await server.start(.init(port: port, token: token))
      running = Running(server: server, pool: pool, port: bound, token: token)
      status = .running(port: bound)
    } catch is CancellationError {
      await pool.closeAll()
      status = .stopped
    } catch {
      await pool.closeAll()
      status = .failed(Self.message(for: error, port: port))
    }
  }

  /// Denies every waiting approval first: none outlives the server (and token) it came through.
  private func stopRunning() async {
    guard let running else { return }
    self.running = nil
    await approver.denyAllWaiting()
    await running.server.stop()
    await running.pool.closeAll()
  }

  private static func message(for error: Error, port: Int) -> String {
    if let error = error as? IOError, error.errnoCode == EADDRINUSE {
      return "Port \(port) is already in use. Choose another port."
    }
    return "The MCP server could not start on port \(port): \(error.localizedDescription)"
  }

  /// Allowlisted ids with a write scope while write tools are on.
  private static func writableIDs(settings: AppSettings) -> Set<UUID> {
    guard settings.mcpWriteToolsEnabled else { return [] }
    return Set(
      settings.mcpWriteScopes.filter { $0.value != .read }.keys
    ).intersection(settings.mcpAllowedConnectionIDs)
  }

  /// Saved connections on the allowlist, without passwords.
  private nonisolated static func allowedEntries(
    settings: AppSettings,
    savedConnections: @escaping @MainActor @Sendable () -> [ConnectionHistoryEntry]
  ) async -> [ConnectionHistoryEntry] {
    await MainActor.run {
      let allowed = settings.mcpAllowedConnectionIDs
      return savedConnections().filter { allowed.contains($0.id) }
    }
  }

  /// The pool's lookup: an allowlisted entry with its password, read off the main actor; nil
  /// for a locked one (any identity it reaches, unlocked in the app or not), before its password
  /// is read.
  nonisolated static func entryLookup(
    settings: AppSettings,
    savedConnections: @escaping @MainActor @Sendable () -> [ConnectionHistoryEntry],
    password: @escaping @Sendable (ConnectionConfig) -> String?, lockSource: LockRegistry
  ) -> MCPConnectionPool.EntryLookup {
    { id in
      let entries = await allowedEntries(settings: settings, savedConnections: savedConnections)
      guard var entry = entries.first(where: { $0.id == id }),
        !LockIdentity.all(entry.config).contains(where: lockSource.isLocked)
      else { return nil }
      if entry.config.databaseType.capabilities.usesPassword, let saved = password(entry.config) {
        entry.config.password = saved
      }
      return entry
    }
  }

  private nonisolated static func makeService(
    pool: MCPConnectionPool, settings: AppSettings,
    savedConnections: @escaping @MainActor @Sendable () -> [ConnectionHistoryEntry],
    recorder: any QueryHistoryRecording, approver: any MCPWriteApproving,
    lockSource: LockRegistry
  ) -> MCPToolService {
    MCPToolService(
      // Every saved row: their AI policies tighten an allowlisted one of the same identity. The
      // service lists and uses allowlisted ids only.
      connections: { await MainActor.run { savedConnections() } },
      allowlist: { await MainActor.run { settings.mcpAllowedConnectionIDs } },
      aiSettings: { AISettings.savedConfiguration(in: AppSettings.sharedDefaults) },
      source: MCPSQLReadSource(pool: pool),
      recorder: MCPNotifyingHistoryRecorder(inner: recorder),
      historyEnabled: { await MainActor.run { settings.historyEnabled } },
      defaultMaxRows: { await MainActor.run { settings.mcpRowCap } },
      writes: MCPWriteAccess(
        enabled: { await MainActor.run { settings.mcpWriteToolsEnabled } },
        scopes: { await MainActor.run { settings.mcpWriteScopes } },
        defaultCommitStyle: { await MainActor.run { settings.commitStyle } },
        approver: approver, source: MCPSQLWriteSource(pool: pool)),
      lockSource: lockSource)
  }
}

/// Records, then tells the History list to reload (as the editor's `onHistoryRecorded` does).
private nonisolated struct MCPNotifyingHistoryRecorder: QueryHistoryRecording {
  let inner: any QueryHistoryRecording

  func record(_ entry: QueryHistoryEntry) async {
    await inner.record(entry)
    LocalDataNotifications.post(.queryHistory)
  }
}
