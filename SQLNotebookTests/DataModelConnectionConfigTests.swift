// DataModelConnectionConfigTests.swift
// Unit tests for ConnectionConfig data model

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Data Model - ConnectionConfig Tests")
@MainActor
struct DataModelConnectionConfigTests {

  // MARK: - ConnectionConfig Tests

  @Test("ConnectionConfig encoding and decoding")
  func connectionConfigEncodingDecoding() throws {
    // Arrange
    let config = ConnectionConfig(
      databaseType: .postgresql,
      host: "localhost",
      port: 5432,
      database: "testdb",
      username: "testuser",
      password: "secret123",
      sslMode: .disable,
      timeoutSeconds: 30
    )

    // Act
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    let data = try encoder.encode(config)
    let jsonString = String(data: data, encoding: .utf8)!

    // Assert - Verify basic encoding works
    #expect(jsonString.contains("localhost"))
    #expect(jsonString.contains("testdb"))
    #expect(jsonString.contains("testuser"))
    #expect(jsonString.contains("30"))  // Verify timeoutSeconds is encoded

    // Decode
    let decoder = JSONDecoder()
    let decodedConfig = try decoder.decode(ConnectionConfig.self, from: data)
    #expect(decodedConfig.host == "localhost")
    #expect(decodedConfig.database == "testdb")
    #expect(decodedConfig.username == "testuser")
    #expect(decodedConfig.timeoutSeconds == 30)
  }

  @Test("ConnectionConfig default timeout value")
  func connectionConfigDefaultTimeout() {
    // Arrange & Act - Create config without specifying timeout
    let config = ConnectionConfig(
      host: "localhost",
      database: "test"
    )

    // Assert - Default timeout should be 30 seconds
    #expect(config.timeoutSeconds == 30)
  }

  @Test("ConnectionConfig custom timeout value")
  func connectionConfigCustomTimeout() {
    // Arrange & Act - Create config with custom timeout
    let config = ConnectionConfig(
      host: "localhost",
      database: "test",
      timeoutSeconds: 60
    )

    // Assert - Custom timeout should be preserved
    #expect(config.timeoutSeconds == 60)
  }

  @Test("ConnectionConfig timeout encoding preserves value")
  func connectionConfigTimeoutEncodingPreservesValue() throws {
    // Arrange - Create configs with different timeout values
    let testCases = [10, 30, 60, 120, 300]

    for timeout in testCases {
      let config = ConnectionConfig(
        host: "localhost",
        database: "test",
        timeoutSeconds: timeout
      )

      // Act - Encode and decode
      let encoder = JSONEncoder()
      let data = try encoder.encode(config)
      let decoder = JSONDecoder()
      let decoded = try decoder.decode(ConnectionConfig.self, from: data)

      // Assert - Timeout value should be preserved
      #expect(decoded.timeoutSeconds == timeout)
    }
  }

  // MARK: - Safety / Session Settings

  @Test("New config has safety/session defaults")
  func safetySessionDefaults() {
    let config = ConnectionConfig(host: "localhost", database: "test")

    #expect(config.protectedMode == true)
    #expect(config.statementTimeoutSeconds == 60)
    #expect(config.lockTimeoutSeconds == 5)
    #expect(config.idleInTransactionTimeoutSeconds == 600)
    #expect(config.rowCapOverride == nil)
  }

  @Test("Legacy JSON without new keys decodes with safety/session defaults")
  func legacyJSONDecodesWithDefaults() throws {
    let json = """
      {
        "databaseType": "PostgreSQL",
        "host": "db.example.com",
        "port": 5432,
        "database": "legacy",
        "username": "admin",
        "password": "",
        "sslMode": "prefer",
        "rememberConnection": true,
        "timeoutSeconds": 30,
        "name": "Old",
        "readOnly": false,
        "blockSchemaChanges": true
      }
      """
    let data = try #require(json.data(using: .utf8))

    let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)

    #expect(decoded.protectionLevel == .schemaOnly)
    #expect(decoded.safeMode == nil)
    #expect(decoded.protectedMode == true)
    #expect(decoded.statementTimeoutSeconds == 60)
    #expect(decoded.lockTimeoutSeconds == 5)
    #expect(decoded.idleInTransactionTimeoutSeconds == 600)
    #expect(decoded.rowCapOverride == nil)
  }

  @Test("Encode/decode round trip preserves custom safety/session values")
  func safetySessionRoundTrip() throws {
    let config = ConnectionConfig(
      host: "localhost",
      database: "test",
      protectedMode: false,
      statementTimeoutSeconds: 30,
      lockTimeoutSeconds: 3,
      idleInTransactionTimeoutSeconds: 120,
      rowCapOverride: 5000
    )

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)

    #expect(decoded == config)
    #expect(decoded.protectedMode == false)
    #expect(decoded.statementTimeoutSeconds == 30)
    #expect(decoded.lockTimeoutSeconds == 3)
    #expect(decoded.idleInTransactionTimeoutSeconds == 120)
    #expect(decoded.rowCapOverride == 5000)
  }

  @Test("Negative safety/session values decode as-is")
  func negativeValuesDecodeAsIs() throws {
    let json = """
      {
        "databaseType": "PostgreSQL",
        "host": "localhost",
        "port": 5432,
        "database": "test",
        "username": "",
        "password": "",
        "sslMode": "prefer",
        "rememberConnection": false,
        "timeoutSeconds": 30,
        "name": "",
        "protectionLevel": "none",
        "statementTimeoutSeconds": -1,
        "lockTimeoutSeconds": -2,
        "idleInTransactionTimeoutSeconds": -3,
        "rowCapOverride": -4
      }
      """
    let data = try #require(json.data(using: .utf8))

    let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)

    #expect(decoded.statementTimeoutSeconds == -1)
    #expect(decoded.lockTimeoutSeconds == -2)
    #expect(decoded.idleInTransactionTimeoutSeconds == -3)
    #expect(decoded.rowCapOverride == -4)
  }
}
