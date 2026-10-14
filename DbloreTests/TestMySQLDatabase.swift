// TestMySQLDatabase.swift
// Connection settings of the MySQL integration tests: `TEST_MYSQL_HOST/PORT/NAME/USER/PASSWORD`
// and `TEST_MARIADB_PORT` (forwarded by xcodebuild from the `TEST_RUNNER_` copies), defaulting
// to the docker test servers (docker/mysql/docker-compose.test.yml: MySQL 8.4 on 3307 with a
// caching_sha2_password user, MariaDB 11.4 on 3308 with a mysql_native_password user). TLS
// fixtures come from docker/mysql/scripts/gen-mysql-tls.sh.

import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

nonisolated enum TestMySQLDatabase {
  private static let env = ProcessInfo.processInfo.environment

  static let host = env["TEST_MYSQL_HOST"] ?? "127.0.0.1"
  static let port = Int(env["TEST_MYSQL_PORT"] ?? "3307") ?? 3307
  static let mariaDBPort = Int(env["TEST_MARIADB_PORT"] ?? "3308") ?? 3308
  static let database = env["TEST_MYSQL_NAME"] ?? "dblore_test"
  static let username = env["TEST_MYSQL_USER"] ?? "dblore_test"
  static let password = env["TEST_MYSQL_PASSWORD"] ?? "dblore123"

  /// REQUIRE X509 user on the MySQL server (docker/mysql/init/01-users.sql).
  static let x509Username = "dblore_x509"
  static let x509Password = "dblore123"

  static let certificates = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docker/mysql/data/tls", isDirectory: true)
  static let caCertificate = certificates.appendingPathComponent("ca.crt")
  static let clientCertificate = certificates.appendingPathComponent("client.crt")
  static let clientKey = certificates.appendingPathComponent("client.key")

  /// Dblore never fetches the RSA key over plain TCP, so a caching_sha2_password user logs in
  /// over plain TCP only once the server has cached it (fast auth). One TLS login (fixture
  /// certificate, not verified) fills the cache for `username` and `root` on the MySQL server;
  /// a server restart or FLUSH PRIVILEGES empties it.
  static func primeAuthCache() async throws {
    for (user, secret) in [(username, password), ("root", "dblore123")] {
      try await primeAuthCache(username: user, password: secret)
    }
  }

  /// One TLS login of `username` on the MySQL server.
  static func primeAuthCache(username: String, password: String) async throws {
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.certificateVerification = .none
    let connection = try await MySQLConnection.connect(
      to: try SocketAddress(ipAddress: host, port: port), username: username,
      database: database, password: password, tlsConfiguration: tls,
      on: MultiThreadedEventLoopGroup.singleton.next()
    ).get()
    try await connection.close().get()
  }
}
