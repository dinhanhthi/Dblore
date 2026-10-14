// MongoURIParserTests.swift
// Unit tests for mongodb:// and mongodb+srv:// connection string parsing

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("MongoDB URI Parser")
struct MongoURIParserTests {

  private typealias Host = ParsedMongoURI.Host

  // MARK: - Accepted input

  @Test("parses a basic URI, scheme case-insensitive, whitespace trimmed")
  func basicURI() throws {
    for scheme in ["mongodb", "MongoDB"] {
      let uri = try MongoURIParser.parse("  \(scheme)://alice:secret@db.example.com:27018/sales\n")
      #expect(uri.isSRV == false)
      #expect(uri.hosts == [Host(name: "db.example.com", port: 27018)])
      #expect(uri.username == "alice")
      #expect(uri.password == "secret")
      #expect(uri.database == "sales")
      #expect(uri.tls == nil)
      #expect(uri.sslMode == .disable)
      #expect(uri.ignoredOptions.isEmpty)
    }
  }

  @Test("a bare host has no credentials, database or port")
  func bareHost() throws {
    for text in ["mongodb://localhost", "mongodb://localhost/", "mongodb://localhost#frag"] {
      let uri = try MongoURIParser.parse(text)
      #expect(uri.hosts == [Host(name: "localhost", port: nil)])
      #expect(uri.username == nil)
      #expect(uri.password == nil)
      #expect(uri.database == nil)
      #expect(uri.sslMode == .disable)
    }
  }

  @Test("percent-decodes user, password and database")
  func percentDecoding() throws {
    let uri = try MongoURIParser.parse("mongodb://al%40ice:p%40ss%3Aw%2Frd%25@h/my%2Ddb")
    #expect(uri.username == "al@ice")
    #expect(uri.password == "p@ss:w/rd%")
    #expect(uri.database == "my-db")
  }

  @Test("an empty password differs from no password")
  func emptyPassword() throws {
    #expect(try MongoURIParser.parse("mongodb://u:@h").password == "")
    #expect(try MongoURIParser.parse("mongodb://u@h").password == nil)
    #expect(try MongoURIParser.parse("mongodb://u@h").username == "u")
  }

