// MongoSession+SSHTunnel.swift
// MongoDB over SSH by channel injection (phase 2.6): no loopback forwarder. The tunnel opens with
// the SSH secret and the host-key validator at every open and probe; every connection the
// single pool builds (and every killOp control connection) is a fresh direct-tcpip channel to
// the URI's one host as the bastion resolves it. With TLS, `NIOSSLClientHandler` checks that
// host name with full verification, and an error recorder after it keeps the TLS cause, which
// MongoKitten reports only as "I/O on closed channel". Teardown order is connections, then a
// killOp control connection under way (bounded wait), then tunnel; a tunneled plan never falls
// back to a direct connection (`usesTunnel`). A tunnel channel runs on the tunnel's own event loop, which its close shuts down:
// MongoKitten fails pending replies only when a connection's context deinitializes, possibly
// later, and a promise failed on a shut-down loop leaks (a Debug assertion crash). So a tunneled
// connection's pending replies are failed first, while the loop still runs.

import Foundation
import Logging
import MongoClient
import MongoKitten
import NIOCore
import NIOSSL

// `nonisolated`: in this target a bare extension would be main-actor isolated, and channel work
// must not wait for the main actor inside the connect.
nonisolated extension MongoSession {
  static let sshSingleHostMessage =
    "SSH tunnels support a single MongoDB host. Remove +srv or extra hosts."

  /// How long a tunneled close may wait before the tunnel is closed anyway. On a dead link the
  /// SSH child channel waits for a CHANNEL_CLOSE that never comes; closing the tunnel tears it
  /// down locally.
  static let tunneledCloseGrace: Duration = .seconds(2)

  /// Opens the tunnel and hands it to the session, so `close()` tears it down (also after a
  /// failed login). SSH errors keep their type.
  func openTunnel() async throws -> any SSHTunneling {
    let tunnel: any SSHTunneling
    do {
      let authentication = try SSHTunnelConnector.sshAuthentication(for: config)
      tunnel = try await SSHTunnelConnector.connectTunnel(
        config: config, authentication: authentication, hostKeyValidator: hostKeyValidator,
        factory: tunnelFactory)
    } catch {
      throw Self.tunnelFailure(error)
    }
    guard keepTunnel(tunnel) else {
      await tunnel.close()
      throw DatabaseError.connectionFailed(MongoSessionError.closed.message)
    }
    return tunnel
  }

  /// One connection to the plan's single host on a new tunnel channel, not authenticated yet,
  /// and its context (for `closeConnection`). The channel auto-reads: the MongoDB client speaks
  /// first.
  static func connectThroughTunnel(
    plan: MongoConnectionPlan, tunnel: any SSHTunneling, errors: MongoChannelErrorRecorder
  ) async throws -> (connection: MongoConnection, context: MongoClientContext) {
    guard let host = plan.settings.hosts.first else {
      throw MongoError(.cannotConnect, reason: .noHostSpecified)
    }
    let sslContext = plan.usesTLS ? try NIOSSLContext(configuration: tlsConfiguration(plan)) : nil
    let channel = try await tunnel.openDirectTCPIP(
      targetHost: host.hostname, targetPort: host.port)
    let context = MongoClientContext(logger: Logger(label: "dblore.mongo"))
    do {
      try await channel.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
        if let sslContext {
          do {
            let sync = channel.pipeline.syncOperations
            try sync.addHandler(
              NIOSSLClientHandler(context: sslContext, serverHostname: host.hostname))
            try sync.addHandler(errors)
          } catch {
            return channel.eventLoop.makeFailedFuture(error)
          }
        }
        return MongoConnection.addHandlers(to: channel, context: context)
      }.get()
    } catch {
      try? await channel.close()
      throw error
    }
    return (MongoConnection(channel: channel, context: context), context)
  }

  /// Closes `connection`. A tunneled one (with its `context`) first fails its pending replies
  /// and refuses new ones, then waits at most `tunneledCloseGrace` for the close.
  static func closeConnection(
    _ connection: MongoConnection, context: MongoClientContext?
  ) async {
    guard let context else {
      await connection.close()
      return
    }
    await context.cancelQueries(MongoError(.queryFailure, reason: .connectionClosed))
    let (finished, continuation) = AsyncStream<Void>.makeStream()
    Task {
      await connection.close()
      continuation.finish()
    }
    Task {
      try? await Task.sleep(for: tunneledCloseGrace)
      continuation.finish()
    }
    for await _ in finished {}
  }

  /// Typed errors pass through; anything else becomes `connectionFailed` like a direct open.
  static func tunnelFailure(_ error: any Error) -> any Error {
    switch error {
    case is DatabaseError, is SSHTunnelError, is SSHPrivateKeyError, is CancellationError:
      return error
    default:
      return DatabaseError.connectionFailed(error.localizedDescription)
    }
  }
}

/// Keeps the first error that passes through a tunneled pipeline after the TLS handler and
/// forwards every error.
nonisolated final class MongoChannelErrorRecorder: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  private let lock = NSLock()
  private var stored: (any Error)?

  var first: (any Error)? { lock.withLock { stored } }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    lock.withLock { if stored == nil { stored = error } }
    context.fireErrorCaught(error)
  }
}
