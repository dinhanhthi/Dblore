// TestDatabase.swift
// Connection settings of the integration tests: `TEST_DB_HOST/PORT/NAME/USER/PASSWORD`
// (forwarded by xcodebuild from `TEST_RUNNER_TEST_DB_*`), defaulting to the docker test
// database (docker/postgresql/docker-compose.test.yml, port 5435). Never a developer's own
// PostgreSQL: some suites terminate backends and reset sessions.

import Foundation

nonisolated enum TestDatabase {
  private static let env = ProcessInfo.processInfo.environment

  static let host = env["TEST_DB_HOST"] ?? "localhost"
  static let port = Int(env["TEST_DB_PORT"] ?? "5435") ?? 5435
  static let database = env["TEST_DB_NAME"] ?? "sqlnotebook_test"
  static let username = env["TEST_DB_USER"] ?? "sqlnotebook_test"
  static let password = env["TEST_DB_PASSWORD"] ?? "sqlnotebook123"
}
