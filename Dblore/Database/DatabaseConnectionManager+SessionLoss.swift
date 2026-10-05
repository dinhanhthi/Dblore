// DatabaseConnectionManager+SessionLoss.swift
// Every query is sent through `send(on:_:)`: refused at once on a closed or replaced
// connection, and raced against the connection closing (`ConnectionCloseWatch`), so no caller
// waits forever on a session the server ended. The lost session is forgotten in one actor turn
// and published on `sessionEvents` (no automatic reconnect).

import Foundation
import PostgresNIO

extension DatabaseConnectionManager {
  /// Send one query on `connection` (the current one): `body` runs raced against the
  /// session's close watch. Row iteration of a returned `PostgresRowSequence` is not raced:
  /// PostgresNIO fails an in-flight stream itself when the channel closes.
  /// - Throws: `DatabaseError.connectionLost` (session forgotten, event published) when the
  ///   connection is closed, closes while waiting, or is no longer the current one; `body`'s
  ///   error otherwise.
  func send<T: Sendable>(
    on connection: PostgresConnection,
    _ body: @escaping @Sendable (PostgresConnection) async throws -> T
  ) async throws -> T {
    try await performSend(on: connection) {
      guard let postgres = self.postgresSession else { throw ConnectionClosedError() }
      return try await postgres.runWatched {
        try await body(connection)
      }
    }
  }

  /// Count one in-flight send, refuse a closed or replaced connection, and map a close
  /// during `operation` to `DatabaseError.connectionLost`. `operation` is the session call.
  /// Row iteration after a stream is returned is outside this count.
  func performSend<T: Sendable>(
    on connection: PostgresConnection,
    _ operation: () async throws -> T
  ) async throws -> T {
    let epoch = connectionEpoch
    guard connection === _postgresConnection, !connection.isClosed else {
      throw sessionLostError(connection, epoch: epoch)
    }
    activeSends += 1
    defer { activeSends -= 1 }
    do {
      return try await operation()
    } catch {
      guard error is ConnectionClosedError || connection.isClosed else { throw error }
      throw sessionLostError(connection, epoch: epoch)
    }
  }

  /// `performSend` on the current connection, then `body` on its `PostgresSession`.
  func withPostgres<T: Sendable>(
    on connection: PostgresConnection,
    _ body: (PostgresSession) async throws -> T
  ) async throws -> T {
    try await performSend(on: connection) {
      guard let postgres = self.postgresSession else { throw ConnectionClosedError() }
      return try await body(postgres)
    }
  }

  /// Run `operation` on the current session. A closed or replaced PostgreSQL socket becomes
  /// `DatabaseError.connectionLost` (session forgotten, event published). Row iteration of a
  /// returned stream stays inside `operation` so a close during the read is mapped the same way.
  func withSession<T: Sendable>(
    _ operation: (any DatabaseSession) async throws -> T
  ) async throws -> T {
    let epoch = connectionEpoch
    guard let current = session else { throw DatabaseError.notConnected }
    if let postgres = current as? PostgresSession {
      guard let connection = postgres.connection else { throw DatabaseError.notConnected }
      guard !connection.isClosed else { throw sessionLostError(connection, epoch: epoch) }
    }
    activeSends += 1
    defer { activeSends -= 1 }
    do {
      return try await operation(current)
    } catch {
      if let postgres = current as? PostgresSession, let connection = postgres.connection,
        error is ConnectionClosedError || connection.isClosed
      {
        throw sessionLostError(connection, epoch: epoch)
      }
      throw error
    }
  }

  /// Forget `connection`'s session if it is still the current one, then return the error
  /// for a caller that used it (the loss message when this session was lost).
  func sessionLostError(_ connection: PostgresConnection, epoch: UInt64) -> DatabaseError {
    if connection === _postgresConnection { markSessionLost(epoch: epoch) }
    if let loss = lastSessionLoss, loss.epoch == epoch {
      return .connectionLost(loss.message)
    }
    return .connectionLost("The connection was closed. Reconnect to continue.")
  }

  /// The server (or the network) closed the connection published with `epoch`. If it is
  /// still the current one, forget it in this actor turn (not connected, epoch advanced,
  /// transaction state idle, edit tables cleared) and publish a `SessionLostEvent` with what
  /// was pending. A connection already replaced, reset or disconnected by the app is ignored:
  /// every forget / connect advances `connectionEpoch`, so an old epoch never matches.
  func markSessionLost(epoch: UInt64) {
    guard session != nil, connectionEpoch == epoch else { return }
    let event = SessionLostEvent(state: txState, userTxOpen: userTxOpen, epoch: connectionEpoch)
    let forgotten = forgetConnection()
    activeUnrememberedCertificate = nil
    lastSessionLoss = event
    sessionEventsContinuation.yield(event)
    Task.detached {
      await AppLogger.shared.warning("Session lost: \(event.message)", category: "Database")
      await DatabaseConnectionManager.closeForgotten(forgotten, includingConnection: false)
    }
  }
}
