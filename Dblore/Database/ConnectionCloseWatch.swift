// ConnectionCloseWatch.swift
// PostgresNIO 1.33.1 writes a query to a closed channel with `promise: nil`, so its future never
// completes and the caller would wait forever. Every query is raced against the connection's
// `closeFuture` (public): whichever finishes first resumes the caller.

import Foundation
import NIOCore

/// Thrown by `ConnectionCloseWatch.run` when the connection closed before the work finished.
nonisolated struct ConnectionClosedError: Error {}

/// Fails in-flight work when a connection closes. One watch per connection, closed by the
/// connection's `closeFuture` (a single callback, however many queries run).
nonisolated final class ConnectionCloseWatch: @unchecked Sendable {
  private let lock = NSLock()
  private var closed = false
  private var nextToken: UInt64 = 0
  private var waiters: [UInt64: @Sendable () -> Void] = [:]

  init() {}

  convenience init(closeFuture: EventLoopFuture<Void>) {
    self.init()
    closeFuture.whenComplete { [weak self] _ in self?.close() }
  }

  var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }

  /// Mark the connection closed: every waiting `run` throws `ConnectionClosedError` now.
  func close() {
    lock.lock()
    closed = true
    let pending = waiters
    waiters.removeAll()
    lock.unlock()
    for fail in pending.values { fail() }
  }

  /// Run `operation` on its own task and return its result, or throw `ConnectionClosedError` as
  /// soon as the connection closes. On close the operation's task is cancelled and the caller
  /// resumes at once; an operation that ignores cancellation (e.g. a query future that never
  /// completes) is left running and its result discarded. Cancelling the caller cancels the
  /// operation's task.
  func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    if isClosed { throw ConnectionClosedError() }
    let work = Task { try await operation() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let token = register {
          work.cancel()
          continuation.resume(throwing: ConnectionClosedError())
        }
        guard let token else {
          work.cancel()
          continuation.resume(throwing: ConnectionClosedError())
          return
        }
        Task {
          let result = await work.result
          if self.unregister(token) { continuation.resume(with: result) }
        }
      }
    } onCancel: {
      work.cancel()
    }
  }

  /// nil when already closed. Exactly one of `fail` (on close) or a successful `unregister`
  /// happens for a token, so the continuation is resumed once.
  private func register(_ fail: @escaping @Sendable () -> Void) -> UInt64? {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return nil }
    nextToken &+= 1
    waiters[nextToken] = fail
    return nextToken
  }

  private func unregister(_ token: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return waiters.removeValue(forKey: token) != nil
  }
}

/// Published once when the server (or the network) closed the connected session. The manager
/// has already forgotten the session: not connected, transaction state idle.
nonisolated struct SessionLostEvent: Sendable, Equatable {
  /// `connectionEpoch` of the lost connection
  let epoch: UInt64
  /// Statements of the app transaction that ended with the session
  let pendingCount: Int
  /// The session was lost while COMMIT was awaited: the server may or may not have committed
  let commitOutcomeUnknown: Bool
  /// A transaction the user opened with BEGIN (Protected mode off) was open
  let userTransactionLost: Bool

  init(state: TransactionState, userTxOpen: Bool, epoch: UInt64) {
    self.epoch = epoch
    pendingCount = state.pending.count
    commitOutcomeUnknown = state.endingKind == .commit
    userTransactionLost = userTxOpen
  }

  var message: String {
    var parts = ["The connection to the database was lost."]
    let changes = "\(pendingCount) pending change\(pendingCount == 1 ? "" : "s")"
    let verb = pendingCount == 1 ? "was" : "were"
    if commitOutcomeUnknown {
      parts.append("It is unknown whether the \(changes) \(verb) committed.")
    } else if pendingCount > 0 {
      parts.append("\(changes) \(verb) rolled back by the server.")
    }
    if userTransactionLost {
      parts.append("Your open transaction was rolled back by the server.")
    }
    parts.append("Reconnect to continue.")
    return parts.joined(separator: " ")
  }
}
