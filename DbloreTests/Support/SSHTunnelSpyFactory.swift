// SSHTunnelSpyFactory.swift
// Real SSH tunnels wrapped in spies, so live tests can count the tunnels a session or manager
// opened, see which ones are closed, and reach the parent channel to simulate a drop.

import Foundation
import NIOCore
import NIOSSH

@testable import Dblore

struct AcceptAnySSHHostKey: SSHHostKeyValidating {
  func validate(
    host: String, port: Int, hostKey: NIOSSHPublicKey, fingerprint: String
  )
    async throws
  {}
}

/// Wraps a real tunnel so tests can see when it was closed and what was closed before it.
final class SpySSHTunnel: SSHTunneling, @unchecked Sendable {
  let tunnel: SSHTunnel
  private let lock = NSLock()
  private var closeHook: (@Sendable () -> Bool)?
  private var observed: Bool?

  init(_ tunnel: SSHTunnel) {
    self.tunnel = tunnel
  }

  var parentChannel: any Channel { tunnel.parentChannel }
  var isClosed: Bool { tunnel.isClosed }
  /// Closed by the app and its SSH connection is gone.
  var isTornDown: Bool { isClosed && !parentChannel.isActive }
  var onClose: (@Sendable () -> Bool)? {
    get { lock.withLock { closeHook } }
    set { lock.withLock { closeHook = newValue } }
  }
  var connectionClosedFirst: Bool? { lock.withLock { observed } }

  func openDirectTCPIP(targetHost: String, targetPort: Int) async throws -> any Channel {
    try await tunnel.openDirectTCPIP(targetHost: targetHost, targetPort: targetPort)
  }

  func close() async {
    if let hook = onClose {
      let value = hook()
      lock.withLock { if observed == nil { observed = value } }
    }
    await tunnel.close()
  }
}

final class SpySSHTunnelFactory: SSHTunnelFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var made: [SpySSHTunnel] = []

  var tunnels: [SpySSHTunnel] { lock.withLock { made } }

  func connect(
    host: String, port: Int, username: String, authentication: SSHTunnelAuthentication,
    hostKeyValidator: @escaping SSHHostKeyValidator, connectTimeout: TimeAmount,
    handshakeTimeout: TimeAmount
  ) async throws -> any SSHTunneling {
    let tunnel = try await SSHTunnel.connect(
      host: host, port: port, username: username, authentication: authentication,
      hostKeyValidator: hostKeyValidator, connectTimeout: connectTimeout,
      handshakeTimeout: handshakeTimeout)
    let spy = SpySSHTunnel(tunnel)
    lock.withLock { made.append(spy) }
    return spy
  }
}

/// PostgreSQL sessions whose tunnels come from `tunnelFactory`.
struct SpyPostgresSessionFactory: DatabaseSessionFactory {
  let tunnelFactory: SpySSHTunnelFactory
  var hostKeyValidator: any SSHHostKeyValidating = AcceptAnySSHHostKey()

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    PostgresSession(
      config: config, tunnelFactory: tunnelFactory, hostKeyValidator: hostKeyValidator)
  }
}
