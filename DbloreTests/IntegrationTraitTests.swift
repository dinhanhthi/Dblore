// IntegrationTraitTests.swift
// Env parsing of the opt-in MongoDB, engine plugin, SQL Server and ClickHouse gates: bare or
// TEST_RUNNER_ keys, true/1/yes only, and SKIP_INTEGRATION_TESTS wins. The spike gate also
// needs the MongoDB gate.

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

  @Test(
    "MongoSpikeIntegrationGate needs MONGO_SPIKE_TESTS and MONGO_TESTS",
    arguments: [
      ([:], false),
      (["MONGO_TESTS": "1"], false),
      (["MONGO_SPIKE_TESTS": "1"], false),
      (["MONGO_TESTS": "1", "MONGO_SPIKE_TESTS": "1"], true),
      (["TEST_RUNNER_MONGO_TESTS": "1", "TEST_RUNNER_MONGO_SPIKE_TESTS": "yes"], true),
      (["MONGO_TESTS": "1", "MONGO_SPIKE_TESTS": "no"], false),
      (["MONGO_TESTS": "1", "MONGO_SPIKE_TESTS": "1", "SKIP_INTEGRATION_TESTS": "true"], false),
    ] as [([String: String], Bool)]
  )
  func mongoSpikeGate(env: [String: String], expected: Bool) {
    #expect(MongoSpikeIntegrationGate.isEnabled(env: env) == expected)
  }

  @Test(
    "EnginePluginGate parses ENGINE_PLUGIN_TESTS",
    arguments: [
      ([:], false),
      (["ENGINE_PLUGIN_TESTS": "1"], true),
      (["TEST_RUNNER_ENGINE_PLUGIN_TESTS": "YES"], true),
      (["ENGINE_PLUGIN_TESTS": "true", "TEST_RUNNER_ENGINE_PLUGIN_TESTS": "0"], true),
      (["ENGINE_PLUGIN_TESTS": "no"], false),
      (["SQLSERVER_TESTS": "1"], false),
      (["ENGINE_PLUGIN_TESTS": "1", "SKIP_INTEGRATION_TESTS": "true"], false),
      (["TEST_RUNNER_ENGINE_PLUGIN_TESTS": "1", "TEST_RUNNER_SKIP_INTEGRATION_TESTS": "1"], false),
    ] as [([String: String], Bool)]
  )
  func enginePluginGate(env: [String: String], expected: Bool) {
    #expect(EnginePluginGate.isEnabled(env: env) == expected)
  }

  @Test(
    "SQLServerIntegrationGate parses SQLSERVER_TESTS",
    arguments: [
      ([:], false),
      (["SQLSERVER_TESTS": "1"], true),
      (["TEST_RUNNER_SQLSERVER_TESTS": "YES"], true),
      (["SQLSERVER_TESTS": "true", "TEST_RUNNER_SQLSERVER_TESTS": "0"], true),
      (["SQLSERVER_TESTS": "no"], false),
      (["CLICKHOUSE_TESTS": "1"], false),
      (["SQLSERVER_TESTS": "1", "SKIP_INTEGRATION_TESTS": "true"], false),
      (["TEST_RUNNER_SQLSERVER_TESTS": "1", "TEST_RUNNER_SKIP_INTEGRATION_TESTS": "1"], false),
    ] as [([String: String], Bool)]
  )
  func sqlServerGate(env: [String: String], expected: Bool) {
    #expect(SQLServerIntegrationGate.isEnabled(env: env) == expected)
  }

  @Test(
    "ClickHouseIntegrationGate parses CLICKHOUSE_TESTS",
    arguments: [
      ([:], false),
      (["CLICKHOUSE_TESTS": "1"], true),
      (["TEST_RUNNER_CLICKHOUSE_TESTS": "YES"], true),
      (["CLICKHOUSE_TESTS": "true", "TEST_RUNNER_CLICKHOUSE_TESTS": "0"], true),
      (["CLICKHOUSE_TESTS": "no"], false),
      (["ENGINE_PLUGIN_TESTS": "1"], false),
      (["CLICKHOUSE_TESTS": "1", "SKIP_INTEGRATION_TESTS": "true"], false),
      (["TEST_RUNNER_CLICKHOUSE_TESTS": "1", "TEST_RUNNER_SKIP_INTEGRATION_TESTS": "1"], false),
    ] as [([String: String], Bool)]
  )
  func clickHouseGate(env: [String: String], expected: Bool) {
    #expect(ClickHouseIntegrationGate.isEnabled(env: env) == expected)
  }
}
