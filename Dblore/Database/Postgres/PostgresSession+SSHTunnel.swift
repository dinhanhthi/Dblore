// PostgresSession+SSHTunnel.swift
// PostgreSQL over an SSH direct-tcpip channel. The SSH secret is loaded here, at every open and
// probe, so each reconnect path (cancel, capped read, banner, session loss) rebuilds the
// tunnel. The tunnel owns its event loop; teardown order is PostgreSQL, then SSH (which shuts
// its loop down).

import Foundation
import Logging
import NIOCore
import PostgresNIO

/// What `PostgresSession.detach()` hands over. The caller closes it with `close`.
nonisolated struct DetachedPostgresSession: Sendable {
  var connection: PostgresConnection?
  var group: EventLoopGroup?
  var tunnel: (any SSHTunneling)?

  /// How long a tunneled PostgreSQL close may wait before the tunnel is closed anyway. On a
  /// dead link the SSH child channel waits for a CHANNEL_CLOSE that never comes; closing the
  /// tunnel tears it down locally.
  static let tunneledCloseGrace: Duration = .seconds(2)

  /// Close in order: PostgreSQL connection (when `includingConnection`), SSH tunnel, group.
  func close(includingConnection: Bool) async {
    if includingConnection, let connection {
      if tunnel != nil {
        await Self.closeBounded(connection)
      } else {
        try? await connection.close()
      }
    }
    await tunnel?.close()
    try? await group?.shutdownGracefully()
  }

  /// Starts the close and returns when it finished or after `tunneledCloseGrace`.
  static func closeBounded(_ connection: PostgresConnection) async {
    let (finished, continuation) = AsyncStream<Void>.makeStream()
    Task {
      try? await connection.close()
      continuation.finish()
    }
    Task {
      try? await Task.sleep(for: tunneledCloseGrace)
      continuation.finish()
    }
    for await _ in finished {}
  }
}

extension PostgresSession {
  /// `open()` for a connection with `sshTunnel`. Every failure after the tunnel exists closes it.
  func openThroughTunnel() async throws {
    try Self.checkTunneledTLSName(config)
    let tls = try tunnelTLS()
    let authentication = try SSHTunnelConnector.sshAuthentication(for: config)
    let tunnel = try await SSHTunnelConnector.connectTunnel(
      config: config, authentication: authentication, hostKeyValidator: hostKeyValidator,
      factory: tunnelFactory)
    let conn: PostgresConnection
    do {
      conn = try await attemptConnection(timeoutSeconds: config.timeoutSeconds) {
        try await self.connectPostgres(through: tunnel, tls: tls)
      }
    } catch let error as PSQLError {
      await AppLogger.shared.error(
        "Failed to connect to database: \(formatPostgresError(error))", category: "Database")
      await tunnel.close()
      throw DatabaseError.connectionFailed(formatPostgresError(error))
    } catch {
      await tunnel.close()
      throw Self.tunnelFailure(error)
    }
    setConnected(conn, tunnel: tunnel)
  }

  /// `probe()` for a connection with `sshTunnel`. The tunnel is always closed afterwards: when
  /// the probe work ends, or after a grace when the shared timeout fires and the work never
  /// ends, so a connect still running never lands on the tunnel's shut-down loop.
  /// The tunnel connects before the probe timeout starts: its own connect and handshake
  /// timeouts bound it, and the handshake one is paused while the trust sheet is open.
  func probeThroughTunnel() async throws -> Bool {
    try Self.checkTunneledTLSName(config)
    let tls = try tunnelTLS()
    let authentication = try SSHTunnelConnector.sshAuthentication(for: config)
    let tunnel: any SSHTunneling
    do {
      tunnel = try await SSHTunnelConnector.connectTunnel(
        config: config, authentication: authentication, hostKeyValidator: hostKeyValidator,
        factory: tunnelFactory)
    } catch {
      throw Self.tunnelFailure(error)
    }
    // The grace outlasts one attempt's nominal timeout with margin; the tunnel's own close
    // also waits for channel opens still in flight.
    let teardown = ProbeTeardown(grace: .seconds(config.timeoutSeconds) + .seconds(5)) {
      await tunnel.close()
    }
    do {
      try await withTimeout(of: .seconds(config.timeoutSeconds)) {
        try await self.probeConnectAndQuery {
          do {
            try await self.runTunneledProbe(tls: tls, tunnel: tunnel)
          } catch {
            await teardown.run()
            throw error
          }
          await teardown.run()
        }
      }
      return true
    } catch is TimeoutError {
      teardown.runAfterGrace()
      throw DatabaseError.connectionFailed(
        "Connection timeout after \(config.timeoutSeconds) seconds")
    } catch let error as PSQLError {
      teardown.runAfterGrace()
      throw DatabaseError.connectionFailed(formatPostgresError(error))
    } catch {
      teardown.runAfterGrace()
      throw Self.tunnelFailure(error)
    }
  }

