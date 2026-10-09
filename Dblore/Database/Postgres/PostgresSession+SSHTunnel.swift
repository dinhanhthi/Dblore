// PostgresSession+SSHTunnel.swift
// PostgreSQL over an SSH direct-tcpip channel. The SSH secret is loaded here, at every open and
// probe, so each reconnect path (cancel, capped read, banner, session loss) rebuilds the
// tunnel. The tunnel owns its event loop; teardown order is PostgreSQL, then SSH (which shuts
// its loop down).

import Foundation
import Logging
import NIOCore
import NIOSSH
import PostgresNIO

/// Opens an SSH tunnel. Production calls `SSHTunnel.connect`; tests inject fakes or spies.
nonisolated protocol SSHTunnelFactory: Sendable {
  func connect(
    host: String, port: Int, username: String, authentication: SSHTunnelAuthentication,
    hostKeyValidator: @escaping SSHHostKeyValidator, connectTimeout: TimeAmount,
    handshakeTimeout: TimeAmount
  ) async throws -> any SSHTunneling
}

nonisolated struct LiveSSHTunnelFactory: SSHTunnelFactory {
  func connect(
    host: String, port: Int, username: String, authentication: SSHTunnelAuthentication,
    hostKeyValidator: @escaping SSHHostKeyValidator, connectTimeout: TimeAmount,
    handshakeTimeout: TimeAmount
  ) async throws -> any SSHTunneling {
    try await SSHTunnel.connect(
      host: host, port: port, username: username, authentication: authentication,
      hostKeyValidator: hostKeyValidator, connectTimeout: connectTimeout,
      handshakeTimeout: handshakeTimeout)
  }
}

/// Decides whether the SSH server at `host:port` is trusted. Throw to reject the key.
nonisolated protocol SSHHostKeyValidating: Sendable {
  func validate(
    host: String, port: Int, hostKey: NIOSSHPublicKey, fingerprint: String)
    async throws
}

/// The default until the trust prompt exists: no host key is trusted.
nonisolated struct RejectUnknownSSHHostKeys: SSHHostKeyValidating {
  func validate(
    host: String, port: Int, hostKey: NIOSSHPublicKey, fingerprint: String
  )
    async throws
  {
    throw SSHTunnelError.hostKeyRejected
  }
}

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
    let tls = try tunnelTLS()
    let authentication = try sshAuthentication()
    let tunnel = try await connectTunnel(authentication)
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

  /// `probe()` for a connection with `sshTunnel`. The tunnel is always closed afterwards,
  /// also when the shared timeout fires while the probe is still running.
  /// The tunnel connects before the probe timeout starts: its own connect and handshake
  /// timeouts bound it, and the handshake one is paused while the trust sheet is open.
  func probeThroughTunnel() async throws -> Bool {
    let tls = try tunnelTLS()
    let authentication = try sshAuthentication()
    let tunnel: any SSHTunneling
    do {
      tunnel = try await connectTunnel(authentication)
    } catch {
      throw Self.tunnelFailure(error)
    }
    do {
      try await withTimeout(of: .seconds(config.timeoutSeconds)) {
        try await self.probeConnectAndQuery {
          try await self.runTunneledProbe(tls: tls, tunnel: tunnel)
        }
      }
      return true
    } catch is TimeoutError {
      await tunnel.close()
      throw DatabaseError.connectionFailed(
        "Connection timeout after \(config.timeoutSeconds) seconds")
    } catch let error as PSQLError {
      await tunnel.close()
      throw DatabaseError.connectionFailed(formatPostgresError(error))
    } catch {
      await tunnel.close()
      throw Self.tunnelFailure(error)
    }
  }

  /// Every failure path of the caller closes `tunnel` (close is idempotent).
  private func runTunneledProbe(
    tls: PostgresConnection.Configuration.TLS, tunnel: any SSHTunneling
  ) async throws {
    let conn = try await attemptConnection(timeoutSeconds: config.timeoutSeconds) {
      try await self.connectPostgres(through: tunnel, tls: tls)
    }
    try await Self.runTestQuery(on: conn)
    await DetachedPostgresSession(connection: conn, tunnel: tunnel)
      .close(includingConnection: true)
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

  /// The SSH secret as an authentication: the operation's scoped credential (form, unremembered
  /// connection) for this account, else the stored one. Private keys are restored from their
  /// decrypted Keychain form.
  private func sshAuthentication() throws -> SSHTunnelAuthentication {
    guard let stored = SSHCredentialStoreFactory.load(for: config) else {
      throw DatabaseError.sshCredentialMissing
    }
    switch stored {
    case .password(let password):
      return .password(password)
    case .privateKey(let keychainRepresentation):
      return .privateKey(try SSHPrivateKeyParser.restore(from: keychainRepresentation).privateKey)
    }
  }

  /// Connects to the bastion. The session timeout bounds both the TCP connect and the
  /// handshake (key exchange, user auth); time spent in the host-key check (trust sheet) is
  /// not counted.
  private func connectTunnel(
    _ authentication: SSHTunnelAuthentication
  ) async throws
    -> any SSHTunneling
  {
    guard let ssh = config.sshTunnel else { throw DatabaseError.sshCredentialMissing }
    let validator = hostKeyValidator
    let host = ssh.host
    let port = ssh.port
    let timeout = TimeAmount.seconds(Int64(config.timeoutSeconds))
    let factory = tunnelFactory
    do {
      return try await PerfSignpost.interval("ssh-tunnel-connect") {
        try await factory.connect(
          host: host, port: port, username: ssh.username, authentication: authentication,
          hostKeyValidator: { key, fingerprint in
            try await validator.validate(
              host: host, port: port, hostKey: key, fingerprint: fingerprint)
          },
          connectTimeout: timeout, handshakeTimeout: timeout)
      }
    } catch let error as SSHTunnelError {
      throw error.databaseError(host: host, port: port) ?? error
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
