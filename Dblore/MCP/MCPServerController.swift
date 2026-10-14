// MCPServerController.swift
// Runs the MCP server from the settings: started at launch only while `mcpEnabled`, restarted
// on a port change or a new token, stopped when disabled and on quit. Each start builds a new
// pool, tool service and listener (a closed pool refuses, the listener's handler is fixed).
// Transitions run one at a time. An allowlist change needs no restart: the service reads the
// allowlist on every call, and the pool closes the managers of removed connections.
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
  @ObservationIgnored private var running: Running?
  @ObservationIgnored private var cachedToken: String?
  /// The allowlist the running pool was last told about
  @ObservationIgnored private var allowed: Set<UUID> = []
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
    sessionFactory: (any DatabaseSessionFactory)? = nil
  ) {
    self.settings = settings
    self.tokens = tokens
    self.savedConnections = savedConnections
    self.password = password
    self.recorder = recorder
    self.requestTimeout = requestTimeout
    self.sessionFactory = sessionFactory
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
      _ = (settings.mcpEnabled, settings.mcpPort, settings.mcpAllowedConnectionIDs)
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
    if let running {
      for id in allowed.subtracting(allowlist) { await running.pool.close(id: id) }
    }
    allowed = allowlist
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
        settings: settings, savedConnections: savedConnections, password: password),
      sessionFactory: sessionFactory)
    let service = Self.makeService(
      pool: pool, settings: settings, savedConnections: savedConnections, recorder: recorder)
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

  private func stopRunning() async {
    guard let running else { return }
    self.running = nil
    await running.server.stop()
    await running.pool.closeAll()
  }

  private static func message(for error: Error, port: Int) -> String {
    if let error = error as? IOError, error.errnoCode == EADDRINUSE {
      return "Port \(port) is already in use. Choose another port."
    }
    return "The MCP server could not start on port \(port): \(error.localizedDescription)"
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

  /// The pool's lookup: an allowlisted entry with its password, read off the main actor.
  private nonisolated static func entryLookup(
    settings: AppSettings,
    savedConnections: @escaping @MainActor @Sendable () -> [ConnectionHistoryEntry],
    password: @escaping @Sendable (ConnectionConfig) -> String?
  ) -> MCPConnectionPool.EntryLookup {
    { id in
      let entries = await allowedEntries(settings: settings, savedConnections: savedConnections)
      guard var entry = entries.first(where: { $0.id == id }) else { return nil }
      if entry.config.databaseType.capabilities.usesPassword, let saved = password(entry.config) {
        entry.config.password = saved
      }
      return entry
    }
  }

  private nonisolated static func makeService(
    pool: MCPConnectionPool, settings: AppSettings,
    savedConnections: @escaping @MainActor @Sendable () -> [ConnectionHistoryEntry],
    recorder: any QueryHistoryRecording
  ) -> MCPToolService {
    MCPToolService(
      connections: {
        await allowedEntries(settings: settings, savedConnections: savedConnections)
      },
      allowlist: { await MainActor.run { settings.mcpAllowedConnectionIDs } },
      source: MCPSQLReadSource(pool: pool),
      recorder: MCPNotifyingHistoryRecorder(inner: recorder),
      historyEnabled: { await MainActor.run { settings.historyEnabled } },
      defaultMaxRows: { await MainActor.run { settings.mcpRowCap } })
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
