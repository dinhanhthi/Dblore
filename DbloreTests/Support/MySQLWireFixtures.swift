// MySQLWireFixtures.swift
// Scripted MySQL server packets for driving the mysql-nio login over an EmbeddedChannel
// (no server). Layouts follow the MySQL client/server protocol: Protocol::HandshakeV10 and
// caching_sha2_password's AuthMoreData packets.

import Foundation
import MySQLNIO

enum MySQLWireFixtures {
  /// AuthMoreData "perform_full_authentication": the server wants the password itself.
  static let performFullAuthentication: [UInt8] = [0x01, 0x04]
  /// AuthMoreData "fast_auth_success": the scramble matched the server's cache; OK follows.
  static let fastAuthSuccess: [UInt8] = [0x01, 0x03]
  /// OK_Packet: header, affected rows 0, last insert id 0, SERVER_STATUS_AUTOCOMMIT, 0 warnings.
  static let ok: [UInt8] = [0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]

  /// A MySQL 8 server that offers caching_sha2_password. Without `ssl` the greeting has no
  /// CLIENT_SSL, so the client logs in over the plain channel.
  static func capabilities(ssl: Bool) -> MySQLProtocol.CapabilityFlags {
    var flags: MySQLProtocol.CapabilityFlags = [
      .CLIENT_LONG_PASSWORD, .CLIENT_PROTOCOL_41, .CLIENT_SECURE_CONNECTION, .CLIENT_PLUGIN_AUTH,
      .CLIENT_CONNECT_WITH_DB, .CLIENT_TRANSACTIONS, .CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA,
      .CLIENT_DEPRECATE_EOF,
    ]
    if ssl { flags.insert(.CLIENT_SSL) }
    return flags
  }

  /// Protocol::HandshakeV10 payload: version 10, server version, connection id, 20-byte
  /// scramble in two parts, capability flags, utf8mb4, autocommit, auth plugin name.
  static func greeting(ssl: Bool) -> [UInt8] {
    let flags = UInt32(truncatingIfNeeded: capabilities(ssl: ssl).rawValue)
    let scramble: [UInt8] = Array(1...20)
    var payload: [UInt8] = [0x0A]
    payload += Array("8.0.36".utf8) + [0x00]
    payload += [0x07, 0x00, 0x00, 0x00]  // connection id
    payload += scramble[0..<8] + [0x00]  // auth-plugin-data part 1, filler
    payload += [UInt8(flags & 0xFF), UInt8(flags >> 8 & 0xFF)]
    payload += [0xFF]  // utf8mb4_0900_ai_ci
    payload += [0x02, 0x00]  // SERVER_STATUS_AUTOCOMMIT
    payload += [UInt8(flags >> 16 & 0xFF), UInt8(flags >> 24 & 0xFF)]
    payload += [21]  // auth-plugin-data length (20 + NUL)
    payload += [UInt8](repeating: 0, count: 10)  // reserved
    payload += scramble[8..<20] + [0x00]  // auth-plugin-data part 2
    payload += Array("caching_sha2_password".utf8) + [0x00]
    return payload
  }

  /// AuthSwitchRequest: 0xFE, the plugin name (NUL-terminated), then 20 bytes of auth data and
  /// a NUL, as MySQL 8 sends for caching_sha2_password and mysql_native_password.
  static func authSwitchRequest(plugin: String) -> [UInt8] {
    [0xFE] + Array(plugin.utf8) + [0x00] + Array(21...40) + [0x00]
  }

  /// `payload` padded with zeros to 0xFFFFFF bytes, the length at which a packet continues in
  /// the next one: the receiver joins them into one message.
  static func padded(_ payload: [UInt8]) -> [UInt8] {
    payload + [UInt8](repeating: 0, count: 0xFF_FF_FF - payload.count)
  }

  /// One packet on the wire: 3-byte little-endian payload length, 1-byte sequence id, payload.
  static func frame(sequence: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let length = payload.count
    return [UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), sequence]
      + payload
  }

  // MARK: - TLS

  /// Throwaway self-signed P-256 certificate (CN=mysql.test) for an in-memory TLS server.
  /// It guards nothing: the client under test does not verify it, which is the point.
  static let serverCertificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIBgjCCASegAwIBAgIUAgYNrqSJY6px4GbD4UdJXUCruPwwCgYIKoZIzj0EAwIw
    FTETMBEGA1UEAwwKbXlzcWwudGVzdDAgFw0yNjEwMjExMzMyNDVaGA8yMTI2MDky
    NzEzMzI0NVowFTETMBEGA1UEAwwKbXlzcWwudGVzdDBZMBMGByqGSM49AgEGCCqG
    SM49AwEHA0IABLlxf4q2+KXFK9Bc6jqXr0RBWl3ZAK73kFVn/umdYov5f8MkwQZq
    3Zy+eu1wQ0UfMNeb7ICyStAQHp7RiRbBVPqjUzBRMB0GA1UdDgQWBBR3JBMKOxch
    0TfODjqyUV/StkyggTAfBgNVHSMEGDAWgBR3JBMKOxch0TfODjqyUV/StkyggTAP
    BgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQDCFPh2cnuA4hZk5dij
    kCV8W5HurEQOaQm54e3ZCvL5TAIhAJ1N6t4/0K7MP/yBbxWMfzT2OjpzueRd+NCx
    FDhvIYJQ
    -----END CERTIFICATE-----
    """

  // test-only throwaway key for an in-memory TLS server; never a real secret
  static let serverPrivateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgVEcS09TLrDuLMdF/
    +zul/UxoNxZWnGhpJypXJUogdamhRANCAAS5cX+KtvilxSvQXOo6l69EQVpd2QCu
    95BVZ/7pnWKL+X/DJMEGat2cvnrtcENFHzDXm+yAskrQEB6e0YkWwVT6
    -----END PRIVATE KEY-----
    """
}
