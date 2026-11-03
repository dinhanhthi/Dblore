//
//  WorkspaceManager+WriteUnlock.swift
//  Dblore
//
//  Timed write unlock of a Read-only connection, for this session only: after the Safe Mode
//  authentication, data writes run for 1 or 5 minutes (the gate lowers Read-only to Schema only,
//  so schema changes stay blocked). Nothing is saved or written to the connection config. It
//  ends on expiry, Lock now, a relock (`LockRegistry.didRelock`), a disconnect, a session reset
//  and a new connect. MCP managers never get one.
//

import Foundation

/// How long a write unlock lasts
enum WriteUnlockDuration: Int, CaseIterable, Hashable, Sendable {
  case oneMinute = 1
  case fiveMinutes = 5

  var seconds: TimeInterval { TimeInterval(rawValue * 60) }
  var title: String { "\(rawValue) min" }
}

/// What `WriteUnlockController.requestUnlock` did
enum WriteUnlockRequest: Equatable, Sendable {
  case started
  /// Touch ID did not unlock (off, unavailable or cancelled): the Safe Mode sheet verifies, then
  /// `start` runs
  case needsPassword
  /// The connection cannot be unlocked (`ProtectionPolicy.writeUnlockRefusal`, or the actor
  /// refused it)
  case refused
}

/// The write unlock of a workspace's connection. The connection actor holds the same expiry and
/// is the gate (`DatabaseConnectionManager.connectedPolicy`); this side drives the countdown, the
/// tabs' caller policy (`NotebookViewModel.protectionPolicy`) and the end events.
@MainActor
@Observable
final class WriteUnlockController {
  /// Touch ID prompt text of the unlock
  static let authenticationReason = "Unlock writes on this connection"

  /// End of the running unlock; nil when none runs
  private(set) var expiry: Date?
  /// Whole seconds left, refreshed every second while an unlock runs (the countdown)
  private(set) var remainingSeconds = 0

  @ObservationIgnored private let connectionManager: DatabaseConnectionManager
  @ObservationIgnored private let authenticate: @MainActor (String) async -> Bool
  @ObservationIgnored private var ticker: Task<Void, Never>?
  @ObservationIgnored private var relockObserver: (any NSObjectProtocol)?
  /// Bumped by every start and end, so a start that resumes after an end does not revive it
  @ObservationIgnored private var generation: UInt64 = 0

  /// `authenticate`: Touch ID (`SafeModeAuthenticator.authenticate(reason:)`); false means the
  /// Safe Mode sheet must verify instead
  init(
    connectionManager: DatabaseConnectionManager,
    authenticate: @escaping @MainActor (String) async -> Bool = {
      await SafeModeAuthenticator.shared.authenticate(reason: $0)
    }
  ) {
    self.connectionManager = connectionManager
    self.authenticate = authenticate
  }

  /// An unlock runs now (the connection actor's clock)
  var isActive: Bool {
    guard let expiry else { return false }
    return connectionManager.now() < expiry
  }

  /// Asks Touch ID, then starts the unlock of `config` for `duration`. Nothing starts unless
  /// the authentication succeeds: on `.needsPassword` the caller shows the Safe Mode sheet and
  /// calls `start` once it verified.
  func requestUnlock(
    _ duration: WriteUnlockDuration, config: ConnectionConfig?
  ) async -> WriteUnlockRequest {
    guard let config, ProtectionPolicy.writeUnlockRefusal(for: config) == nil else {
      return .refused
    }
    guard await authenticate(Self.authenticationReason) else { return .needsPassword }
    return await start(duration) ? .started : .refused
  }

  /// Starts (or restarts) the unlock for `duration`. Call only after the Safe Mode
  /// authentication succeeded. False when the connection actor refused it.
  @discardableResult
  func start(_ duration: WriteUnlockDuration) async -> Bool {
    generation &+= 1
    let started = generation
    guard let end = await connectionManager.unlockWrites(for: duration.seconds) else {
      return false
    }
    // Ended (disconnect, relock, Lock now) while the actor was starting it
    guard started == generation else {
      await connectionManager.lockWrites()
      return false
    }
    expiry = end
    observeRelock()
    startTicker()
    tick()
    return true
  }

  /// Lock now: ends the unlock at once
  func lockNow() async {
    end()
    await connectionManager.lockWrites()
  }

  /// Ends the unlock (no-op when none runs). The actor ends its own on a disconnect, a reset or
  /// a new connect; otherwise it is told here.
  func end() {
    generation &+= 1
    ticker?.cancel()
    ticker = nil
    if let relockObserver { NotificationCenter.default.removeObserver(relockObserver) }
    relockObserver = nil
    guard expiry != nil else { return }
    expiry = nil
    remainingSeconds = 0
    let connectionManager = connectionManager
    Task { await connectionManager.lockWrites() }
  }

  /// Refreshes the countdown; ends the unlock once it expired
  func tick() {
    guard let expiry else { return }
    let left = expiry.timeIntervalSince(connectionManager.now())
    guard left > 0 else {
      end()
      return
    }
    remainingSeconds = Int(left.rounded(.up))
  }

  private func startTicker() {
    ticker?.cancel()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled else { return }
        self.tick()
      }
    }
  }

  /// A relock ends the unlock (the observer pattern of `MCPConnectionPool.observeLocks`)
  private func observeRelock() {
    guard relockObserver == nil else { return }
    relockObserver = NotificationCenter.default.addObserver(
      forName: LockRegistry.didRelock, object: connectionManager.lockSource, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.end() }
    }
  }
}
