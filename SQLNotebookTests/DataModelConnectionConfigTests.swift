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
}
