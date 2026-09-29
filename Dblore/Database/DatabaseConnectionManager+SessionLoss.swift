// DatabaseConnectionManager+SessionLoss.swift
// Every query is sent through `send(on:_:)`: refused at once on a closed or replaced
// connection, and raced against the connection closing (`ConnectionCloseWatch`), so no caller
// waits forever on a session the server ended. The lost session is forgotten in one actor turn
// and published on `sessionEvents` (no automatic reconnect).

import Foundation
import PostgresNIO

extension DatabaseConnectionManager {
  /// Send one query on `connection` (the current one): `body` runs raced against the
  /// connection closing. Row iteration of a returned `PostgresRowSequence` is not raced:
  /// PostgresNIO fails an in-flight stream itself when the channel closes.
  /// - Throws: `DatabaseError.connectionLost` (session forgotten, event published) when the
  ///   connection is closed, closes while waiting, or is no longer the current one; `body`'s
  ///   error otherwise.
  func send<T: Sendable>(
    on connection: PostgresConnection,
    _ body: @escaping @Sendable (PostgresConnection) async throws -> T
  ) async throws -> T {
    let epoch = connectionEpoch
    guard connection === _connection, let watch = closeWatch, !connection.isClosed else {
      throw sessionLostError(connection, epoch: epoch)
    }
    activeSends += 1
    defer { activeSends -= 1 }
    do {
      return try await watch.run { try await body(connection) }
    } catch {
      guard error is ConnectionClosedError || connection.isClosed else { throw error }
      throw sessionLostError(connection, epoch: epoch)
    }
  }

  /// Forget `connection`'s session if it is still the current one, then return the error
  /// for a caller that used it (the loss message when this session was lost).
  func sessionLostError(_ connection: PostgresConnection, epoch: UInt64) -> DatabaseError {
    if connection === _connection { markSessionLost(epoch: epoch) }
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
    guard _connection != nil, connectionEpoch == epoch else { return }
    let event = SessionLostEvent(state: txState, userTxOpen: userTxOpen, epoch: connectionEpoch)
    let (_, group) = forgetConnection()
    lastSessionLoss = event
    sessionEventsContinuation.yield(event)
    Task.detached {
      await AppLogger.shared.warning("Session lost: \(event.message)", category: "Database")
      try? await group?.shutdownGracefully()
    }
  }
}
