// MySQLSession+TLS.swift
// TLS for MySQL / MariaDB, with the MySQL / libpq meaning of the SSL modes: Allow, Prefer and
// Require encrypt without checking the server certificate (a man in the middle can intercept),
// Verify CA checks the chain but not the host name, Verify Full checks both. The CA and client
// certificate come from the Keychain, loaded as for PostgreSQL. With TLS settings, the patched
// mysql-nio fails with `.tlsNotSupportedByServer` before the login when the server offers no
// SSL; only then do Allow and Prefer reconnect without TLS (a failed verification never does).
// As a second line of defence the session checks the pipeline for a TLS handler after connect
// and refuses the modes that require encryption.

import Foundation
import MySQLNIO
import NIOCore
import NIOSSL

/// How the open MySQL session is protected. Feeds the footer SSL badges.
nonisolated enum MySQLTransport: Sendable, Equatable {
  /// No TLS: Disable, or Allow / Prefer against a server without SSL.
  case plaintext
  /// TLS without checking the server certificate (Allow, Prefer, Require).
  case encryptedUnverified
  /// TLS with the server certificate checked (Verify CA, Verify Full).
  case verified
}

extension MySQLSession {
  /// Nil for Disable (plain TCP). Otherwise the client configuration with the client
  /// certificate and CA, verifying the server as the SSL mode says.
  static func tlsConfiguration(
    sslMode: SSLMode, material: ClientCertificateMaterial?
  ) throws -> TLSConfiguration? {
    guard sslMode != .disable else { return nil }
    var tls = try PostgresSession.tlsConfiguration(sslMode: sslMode, material: material)
    switch sslMode {
    // Deliberate (user decision, 2026-10-10): the MySQL / libpq meaning of these modes. They
    // encrypt but do not authenticate the server, so an active man in the middle with its own
    // certificate can read the traffic, including the password of a caching_sha2_password full
    // authentication. Only Verify CA and Verify Full authenticate the server.
    case .disable, .allow, .prefer, .require: tls.certificateVerification = .none
    case .verifyCa: tls.certificateVerification = .noHostnameVerification
    case .verifyFull: tls.certificateVerification = .fullVerification
    }
    return tls
  }

  /// The protection of a session opened with `sslMode`.
  static func transport(sslMode: SSLMode, isEncrypted: Bool) -> MySQLTransport {
    guard isEncrypted else { return .plaintext }
    return sslMode == .verifyCa || sslMode == .verifyFull ? .verified : .encryptedUnverified
  }

  /// The client certificate (and CA) of `config`, from the Keychain or the operation scope.
  static func clientCertificateMaterial(
    for config: ConnectionConfig
  ) throws -> ClientCertificateMaterial? {
    guard config.clientCertificate != nil else { return nil }
    guard requiresEncryption(config.sslMode) else {
      throw DatabaseError.connectionFailed(
        "Client certificate or custom CA requires Require, Verify CA, or Verify Full TLS mode")
    }
    guard let material = ClientCertificateStoreFactory.load(for: config) else {
      throw DatabaseError.connectionFailed("Client certificate is missing from the Keychain")
    }
    return material
  }

  /// SNI and host name for the handshake. NIOSSL refuses an IP address as SNI; with nil it
  /// checks the certificate against the peer address instead.
  static func serverHostname(for host: String) -> String? {
    (try? SocketAddress(ipAddress: host, port: 0)) == nil ? host : nil
  }

  /// Require, Verify CA and Verify Full never run over a plaintext connection.
  static func checkTransport(sslMode: SSLMode, isEncrypted: Bool) throws {
    guard !isEncrypted, requiresEncryption(sslMode) else { return }
    throw DatabaseError.connectionFailed(
      "The server does not offer SSL, and this connection's SSL mode requires it. Turn on SSL "
        + "on the server or choose another SSL mode.")
  }

  /// Allow and Prefer: TLS when the server offers it, otherwise plain TCP.
  static func mayFallBack(_ sslMode: SSLMode) -> Bool {
    sslMode == .allow || sslMode == .prefer
  }

  /// `SSLMode.mayBeUnencrypted`, readable off the main actor.
  private static func requiresEncryption(_ sslMode: SSLMode) -> Bool {
    sslMode == .require || sslMode == .verifyCa || sslMode == .verifyFull
  }

  /// A TLS handler sits in the pipeline only when the handshake upgraded to TLS.
  static func isEncrypted(_ connection: MySQLConnection) async -> Bool {
    let channel = connection.channel
    let found = try? await connection.eventLoop.submit {
      (try? channel.pipeline.syncOperations.handler(type: NIOSSLClientHandler.self)) != nil
    }.get()
    return found ?? false
  }
}
