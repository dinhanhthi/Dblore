// IntegrationTraitTests.swift
// IntegrationGate stays enabled unless SKIP_INTEGRATION_TESTS or
// TEST_RUNNER_SKIP_INTEGRATION_TESTS is true, 1, or yes (any casing).

import Foundation
import Testing

@Suite("Integration Trait")
struct IntegrationTraitTests {
  @Test(
    "Skip env vars disable integration tests; other values and an empty env leave them on",
    arguments: [
      (["SKIP_INTEGRATION_TESTS": "true"], false),
      (["SKIP_INTEGRATION_TESTS": "TRUE"], false),
      (["SKIP_INTEGRATION_TESTS": "Yes"], false),
      (["SKIP_INTEGRATION_TESTS": "1"], false),
      (["TEST_RUNNER_SKIP_INTEGRATION_TESTS": "true"], false),
      (["TEST_RUNNER_SKIP_INTEGRATION_TESTS": "TRUE"], false),
      (["TEST_RUNNER_SKIP_INTEGRATION_TESTS": "Yes"], false),
      (["TEST_RUNNER_SKIP_INTEGRATION_TESTS": "1"], false),
      (["SKIP_INTEGRATION_TESTS": "false"], true),
      (["SKIP_INTEGRATION_TESTS": "0"], true),
      (["SKIP_INTEGRATION_TESTS": "no"], true),
      (["SKIP_INTEGRATION_TESTS": "garbage"], true),
      (["TEST_RUNNER_SKIP_INTEGRATION_TESTS": "false"], true),
      (["TEST_RUNNER_SKIP_INTEGRATION_TESTS": "0"], true),
      (["TEST_RUNNER_SKIP_INTEGRATION_TESTS": "no"], true),
      (["TEST_RUNNER_SKIP_INTEGRATION_TESTS": "garbage"], true),
      ([:], true),
      (
        [
          "SKIP_INTEGRATION_TESTS": "false",
          "TEST_RUNNER_SKIP_INTEGRATION_TESTS": "yes",
        ], false
      ),
    ]
  )
  func gate(env: [String: String], enabled: Bool) {
    #expect(IntegrationGate.isEnabled(env: env) == enabled)
  }
}
