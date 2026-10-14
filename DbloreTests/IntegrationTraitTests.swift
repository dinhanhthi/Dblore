// IntegrationTraitTests.swift
// Env parsing of the opt-in MongoDB gates: bare or TEST_RUNNER_ keys, true/1/yes only,
// and SKIP_INTEGRATION_TESTS wins.

import Testing

@Suite("IntegrationTraitTests")
struct IntegrationTraitTests {
  @Test(
    "MongoIntegrationGate parses MONGO_TESTS",
    arguments: [
      ([:], false),
      (["MONGO_TESTS": "1"], true),
      (["TEST_RUNNER_MONGO_TESTS": "YES"], true),
      (["MONGO_TESTS": "true", "TEST_RUNNER_MONGO_TESTS": "0"], true),
      (["MONGO_TESTS": "0"], false),
      (["MONGO_TESTS": "false"], false),
      (["MONGO_TLS_TESTS": "1"], false),
      (["MONGO_TESTS": "1", "SKIP_INTEGRATION_TESTS": "true"], false),
      (["TEST_RUNNER_MONGO_TESTS": "1", "TEST_RUNNER_SKIP_INTEGRATION_TESTS": "1"], false),
    ] as [([String: String], Bool)]
  )
  func mongoGate(env: [String: String], expected: Bool) {
    #expect(MongoIntegrationGate.isEnabled(env: env) == expected)
  }

  @Test(
    "MongoTLSIntegrationGate parses MONGO_TLS_TESTS",
    arguments: [
      ([:], false),
      (["MONGO_TLS_TESTS": "1"], true),
      (["TEST_RUNNER_MONGO_TLS_TESTS": "yes"], true),
      (["MONGO_TLS_TESTS": "no"], false),
      (["MONGO_TESTS": "1"], false),
      (["MONGO_TLS_TESTS": "1", "SKIP_INTEGRATION_TESTS": "YES"], false),
    ] as [([String: String], Bool)]
  )
  func mongoTLSGate(env: [String: String], expected: Bool) {
    #expect(MongoTLSIntegrationGate.isEnabled(env: env) == expected)
  }
}
