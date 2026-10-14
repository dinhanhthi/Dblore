//
//  AppLoggerTests.swift
//  DbloreTests
//

import Foundation
import Testing

@testable import Dblore

struct AppLoggerTests {

  // MARK: - Security Tests

  @Test("Sanitize query redacts string literals")
  func testSanitizeQueryStringLiterals() {
    let logger = AppLogger.shared

    let query1 = "SELECT * FROM users WHERE email='user@example.com'"
    let sanitized1 = logger.sanitizeQuery(query1)
    #expect(!sanitized1.contains("user@example.com"))
    #expect(sanitized1.contains("[REDACTED]"))

    let query2 = "INSERT INTO users (name, email) VALUES ('John Doe', 'john@example.com')"
    let sanitized2 = logger.sanitizeQuery(query2)
    #expect(!sanitized2.contains("John Doe"))
    #expect(!sanitized2.contains("john@example.com"))
    #expect(sanitized2.contains("[REDACTED]"))
  }

  @Test("Sanitize query redacts numeric values after equals")
  func testSanitizeQueryNumericValues() {
    let logger = AppLogger.shared

    let query = "SELECT * FROM users WHERE id=12345"
    let sanitized = logger.sanitizeQuery(query)
    #expect(!sanitized.contains("12345"))
    #expect(sanitized.contains("[REDACTED]"))
  }

  @Test("Sanitize query redacts IN clauses")
  func testSanitizeQueryInClauses() {
    let logger = AppLogger.shared

    let query = "SELECT * FROM users WHERE id IN (1, 2, 3, 4, 5)"
    let sanitized = logger.sanitizeQuery(query)
    #expect(!sanitized.contains("1, 2, 3, 4, 5"))
    #expect(sanitized.contains("IN ([REDACTED])"))
  }

  @Test("Connection config safe display string redacts host")
  func testConnectionConfigSafeDisplayString() {
    // Test domain name redaction
    let config1 = ConnectionConfig(
      host: "db.example.com",
      database: "mydb"
    )
    let safe1 = config1.safeDisplayString
    #expect(!safe1.contains("example"))
    #expect(safe1.contains("db"))
    #expect(safe1.contains("com"))
    #expect(safe1.contains("*****"))

    // Test IP address redaction
    let config2 = ConnectionConfig(
      host: "192.168.1.100",
      database: "mydb"
    )
    let safe2 = config2.safeDisplayString
    #expect(safe2.contains("192.168"))
    #expect(!safe2.contains("1.100"))
    #expect(safe2.contains("***"))

    // Test localhost (should NOT be redacted)
    let config3 = ConnectionConfig(
      host: "localhost",
      database: "mydb"
    )
    let safe3 = config3.safeDisplayString
    #expect(safe3.contains("localhost"))
    #expect(!safe3.contains("***"))
  }
}