  @Test("multiple hosts, bracketed IPv6 and ports")
  func multipleHosts() throws {
    let uri = try MongoURIParser.parse("mongodb://h1:27017,h2,[::1]:27018,[2001:db8::1]/db")
    #expect(
      uri.hosts == [
        Host(name: "h1", port: 27017), Host(name: "h2", port: nil),
        Host(name: "::1", port: 27018), Host(name: "2001:db8::1", port: nil),
      ])
  }

  @Test("options without a slash before the query")
  func queryWithoutSlash() throws {
    let uri = try MongoURIParser.parse("mongodb://h?tls=true")
    #expect(uri.database == nil)
    #expect(uri.tls == true)
  }

  @Test("every allow-listed option, keys case-insensitive")
  func allowListedOptions() throws {
    let uri = try MongoURIParser.parse(
      "mongodb://h/db?AUTHSOURCE=admin&authmechanism=scram-sha-256&TLS=TRUE&replicaset=rs%200"
        + "&DirectConnection=false&appname=My%20App&readpreference=SECONDARYPREFERRED")
    #expect(uri.authSource == "admin")
    #expect(uri.authMechanism == .scramSHA256)
    #expect(uri.tls == true)
    #expect(uri.replicaSet == "rs 0")
    #expect(uri.directConnection == false)
    #expect(uri.appName == "My App")
    #expect(uri.readPreference == .secondaryPreferred)
    #expect(uri.ignoredOptions.isEmpty)
    #expect(
      try MongoURIParser.parse("mongodb://h/?authMechanism=SCRAM-SHA-1").authMechanism == .scramSHA1
    )
    #expect(try MongoURIParser.parse("mongodb://h/?directConnection=true").directConnection == true)
  }

  @Test("ssl is an alias of tls; equal repeats are fine")
  func sslAlias() throws {
    #expect(try MongoURIParser.parse("mongodb://h/?ssl=true").sslMode == .verifyFull)
    #expect(try MongoURIParser.parse("mongodb://h/?ssl=false").sslMode == .disable)
    #expect(try MongoURIParser.parse("mongodb://h/?tls=true&ssl=true").tls == true)
    #expect(try MongoURIParser.parse("mongodb://h/?tls=false").sslMode == .disable)
  }

  @Test("a repeated option keeps its last value")
  func repeatedOptionLastWins() throws {
    let uri = try MongoURIParser.parse("mongodb://h/?authSource=a&AuthSource=b&appName=x&appName=y")
    #expect(uri.authSource == "b")
    #expect(uri.appName == "y")
  }

  @Test("unknown options are ignored, listed once, and not stored")
  func unknownOptions() throws {
    let uri = try MongoURIParser.parse(
      "mongodb://h/db?retryWrites=true&w=majority&retryWrites=false&tlsInsecure=false"
        + "&compressors=zlib&authSource=admin")
    #expect(uri.ignoredOptions == ["retryWrites", "w", "tlsInsecure", "compressors"])
    #expect(uri.authSource == "admin")
    #expect(!uri.storedURI.contains("retryWrites"))
    #expect(!uri.storedURI.contains("majority"))
    #expect(!uri.storedURI.contains("tlsInsecure"))
  }

  // MARK: - SRV

  @Test("+srv implies TLS, keeps the single host and leaves authSource unset")
  func srv() throws {
    let uri = try MongoURIParser.parse("mongodb+srv://u:p@cluster0.example.net/app")
    #expect(uri.isSRV)
    #expect(uri.hosts == [Host(name: "cluster0.example.net", port: nil)])
    #expect(uri.tls == nil)
    #expect(uri.sslMode == .verifyFull)
    #expect(uri.authSource == nil)
  }

  @Test("+srv with an explicit tls=false is honoured, per the URI spec")
  func srvTLSFalse() throws {
    let uri = try MongoURIParser.parse("mongodb+srv://cluster0.example.net/?tls=false")
    #expect(uri.sslMode == .disable)
  }

  // MARK: - Refusals

  @Test(
    "refuses invalid input with a message that echoes nothing",
    arguments: [
      ("", MongoURIParser.ParseError.unsupportedScheme),
      ("localhost:27017", .unsupportedScheme),
      ("garbage", .unsupportedScheme),
      ("postgres://h/db", .unsupportedScheme),
      ("mongodb:/h", .unsupportedScheme),
      ("mongodb://", .missingHost),
      ("mongodb:///db", .missingHost),
      ("mongodb://u:p@/db", .missingHost),
      ("mongodb://h1,,h2", .missingHost),
      ("mongodb://p%ZZ@h", .invalidPercentEncoding),
      ("mongodb://u:p@ss@h", .unescapedUserInfo),
      ("mongodb://u:p:ss@h", .unescapedUserInfo),
      ("mongodb://:hunter2@h", .emptyUsername),
      ("mongodb://@h", .emptyUsername),
      ("mongodb://h:0", .invalidPort),
      ("mongodb://h:65536", .invalidPort),
      ("mongodb://h:", .invalidPort),
      ("mongodb://h:12a", .invalidPort),
      ("mongodb://[::1]x", .invalidHost),
      ("mongodb://[::1", .invalidHost),
      ("mongodb://::1", .invalidHost),
      ("mongodb://bad%20host", .invalidHost),
      ("mongodb://h%2Cx", .invalidHost),
      ("mongodb://%2Ftmp%2Fmongodb-27017.sock", .unixSocketNotSupported),
      ("mongodb://h/a/b", .invalidDatabaseName),
      ("mongodb://h/a%2Fb", .invalidDatabaseName),
      ("mongodb://h/a.b", .invalidDatabaseName),
      ("mongodb://h/a%20b", .invalidDatabaseName),
      ("mongodb://h/a$b", .invalidDatabaseName),
      ("mongodb://h/a%22b", .invalidDatabaseName),
      ("mongodb://h/a%5Cb", .invalidDatabaseName),
      ("mongodb://h/a%00b", .invalidDatabaseName),
      ("mongodb://h/" + String(repeating: "d", count: 64), .invalidDatabaseName),
      ("mongodb://h/?authMechanism=MONGODB-X509", .unsupportedAuthMechanism),
      ("mongodb://h/?authMechanism=GSSAPI", .unsupportedAuthMechanism),
      ("mongodb://h/?authMechanism=PLAIN", .unsupportedAuthMechanism),
      ("mongodb://h/?authMechanism=MONGODB-AWS", .unsupportedAuthMechanism),
      ("mongodb://h/?tls=true&ssl=false", .conflictingTLSOptions),
      ("mongodb://h/?tls=true&tls=false", .conflictingTLSOptions),
      ("mongodb://h/?tls=yes", .invalidOptionValue("tls")),
      ("mongodb://h/?ssl", .invalidOptionValue("ssl")),
      ("mongodb://h/?directConnection=1", .invalidOptionValue("directConnection")),
      ("mongodb://h/?readPreference=fastest", .invalidOptionValue("readPreference")),
      ("mongodb://h/?authSource=", .invalidOptionValue("authSource")),
      ("mongodb://h/?replicaSet=", .invalidOptionValue("replicaSet")),
      ("mongodb://h/?appName=", .invalidOptionValue("appName")),
      ("mongodb://h/?tlsCAFile=%2Fetc%2Fca.pem", .tlsFileNotSupported),
      ("mongodb://h/?tlsCertificateKeyFile=c.pem", .tlsFileNotSupported),
      ("mongodb://h/?tlsInsecure=true", .insecureTLSNotSupported),
      ("mongodb://h/?TLSALLOWINVALIDCERTIFICATES=true", .insecureTLSNotSupported),
      ("mongodb://h/?tlsAllowInvalidHostnames=true", .insecureTLSNotSupported),
      ("mongodb://h1,h2/?directConnection=true", .directConnectionWithMultipleHosts),
      ("mongodb+srv://c.example.net:27017", .srvWithPort),
      ("mongodb+srv://a.example.net,b.example.net", .srvWithMultipleHosts),
      ("mongodb+srv://c.example.net/?directConnection=true", .srvWithDirectConnection),
    ])
  func refusals(input: String, expected: MongoURIParser.ParseError) throws {
    let error = #expect(throws: MongoURIParser.ParseError.self) {
      try MongoURIParser.parse(input)
    }
    #expect(error == expected)
    let message = try #require(error?.errorDescription)
    #expect(!message.isEmpty)
    for secret in ["hunter2", "ss@h", "X509", "GSSAPI", "fastest", "ca.pem", "c.example.net"] {
      #expect(!message.contains(secret))
    }
  }

  @Test("refusal messages name the fix")
  func refusalMessages() {
    typealias E = MongoURIParser.ParseError
    #expect(E.unsupportedScheme.errorDescription?.contains("mongodb+srv://") == true)
    #expect(E.unsupportedAuthMechanism.errorDescription?.contains("SCRAM-SHA-256") == true)
    #expect(E.tlsFileNotSupported.errorDescription?.contains("Keychain") == true)
    #expect(E.insecureTLSNotSupported.errorDescription?.contains("verif") == true)
    #expect(E.unescapedUserInfo.errorDescription?.contains("Percent-encode") == true)
    #expect(E.invalidOptionValue("tls").errorDescription?.contains("tls") == true)
  }

  // MARK: - Stored URI and config

  @Test("the stored URI has no userinfo or unknown options and re-parses to the same options")
  func storedURIReparses() throws {
    let texts = [
      "mongodb://al%40ice:p%40ss@h1:27017,h2,[::1]:27018/my%2Ddb?authSource=admin"
        + "&authMechanism=SCRAM-SHA-1&ssl=true&replicaSet=rs%200&appName=A%26B%3DC"
        + "&readPreference=nearest&w=majority",
      "mongodb+srv://u:p@cluster0.example.net/app?tls=false&directConnection=false",
      "mongodb://h/?directConnection=true",
      "mongodb://localhost",
    ]
    for text in texts {
      let parsed = try MongoURIParser.parse(text)
      let stored = parsed.storedURI
      #expect(!stored.contains("@"))
      #expect(!stored.contains("p%40ss"))
      #expect(!stored.contains("majority"))
      var expected = parsed
      expected.username = nil
      expected.password = nil
      expected.ignoredOptions = []
      #expect(try MongoURIParser.parse(stored) == expected)
    }
  }

  @Test("the stored URI of a simple connection")
  func storedURIText() throws {
    #expect(try MongoURIParser.parse("mongodb://u:p@localhost").storedURI == "mongodb://localhost")
    #expect(
      try MongoURIParser.parse("mongodb+srv://u:p@c.example.net/db?tls=true&replicaSet=rs")
        .storedURI == "mongodb+srv://c.example.net/db?tls=true&replicaSet=rs")
  }

  @Test("applied(to:) fills host, port, database, user, TLS and the stored URI from the URI")
  func appliedToConfig() throws {
    let base = ConnectionConfig(
      databaseType: .mongodb, host: "old", port: 1, database: "old", username: "old",
      password: "kept", sslMode: .prefer, name: "My Mongo")

    let single = try MongoURIParser.parse("mongodb://bob:pw@db.example.com:27018/sales?tls=true")
      .applied(to: base)
    #expect(single.databaseType == .mongodb)
    #expect(single.host == "db.example.com")
    #expect(single.port == 27018)
    #expect(single.database == "sales")
    #expect(single.username == "bob")
    #expect(single.password == "kept")
    #expect(single.sslMode == .verifyFull)
    #expect(single.name == "My Mongo")
    #expect(single.mongoURI == "mongodb://db.example.com:27018/sales?tls=true")

    let multi = try MongoURIParser.parse("mongodb://h1,h2:27019").applied(to: base)
    #expect(multi.host == "h1")
    #expect(multi.port == 27017)
    #expect(multi.database == "")
    #expect(multi.username == "")
    #expect(multi.sslMode == .disable)

    let srv = try MongoURIParser.parse("mongodb+srv://cluster0.example.net").applied(to: base)
    #expect(srv.host == "cluster0.example.net")
    #expect(srv.port == 27017)
    #expect(srv.sslMode == .verifyFull)

    let ipv6 = try MongoURIParser.parse("mongodb://[::1]:27020").applied(to: base)
    #expect(ipv6.host == "::1")
    #expect(ipv6.port == 27020)
  }

  @Test("printing a parsed URI never shows the credentials")
  func redactedDescription() throws {
    let uri = try MongoURIParser.parse("mongodb://alice:hunter2@h/db")
    var dumped = ""
    dump(uri, to: &dumped)
    for text in ["\(uri)", String(reflecting: uri), dumped] {
      #expect(!text.contains("hunter2"))
      #expect(!text.contains("alice"))
    }
  }
}
