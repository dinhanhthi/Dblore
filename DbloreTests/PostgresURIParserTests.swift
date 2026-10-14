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
      "", "hello world", "sqlserver://u@h/d", "postgresql://u@h:99999/d", "postgresql://u@h:abc/d",
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

  // MARK: - MySQL / MariaDB

  @Test("parses mysql:// and mariadb:// URIs with the MySQL default port")
  func mysqlBasicURI() throws {
    for scheme in ["mysql", "mariadb", "MySQL"] {
      let imported = try PostgresURIParser.parse("\(scheme)://alice:secret@db.example.com/shop")
      #expect(imported.config.databaseType == .mysql)
      #expect(imported.config.host == "db.example.com")
      #expect(imported.config.port == 3306)
      #expect(imported.config.database == "shop")
      #expect(imported.config.username == "alice")
      #expect(imported.config.password == "")
      #expect(imported.config.sslMode == .prefer)
      #expect(imported.config.name == "alice@db.example.com/shop")
      #expect(imported.password == "secret")
      #expect(imported.source == .uri)
      #expect(imported.warnings.isEmpty)
    }
    let custom = try PostgresURIParser.parse("mysql://u@h:3307/d")
    #expect(custom.config.port == 3307)
  }

  @Test("mysql:// percent-decodes the password and reads bracketed IPv6 hosts")
  func mysqlEncodingAndIPv6() throws {
    let encoded = try PostgresURIParser.parse("mysql://r%40ot:p%40ss%3Aw%2Frd%23@h/my%20db")
    #expect(encoded.config.username == "r@ot")
    #expect(encoded.password == "p@ss:w/rd#")
    #expect(encoded.config.database == "my db")
    let withPort = try PostgresURIParser.parse("mariadb://u@[2001:db8::1]:3307/d")
    #expect(withPort.config.host == "2001:db8::1")
    #expect(withPort.config.port == 3307)
    let noPort = try PostgresURIParser.parse("mysql://u@[::1]/d")
    #expect(noPort.config.host == "::1")
    #expect(noPort.config.port == 3306)
  }

  @Test("a mysql:// URI without a database is kept, empty, with a warning")
  func mysqlMissingDatabase() throws {
    for uri in [
      "mysql://carol@h", "mysql://carol@h/", "mariadb://carol:pw@h:3306?ssl-mode=REQUIRED",
    ] {
      let imported = try PostgresURIParser.parse(uri)
      #expect(imported.config.databaseType == .mysql)
      #expect(imported.config.database == "")
      #expect(imported.warnings == [PostgresURIParser.missingDatabaseWarning])
    }
  }

  @Test(
    "maps MySQL, MariaDB and libpq SSL mode names",
    arguments: [
      ("ssl-mode", "DISABLED", SSLMode.disable), ("ssl-mode", "PREFERRED", .prefer),
      ("ssl-mode", "REQUIRED", .require), ("ssl-mode", "VERIFY_CA", .verifyCa),
      ("ssl-mode", "VERIFY_IDENTITY", .verifyFull), ("sslMode", "verify_identity", .verifyFull),
      ("sslMode", "trust", .require), ("sslMode", "verify-full", .verifyFull),
      ("sslmode", "disable", .disable), ("sslmode", "allow", .allow),
      ("SSLMODE", "verify-ca", .verifyCa),
    ])
  func mysqlSSLModes(key: String, raw: String, expected: SSLMode) throws {
    let imported = try PostgresURIParser.parse("mysql://u@h/d?\(key)=\(raw)")
    #expect(imported.config.sslMode == expected)
    #expect(imported.warnings.isEmpty)
  }

  @Test("useSSL=false disables TLS unless an explicit SSL mode is given")
  func mysqlUseSSL() throws {
    #expect(try PostgresURIParser.parse("mysql://u@h/d?useSSL=false").config.sslMode == .disable)
    #expect(try PostgresURIParser.parse("mysql://u@h/d?useSSL=true").config.sslMode == .prefer)
    #expect(
      try PostgresURIParser.parse("mysql://u@h/d?useSSL=false&sslMode=REQUIRED").config.sslMode
        == .require)
    #expect(
      try PostgresURIParser.parse("mysql://u@h/d?sslMode=REQUIRED&useSSL=false").config.sslMode
        == .require)
  }

  @Test("legacy Connector/J TLS flags never import weaker than they ask")
  func mysqlLegacyTLSFlags() throws {
    func mode(_ query: String) throws -> SSLMode {
      try PostgresURIParser.parse("mysql://u@h/d?\(query)").config.sslMode
    }
    #expect(try mode("requireSSL=true") == .require)
    #expect(try mode("verifyServerCertificate=true") == .verifyCa)
    #expect(try mode("verifyServerCertificate=true&requireSSL=true") == .verifyCa)
    #expect(try mode("verifyServerCertificate=true&useSSL=false") == .disable)
    #expect(try mode("requireSSL=true&sslMode=VERIFY_IDENTITY") == .verifyFull)
    #expect(try mode("sslMode=PREFERRED&requireSSL=true") == .prefer)
    let imported = try PostgresURIParser.parse("mysql://u@h/d?trustServerCertificate=false")
    #expect(imported.config.sslMode == .prefer)
    #expect(
      imported.warnings == [
        "TLS setting \"trustServerCertificate\" not imported; check the SSL mode."
      ])
  }

  @Test("mysql:// unknown parameters and a query password warn without echoing values")
  func mysqlUnknownParameters() throws {
    let imported = try PostgresURIParser.parse(
      "mysql://u@h/d?serverTimezone=UTC&password=QuerySecret7&user=bob&port=3310")
    #expect(imported.password == nil)
    #expect(imported.config.username == "bob")
    #expect(imported.config.port == 3310)
    #expect(imported.warnings.count == 2)
    #expect(imported.warnings.contains { $0.contains("serverTimezone") })
    #expect(imported.warnings.allSatisfy { !$0.contains("QuerySecret7") && !$0.contains("UTC") })
  }

  @Test("mysql:// rejects multiple hosts, sockets, bad ports and bad encoding")
  func mysqlRejected() {
    #expect(throws: PostgresURIParser.ParseError.multipleHostsNotSupported) {
      try PostgresURIParser.parse("mysql://u@h1:3306,h2:3306/d")
    }
    #expect(throws: PostgresURIParser.ParseError.unixSocketNotSupported) {
      try PostgresURIParser.parse("mysql://u@%2Ftmp%2Fmysql.sock/d")
    }
    #expect(throws: PostgresURIParser.ParseError.invalidPort) {
      try PostgresURIParser.parse("mysql://u@h:0/d")
    }
    #expect(throws: PostgresURIParser.ParseError.invalidPercentEncoding) {
      try PostgresURIParser.parse("mysql://u:%zz@h/d")
    }
    #expect(throws: PostgresURIParser.ParseError.missingHost) {
      try PostgresURIParser.parse("mysql:///d")
    }
  }
}
