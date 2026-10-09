// PostgresURIParserTests.swift
// Unit tests for PostgreSQL URI and libpq key=value parsing used by connection import

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("PostgreSQL URI Parser")
struct PostgresURIParserTests {

  @Test("parses a basic URI with both schemes")
  func basicURI() throws {
    for scheme in ["postgres", "postgresql", "PostgreSQL"] {
      let imported = try PostgresURIParser.parse(
        "  \(scheme)://alice:secret@db.example.com:6543/sales\n")
      #expect(imported.config.databaseType == .postgresql)
      #expect(imported.config.host == "db.example.com")
      #expect(imported.config.port == 6543)
      #expect(imported.config.database == "sales")
      #expect(imported.config.username == "alice")
      #expect(imported.config.password == "")
      #expect(imported.config.sslMode == .prefer)
      #expect(imported.config.name == "alice@db.example.com/sales")
      #expect(imported.password == "secret")
      #expect(imported.source == .uri)
      #expect(imported.warnings.isEmpty)
    }
  }

  @Test("percent-decodes user, password, host and database")
  func percentDecoding() throws {
    let imported = try PostgresURIParser.parse(
      "postgresql://al%40ice:p%40ss%3Aw%2Frd@my%2Dhost/my%20db")
    #expect(imported.config.username == "al@ice")
    #expect(imported.password == "p@ss:w/rd")
    #expect(imported.config.host == "my-host")
    #expect(imported.config.database == "my db")
    #expect(imported.config.port == 5432)
  }

  @Test("no password gives nil")
  func noPassword() throws {
    let imported = try PostgresURIParser.parse("postgresql://bob@localhost/app")
    #expect(imported.password == nil)
  }

  @Test("bracketed IPv6 hosts")
  func ipv6() throws {
    let withPort = try PostgresURIParser.parse("postgresql://u@[2001:db8::1]:5433/d")
    #expect(withPort.config.host == "2001:db8::1")
    #expect(withPort.config.port == 5433)
    let noPort = try PostgresURIParser.parse("postgresql://u@[::1]/d")
    #expect(noPort.config.host == "::1")
    #expect(noPort.config.port == 5432)
  }

  @Test(
    "maps every sslmode value",
    arguments: [
      ("disable", SSLMode.disable), ("allow", .allow), ("prefer", .prefer),
      ("require", .require), ("verify-ca", .verifyCa), ("verify-full", .verifyFull),
    ])
  func sslModes(raw: String, expected: SSLMode) throws {
    let imported = try PostgresURIParser.parse("postgresql://u@h/d?sslmode=\(raw)")
    #expect(imported.config.sslMode == expected)
    #expect(imported.warnings.isEmpty)
  }

  @Test("unknown sslmode warns and keeps the default")
  func unknownSSLMode() throws {
    let imported = try PostgresURIParser.parse("postgresql://u@h/d?sslmode=bogus")
    #expect(imported.config.sslMode == .prefer)
    #expect(imported.warnings.count == 1)
  }

  @Test("other parameters are ignored with a warning that never echoes the value")
  func unknownParameter() throws {
    let imported = try PostgresURIParser.parse(
      "postgresql://u@h/d?application_name=x&sslpassword=TopSecret1&sslmode=require")
    #expect(imported.config.sslMode == .require)
    #expect(imported.warnings.count == 2)
    #expect(imported.warnings.allSatisfy { !$0.contains("TopSecret1") })
    #expect(imported.warnings.contains { $0.contains("application_name") })
  }

