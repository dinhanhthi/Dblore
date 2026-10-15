// IntegrationTrait.swift
// Every live-database gate is opt-in (PostgreSQL, mTLS, SSH, DuckDB plugin, MySQL,
// MySQL TLS, MongoDB, MongoDB TLS, MongoDB spike). SKIP_INTEGRATION_TESTS or
// TEST_RUNNER_SKIP_INTEGRATION_TESTS (true, 1, or yes) turns them all off.

import Foundation
import Testing

nonisolated enum IntegrationGate {
  private static let skipValues: Set<String> = ["true", "1", "yes"]
  private static let skipKeys = [
    "SKIP_INTEGRATION_TESTS",
    "TEST_RUNNER_SKIP_INTEGRATION_TESTS",
  ]

  /// Integration tests run unless either skip variable is `true`, `1`, or `yes`.
  static func isEnabled(env: [String: String]) -> Bool {
    !skipKeys.contains { key in
      guard let value = env[key] else { return false }
      return skipValues.contains(value.lowercased())
    }
  }
}

nonisolated enum PostgresIntegrationGate {
  static func isEnabled(env: [String: String]) -> Bool {
    guard IntegrationGate.isEnabled(env: env),
      let value = env["POSTGRES_TESTS"] ?? env["TEST_RUNNER_POSTGRES_TESTS"]
    else {
      return false
    }
    return ["true", "1", "yes"].contains(value.lowercased())
  }
}

nonisolated enum MTLSIntegrationGate {
  static func isEnabled(env: [String: String]) -> Bool {
    guard IntegrationGate.isEnabled(env: env),
      let value = env["MTLS_TESTS"] ?? env["TEST_RUNNER_MTLS_TESTS"]
    else {
      return false
    }
    return ["true", "1", "yes"].contains(value.lowercased())
  }
}

nonisolated enum SSHIntegrationGate {
  static func isEnabled(env: [String: String]) -> Bool {
    guard IntegrationGate.isEnabled(env: env),
      let value = env["SSH_TESTS"] ?? env["TEST_RUNNER_SSH_TESTS"]
    else {
      return false
    }
    return ["true", "1", "yes"].contains(value.lowercased())
  }
}

nonisolated enum DuckDBPluginGate {
  static func isEnabled(env: [String: String]) -> Bool {
    guard IntegrationGate.isEnabled(env: env),
      let value = env["DUCKDB_PLUGIN_TESTS"] ?? env["TEST_RUNNER_DUCKDB_PLUGIN_TESTS"]
    else {
      return false
    }
    return ["true", "1", "yes"].contains(value.lowercased())
  }
}

nonisolated enum MySQLIntegrationGate {
  static func isEnabled(env: [String: String]) -> Bool {
    guard IntegrationGate.isEnabled(env: env),
      let value = env["MYSQL_TESTS"] ?? env["TEST_RUNNER_MYSQL_TESTS"]
    else {
      return false
    }
    return ["true", "1", "yes"].contains(value.lowercased())
  }
}

nonisolated enum MySQLTLSIntegrationGate {
  static func isEnabled(env: [String: String]) -> Bool {
    guard IntegrationGate.isEnabled(env: env),
      let value = env["MYSQL_TLS_TESTS"] ?? env["TEST_RUNNER_MYSQL_TLS_TESTS"]
    else {
      return false
    }
    return ["true", "1", "yes"].contains(value.lowercased())
  }
}

nonisolated enum MongoIntegrationGate {
  static func isEnabled(env: [String: String]) -> Bool {
    guard IntegrationGate.isEnabled(env: env),
      let value = env["MONGO_TESTS"] ?? env["TEST_RUNNER_MONGO_TESTS"]
    else {
      return false
    }
    return ["true", "1", "yes"].contains(value.lowercased())
  }
}

