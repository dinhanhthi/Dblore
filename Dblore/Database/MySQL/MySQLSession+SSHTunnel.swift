// MySQLSession+SSHTunnel.swift
// MySQL / MariaDB over SSH, through a loopback forwarder (phase 2.6: mysql-nio's own TLS over an
// SSH child channel crashes). The tunnel opens with the SSH secret and the host-key validator
// at every open and probe, then one `SSHLoopbackForwarder` on 127.0.0.1 reaches
// `config.host:config.port` as the bastion resolves it; every login attempt and every KILL QUERY
// control connection is a fresh accepted connection, so a fresh tunnel channel. TLS runs end to
// end inside the forward and checks `config.host`, never the loopback address. Teardown order is
// connection, forwarder, tunnel, event-loop group.

import Foundation
import MySQLNIO
import NIOCore

/// What `MySQLSession.detach()` hands over. The caller closes it with `close`.
nonisolated struct DetachedMySQLSession: Sendable {
  var connection: MySQLConnection?
  var group: EventLoopGroup?
  var forwarder: SSHLoopbackForwarder?
  var tunnel: (any SSHTunneling)?

  /// Close in order: connection (when `includingConnection`), forwarder, tunnel, group.
  func close(includingConnection: Bool) async {
    if includingConnection, let connection { try? await connection.close().get() }
    await forwarder?.stop()
    await tunnel?.close()
    try? await group?.shutdownGracefully()
  }
}

extension MySQLSession {
  /// Opens the tunnel and the forwarder, hands both to the session (so `close()` tears them
  /// down, also after a failed login) and returns the forwarder's loopback address. The host
  /// is resolved on the bastion: no local DNS lookup.
  func openTunnelEndpoint() async throws -> SocketAddress {
    try Self.checkTunneledTLSName(config)
    let tunnel: any SSHTunneling
    do {
      let authentication = try SSHTunnelConnector.sshAuthentication(for: config)
      tunnel = try await SSHTunnelConnector.connectTunnel(
        config: config, authentication: authentication, hostKeyValidator: hostKeyValidator,
        factory: tunnelFactory)
    } catch {
      throw Self.tunnelFailure(error)
    }
    setTunnel(tunnel)
    do {
      let forwarder = try await SSHLoopbackForwarder.start(
        tunnel: tunnel, targetHost: config.host, targetPort: config.port)
      setForwarder(forwarder)
      return try SocketAddress(ipAddress: "127.0.0.1", port: forwarder.localPort)
    } catch {
      throw Self.tunnelFailure(error)
    }
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

  /// Verify Full checks the certificate against `serverHostname`, and with none (an IP
  /// literal, which SNI refuses) against the peer address: through the forwarder that is
  /// 127.0.0.1, not the database server. Refused rather than checked against the wrong name.
  static func checkTunneledTLSName(_ config: ConnectionConfig) throws {
    guard config.sslMode == .verifyFull, serverHostname(for: config.host) == nil else { return }
    throw DatabaseError.connectionFailed(
      "Verify Full over SSH needs the database server's host name, not an IP address. Enter "
        + "the name in its certificate, or choose Verify CA.")
  }
}
