// IntegrationTrait.swift
// Skips PostgreSQL integration suites when SKIP_INTEGRATION_TESTS or
// TEST_RUNNER_SKIP_INTEGRATION_TESTS is true, 1, or yes.

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

extension Trait where Self == ConditionTrait {
  /// Skip a suite when integration tests are turned off in the environment.
  static var requiresPostgres: Self {
    .enabled(
      if: IntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment),
      "Set SKIP_INTEGRATION_TESTS=false and start docker/postgresql to run"
    )
  }
}
