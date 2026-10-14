// TestMongoDatabase.swift
// Connection settings of the MongoDB integration tests: `TEST_MONGO_HOST/PORT/TLS_PORT/USER/
// PASSWORD/DB` (forwarded by xcodebuild from the `TEST_RUNNER_` copies), defaulting to the docker
// test servers (docker/mongodb/docker-compose.test.yml: mongo:8.0 standalone on 27018, and with
// the compose profile tls a requireTLS copy on 27019). The users live in `admin`
// (docker/mongodb/init/01-users.js), so tests may drop `dblore_test` freely. TLS fixtures come
// from docker/mongodb/scripts/gen-mongo-tls.sh.

import Foundation

nonisolated enum TestMongoDatabase {
  private static let env = ProcessInfo.processInfo.environment

  static let host = env["TEST_MONGO_HOST"] ?? "127.0.0.1"
  static let port = Int(env["TEST_MONGO_PORT"] ?? "27018") ?? 27018
  static let tlsPort = Int(env["TEST_MONGO_TLS_PORT"] ?? "27019") ?? 27019
  static let database = env["TEST_MONGO_DB"] ?? "dblore_test"
  /// Defaults to `dblore_test`: SCRAM-SHA-256 only, readWrite on `dblore_test` plus
  /// clusterMonitor (serverStatus); currentOp `$ownOps` and killOp of its own ops need no role.
  static let username = env["TEST_MONGO_USER"] ?? "dblore_test"
  static let password = env["TEST_MONGO_PASSWORD"] ?? "dblore123"

  /// Database holding every fixture user (pass as `authSource`).
  static let authSource = "admin"

  /// SCRAM-SHA-256 only, read on `dblore_test`.
  static let readerUsername = "dblore_reader"
  /// SCRAM-SHA-1 only, readWrite on `dblore_test`.
  static let sha1Username = "dblore_sha1"
  /// Root user from MONGO_INITDB_ROOT_USERNAME.
  static let rootUsername = "root"
  /// Shared test-only password of every fixture user.
  static let fixturePassword = "dblore123"

  static let certificates = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docker/mongodb/tls", isDirectory: true)
  static let caCertificate = certificates.appendingPathComponent("ca.crt")
}
