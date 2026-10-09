// PgpassParserTests.swift
// Unit tests for .pgpass parsing used by connection import

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Pgpass Parser")
struct PgpassParserTests {

  @Test("parses concrete lines and names them user@host/db")
  func basicLines() {
    let result = PgpassParser.parse(
      "db.example.com:5433:sales:alice:secret\nlocalhost:5432:app:bob:pw\n")
    #expect(result.warnings.isEmpty)
    #expect(result.connections.count == 2)
    let first = result.connections[0]
    #expect(first.config.host == "db.example.com")
    #expect(first.config.port == 5433)
    #expect(first.config.database == "sales")
    #expect(first.config.username == "alice")
    #expect(first.config.password == "")
    #expect(first.config.name == "alice@db.example.com/sales")
    #expect(first.password == "secret")
    #expect(first.source == .pgpass)
  }

  @Test("handles escaped colons and backslashes")
  func escapes() {
    let result = PgpassParser.parse(#"h\:x:5432:d\\b:u\:1:pa\:ss\\w"#)
    #expect(result.warnings.isEmpty)
    let connection = result.connections.first
    #expect(connection?.config.host == "h:x")
    #expect(connection?.config.database == #"d\b"#)
    #expect(connection?.config.username == "u:1")
    #expect(connection?.password == #"pa:ss\w"#)
  }

  @Test("skips comments, blank lines and CRLF endings")
  func commentsAndBlanks() {
    let result = PgpassParser.parse("# comment\r\n\r\n   \nh:5432:d:u:p\r\n")
    #expect(result.warnings.isEmpty)
    #expect(result.connections.count == 1)
    #expect(result.connections.first?.password == "p")
  }

  @Test("wildcards in host, port, database or user skip the line with a warning")
  func wildcards() {
    let text = """
      *:5432:d:u:p
      h:*:d:u:p
      h:5432:*:u:p
      h:5432:d:*:p
      h:5432:d*:u:*
      """
    let result = PgpassParser.parse(text)
    #expect(result.warnings.count == 4)
    #expect(result.connections.count == 1)
    #expect(result.connections.first?.config.database == "d*")
    #expect(result.connections.first?.password == "*")
  }

  @Test("invalid ports and short lines are skipped without echoing the line")
  func invalidLines() {
    let text = """
      h:abc:d:u:SecretA
      h:0:d:u:SecretB
      h:70000:d:u:SecretC
      h:5432:d:SecretD
      ::d:u:SecretE
      """
    let result = PgpassParser.parse(text)
    #expect(result.connections.isEmpty)
    #expect(result.warnings.count == 5)
    #expect(result.warnings.allSatisfy { !$0.contains("Secret") })
  }

  @Test("duplicate host/port/database/user keeps the first line")
  func duplicates() {
    let result = PgpassParser.parse("h:5432:d:u:first\nh:5432:d:u:second\nh:5432:d:v:other")
    #expect(result.connections.map(\.password) == ["first", "other"])
    #expect(result.warnings.count == 1)
  }

  @Test("a unix socket directory host skips the line with a warning")
  func unixSocketHost() {
    let result = PgpassParser.parse("/var/run/postgresql:5432:d:u:SocketSecret\nh:5432:d:u:ok")
    #expect(result.connections.map(\.config.host) == ["h"])
    #expect(result.warnings.count == 1)
    #expect(result.warnings.first?.hasPrefix("Line 1:") == true)
    #expect(result.warnings.allSatisfy { !$0.contains("SocketSecret") })
  }
}
