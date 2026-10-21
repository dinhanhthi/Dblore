// MySQLSession+TLS.swift
// TLS for MySQL / MariaDB, with the MySQL / libpq meaning of the SSL modes: Allow, Prefer and
// Require encrypt without checking the server certificate (a man in the middle can intercept),
// Verify CA checks the chain but not the host name, Verify Full checks both. The CA and client
// certificate come from the Keychain, loaded as for PostgreSQL. With TLS settings, the patched
// mysql-nio fails with `.tlsNotSupportedByServer` before the login when the server offers no
// SSL; only then do Allow and Prefer reconnect without TLS (a failed verification never does).
// As a second line of defence the session checks the pipeline for a TLS handler after connect
// and refuses the modes that require encryption. Where no verified TLS protects it, the password
// itself is never sent outside the loopback exemption (`MySQLFullAuthGuard`).

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
    // certificate can read the traffic. Only Verify CA and Verify Full authenticate the server.
    // So on Disable, Allow, Prefer and Require the full-authentication guard refuses to sign in
    // when the server asks for the password itself (caching_sha2_password full authentication)
    // or switches to a method other than caching_sha2_password and mysql_native_password: only
    // a scramble ever leaves. Exempt: a direct connection to 127.0.0.1, ::1 or localhost (by
    // the host string); the app's SSH tunnel never is (`armsFullAuthGuard`).
    case .disable, .allow, .prefer, .require: tls.certificateVerification = .none
    case .verifyCa: tls.certificateVerification = .noHostnameVerification
    case .verifyFull: tls.certificateVerification = .fullVerification
    }
    return tls
  }

  /// The login error when the full-authentication guard refused because the server asked for
  /// the password itself and no verified TLS protects it.
  static let fullAuthRefusedMessage =
    "The server asked for the full password, and this connection does not verify the server's "
    + "TLS certificate, so Dblore did not send it. Choose Verify CA or Verify Full in the "
    + "connection's TLS settings."

  /// The login error when mysql-nio refused full authentication over plain TCP (without public
  /// key retrieval): the guard is not armed there (a direct loopback host).
  static let plaintextFullAuthRefusedMessage =
    "The server asked for the full password over an unencrypted connection, so Dblore did not "
    + "send it. Turn on TLS for this connection (Verify CA or Verify Full)."

  /// The login error when the guard refused an oversized frame or a malformed auth switch.
  static let unsupportedSignInMessage =
    "The server asked for an unsupported sign-in method, so Dblore did not send the password."

  /// The login error when the server asked for the `name` authentication method, which
  /// mysql-nio cannot use (from mysql-nio or the guard). The name comes from the server, so it
  /// is shown only as a plain identifier (`[A-Za-z0-9_.-]{1,64}`): no line breaks, bidi
  /// overrides or huge strings in the user's text.
  static func unsupportedAuthPluginMessage(_ name: String) -> String {
    guard isDisplayablePluginName(name) else { return unsupportedSignInMessage }
    return "The server asked for the \(name) authentication method, which Dblore does not "
      + "support (sha256_password and MariaDB ed25519 are not supported). Use "
      + "caching_sha2_password or mysql_native_password for this user."
  }

  private static func isDisplayablePluginName(_ name: String) -> Bool {
    (1...64).contains(name.utf8.count)
      && name.utf8.allSatisfy { byte in
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
          UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "."),
          UInt8(ascii: "-"):
          true
        default: false
        }
      }
  }

  /// The user's text for why the full-authentication guard refused the login. A switch to a
  /// plugin mysql-nio cannot use reads as when mysql-nio refuses it.
  static func loginRefusalMessage(_ reason: FullAuthRefusal.Reason) -> String {
    switch reason {
    case .fullAuthentication: fullAuthRefusedMessage
    case .authSwitch(let plugin) where !MySQLFullAuthGuard.switchablePlugins.contains(plugin):
      unsupportedAuthPluginMessage(plugin)
    case .authSwitch, .oversizedFrame: unsupportedSignInMessage
    }
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