nonisolated enum MongoTLSIntegrationGate {
  static func isEnabled(env: [String: String]) -> Bool {
    guard IntegrationGate.isEnabled(env: env),
      let value = env["MONGO_TLS_TESTS"] ?? env["TEST_RUNNER_MONGO_TLS_TESTS"]
    else {
      return false
    }
    return ["true", "1", "yes"].contains(value.lowercased())
  }
}

/// The Phase 2 spike suite (1M-document insert, exact NIO thread counts) runs only on request,
/// on top of the MongoDB gate, so CI's MongoDB service never runs it.
nonisolated enum MongoSpikeIntegrationGate {
  static func isEnabled(env: [String: String]) -> Bool {
    guard MongoIntegrationGate.isEnabled(env: env),
      let value = env["MONGO_SPIKE_TESTS"] ?? env["TEST_RUNNER_MONGO_SPIKE_TESTS"]
    else {
      return false
    }
    return ["true", "1", "yes"].contains(value.lowercased())
  }
}

extension Trait where Self == ConditionTrait {
  /// The PostgreSQL test container is opt-in.
  static var requiresPostgres: Self {
    .enabled(
      if: PostgresIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment),
      "Set TEST_RUNNER_POSTGRES_TESTS=1 and start docker/postgresql/docker-compose.test.yml to run"
    )
  }

  /// mTLS fixtures and the dedicated PostgreSQL container are opt-in.
  static var requiresMTLSPostgres: Self {
    .enabled(
      if: MTLSIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment),
      "Set TEST_RUNNER_MTLS_TESTS=1 and start docker/postgresql/docker-compose.mtls.yml to run"
    )
  }

  /// SSH fixtures and the SSH + PostgreSQL containers are opt-in.
  static var requiresSSHPostgres: Self {
    .enabled(
      if: SSHIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment),
      "Set TEST_RUNNER_SSH_TESTS=1 and start docker/postgresql/docker-compose.ssh.yml to run"
    )
  }

  /// The dev DuckDB plugin in .plugin-dev/ is opt-in.
  static var requiresDuckDBPlugin: Self {
    .enabled(
      if: DuckDBPluginGate.isEnabled(env: ProcessInfo.processInfo.environment),
      "Set TEST_RUNNER_DUCKDB_PLUGIN_TESTS=1 and run scripts/release-plugin.sh --install-dev"
    )
  }

  /// The MySQL and MariaDB containers are opt-in.
  static var requiresMySQL: Self {
    .enabled(
      if: MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment),
      "Set TEST_RUNNER_MYSQL_TESTS=1 and start docker/mysql/docker-compose.test.yml to run"
    )
  }

  /// MySQL TLS fixtures (docker/mysql/scripts/gen-mysql-tls.sh) are opt-in.
  static var requiresMySQLTLS: Self {
    .enabled(
      if: MySQLTLSIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment),
      "Set TEST_RUNNER_MYSQL_TLS_TESTS=1, run docker/mysql/scripts/gen-mysql-tls.sh and recreate the MySQL container"
    )
  }

  /// The MongoDB container is opt-in.
  static var requiresMongo: Self {
    .enabled(
      if: MongoIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment),
      "Set TEST_RUNNER_MONGO_TESTS=1 and start docker/mongodb/docker-compose.test.yml to run"
    )
  }

  /// The MongoDB TLS container (compose profile tls) is opt-in.
  static var requiresMongoTLS: Self {
    .enabled(
      if: MongoTLSIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment),
      "Set TEST_RUNNER_MONGO_TLS_TESTS=1, run docker/mongodb/scripts/gen-mongo-tls.sh and start the compose profile tls"
    )
  }

  /// The MongoKitten spike suite is opt-in on top of the MongoDB container.
  static var requiresMongoSpike: Self {
    .enabled(
      if: MongoSpikeIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment),
      "Set TEST_RUNNER_MONGO_TESTS=1 and TEST_RUNNER_MONGO_SPIKE_TESTS=1 and start docker/mongodb/docker-compose.test.yml to run"
    )
  }
}