  @Test("multiple hosts are rejected")
  func multipleHosts() {
    #expect(throws: PostgresURIParser.ParseError.multipleHostsNotSupported) {
      try PostgresURIParser.parse("postgresql://u@h1:5432,h2:5433/d")
    }
    #expect(throws: PostgresURIParser.ParseError.multipleHostsNotSupported) {
      try PostgresURIParser.parse("host=h1,h2 dbname=d")
    }
  }

  @Test("missing database defaults to the user name, else postgres")
  func missingDatabase() throws {
    #expect(try PostgresURIParser.parse("postgresql://carol@h").config.database == "carol")
    #expect(try PostgresURIParser.parse("postgresql://carol@h/").config.database == "carol")
    let anonymous = try PostgresURIParser.parse("postgresql://h:5432")
    #expect(anonymous.config.database == "postgres")
    #expect(anonymous.config.username == "")
  }

  @Test("unix sockets and host parameters are rejected")
  func unixSocket() {
    #expect(throws: PostgresURIParser.ParseError.unixSocketNotSupported) {
      try PostgresURIParser.parse("postgresql://%2Fvar%2Frun%2Fpostgresql/d")
    }
    #expect(throws: PostgresURIParser.ParseError.hostParameterNotSupported) {
      try PostgresURIParser.parse("postgresql://u@h/d?host=/tmp")
    }
    #expect(throws: PostgresURIParser.ParseError.unixSocketNotSupported) {
      try PostgresURIParser.parse("host=/tmp dbname=d")
    }
    #expect(throws: PostgresURIParser.ParseError.missingHost) {
      try PostgresURIParser.parse("postgresql:///d")
    }
  }

  @Test(
    "garbage and malformed input is rejected",
    arguments: [
      "", "hello world", "mysql://u@h/d", "postgresql://u@h:99999/d", "postgresql://u@h:abc/d",
      "postgresql://u:%zz@h/d", "postgresql://u@[::1/d", "host='unterminated",
    ])
  func garbage(input: String) {
    #expect(throws: PostgresURIParser.ParseError.self) {
      try PostgresURIParser.parse(input)
    }
  }

  @Test("parses libpq key=value strings with quoted values")
  func keyValue() throws {
    let imported = try PostgresURIParser.parse(
      #"host=db.local port = 6000 dbname='my db' user=dave password='it\'s a \\ secret' sslmode=verify-full connect_timeout=5"#
    )
    #expect(imported.config.host == "db.local")
    #expect(imported.config.port == 6000)
    #expect(imported.config.database == "my db")
    #expect(imported.config.username == "dave")
    #expect(imported.password == #"it's a \ secret"#)
    #expect(imported.config.sslMode == .verifyFull)
    #expect(imported.warnings.count == 1)
    #expect(imported.source == .uri)
  }

  @Test("key=value without dbname defaults to the user name")
  func keyValueDefaults() throws {
    let imported = try PostgresURIParser.parse("host=h user=erin")
    #expect(imported.config.database == "erin")
    #expect(imported.config.port == 5432)
  }

  @Test("descriptions never contain the password")
  func redactedDescription() throws {
    var imported = try PostgresURIParser.parse("postgresql://u:Hunter2Secret@h/d")
    imported.sshCredential = .password("SshSecret99")
    for text in [
      String(describing: imported), String(reflecting: imported), "\(imported)",
      {
        var out = ""
        dump(imported, to: &out)
        return out
      }(),
    ] {
      #expect(!text.contains("Hunter2Secret"))
      #expect(!text.contains("SshSecret99"))
    }
  }

  @Test("an ignored parameter key is echoed on one line, without control characters, bounded")
  func unknownParameterKeySanitized() throws {
    let key = "evil%0Akey%1B" + String(repeating: "k", count: 100)
    let imported = try PostgresURIParser.parse("postgresql://u@h/d?\(key)=v")
    let warning = try #require(imported.warnings.first)
    #expect(!warning.contains("\n"))
    #expect(!warning.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    #expect(warning.contains("evilkey"))
    #expect(warning.count < 100)
  }

  @Test("URI user, dbname and port parameters override the authority, as libpq does")
  func uriQueryOverrides() throws {
    let imported = try PostgresURIParser.parse(
      "postgresql://alice:pw@h:5432/one?user=bob&dbname=two&port=6543")
    #expect(imported.config.username == "bob")
    #expect(imported.config.database == "two")
    #expect(imported.config.port == 6543)
    #expect(imported.password == "pw")
    #expect(imported.warnings.isEmpty)
    #expect(throws: PostgresURIParser.ParseError.invalidPort) {
      try PostgresURIParser.parse("postgresql://h/d?port=abc")
    }
  }

  @Test("a URI password parameter is ignored with a key-only warning")
  func uriPasswordParameterIgnored() throws {
    let imported = try PostgresURIParser.parse("postgresql://u@h/d?password=QuerySecret7")
    #expect(imported.password == nil)
    #expect(imported.warnings.count == 1)
    #expect(imported.warnings.allSatisfy { !$0.contains("QuerySecret7") })
    #expect(imported.warnings.first?.contains("password") == true)
  }
}