  /// The caller closes `tunnel` once this returns or throws.
  private func runTunneledProbe(
    tls: PostgresConnection.Configuration.TLS, tunnel: any SSHTunneling
  ) async throws {
    let conn = try await attemptConnection(timeoutSeconds: config.timeoutSeconds) {
      try await self.connectPostgres(through: tunnel, tls: tls)
    }
    try await Self.runTestQuery(on: conn)
    await DetachedPostgresSession.closeBounded(conn)
  }

  /// Typed errors pass through; anything else becomes `connectionFailed` like a direct open.
  private static func tunnelFailure(_ error: any Error) -> any Error {
    switch error {
    case is DatabaseError, is SSHTunnelError, is SSHPrivateKeyError, is CancellationError:
      return error
    default:
      return DatabaseError.connectionFailed(error.localizedDescription)
    }
  }

  private func tunnelTLS() throws -> PostgresConnection.Configuration.TLS {
    do {
      return try Self.configureTLS(
        sslMode: config.sslMode, material: try clientCertificateMaterial())
    } catch {
      throw DatabaseError.connectionFailed("Failed to configure TLS: \(error.localizedDescription)")
    }
  }

  /// One attempt: a fresh direct-tcpip channel to the database host as seen from the bastion.
  /// TLS verifies the database host name, not the bastion's.
  private func connectPostgres(
    through tunnel: any SSHTunneling, tls: PostgresConnection.Configuration.TLS
  ) async throws -> PostgresConnection {
    let channel = try await tunnel.openDirectTCPIP(
      targetHost: config.host, targetPort: config.port)
    let configuration = Self.tunneledConfiguration(channel: channel, config: config, tls: tls)
    do {
      return try await PostgresConnection.connect(
        on: channel.eventLoop, configuration: configuration, id: 1,
        logger: Logger(label: "dblore.connection"))
    } catch {
      channel.close(promise: nil)
      throw error
    }
  }

  /// The configuration for one tunneled attempt. Same TLS mode and context as a direct
  /// connection; the TLS name is the database host (as a direct connection derives it), never
  /// the bastion.
  static func tunneledConfiguration(
    channel: any Channel, config: ConnectionConfig, tls: PostgresConnection.Configuration.TLS
  ) -> PostgresConnection.Configuration {
    var configuration = PostgresConnection.Configuration(
      establishedChannel: channel, tls: tls, username: config.username,
      password: config.password, database: config.database)
    configuration.options.tlsServerName = tlsServerName(for: config.host)
    return configuration
  }

  /// Verify Full checks the certificate against `tlsServerName`, and with none (an IP literal,
  /// which SNI refuses) against the peer address: for an SSH channel that is the bastion's
  /// address, not the database server's. Refused rather than checked against the wrong host.
  static func checkTunneledTLSName(_ config: ConnectionConfig) throws {
    guard config.sslMode == .verifyFull, tlsServerName(for: config.host) == nil else { return }
    throw DatabaseError.connectionFailed(
      "Verify Full over SSH needs the database server's host name, not an IP address. Enter "
        + "the name in its certificate, or choose Verify CA.")
  }

  /// The SNI and verification name for `host`. Nil for an IP literal (not valid in SNI),
  /// matching what PostgresNIO does for a direct TCP connection.
  static func tlsServerName(for host: String) -> String? {
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    let isIP = host.withCString {
      inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
    }
    return isIP ? nil : host
  }
}
