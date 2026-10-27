// ConnectionFormMongoTests.swift
// The connection form for MongoDB (`MongoConnectionDraft`): a pasted URI fills the fields and
// moves its password out of the stored `mongoURI`, field edits rebuild that URI through
// `MongoURIParser`, TLS is Disable or Verify Full, no Review, no SSH, a custom CA without a
// client certificate, and a warning when TLS is off to a remote host.

import Foundation
import Testing

@testable import Dblore

@Suite @MainActor
struct ConnectionFormMongoTests {
  private static let pasted =
    "mongodb://alice:s3cr%40t@db.example.com:27018/app?authSource=admin&tls=true"
    + "&retryWrites=true&w=majority"

  private func pastedConfig() throws -> ConnectionConfig {
    try MongoConnectionDraft.paste(
      Self.pasted, into: ConnectionFormContent.newFormDraft(databaseType: .mongodb)
    ).config
  }

  /// The stored URI agrees with the form fields (port nil only for `+srv`).
  private func expectURIMatchesFields(_ config: ConnectionConfig) throws {
    let uri = try MongoURIParser.parse(try #require(config.mongoURI))
    #expect(uri.hosts.first?.name == config.host)
    #expect(
      uri.hosts.first?.port ?? (uri.isSRV ? config.port : MongoURIParser.defaultPort) == config.port
    )
    #expect((uri.database ?? "") == config.database)
    #expect(uri.sslMode == config.sslMode)
    #expect(uri.username == nil && uri.password == nil)
  }

  // MARK: - Connection string

  @Test func pastedURIFillsFieldsAndMovesThePassword() throws {
    let paste = try MongoConnectionDraft.paste(
      Self.pasted, into: ConnectionFormContent.newFormDraft(databaseType: .mongodb))
    let config = paste.config
    #expect(config.databaseType == .mongodb)
    #expect(config.host == "db.example.com")
    #expect(config.port == 27018)
    #expect(config.database == "app")
    #expect(config.username == "alice")
    #expect(config.password == "s3cr@t")
    #expect(config.sslMode == .verifyFull)
    let stored = try #require(config.mongoURI)
    #expect(!stored.contains("alice") && !stored.contains("s3cr") && !stored.contains("@"))
    #expect(MongoConnectionDraft.authSource(of: config) == "admin")
    #expect(paste.ignoredOptions == ["retryWrites", "w"])
    #expect(
      MongoConnectionDraft.ignoredOptionsNote(paste.ignoredOptions)
        == "Ignored options (not used by Dblore): retryWrites, w")
    #expect(MongoConnectionDraft.ignoredOptionsNote([]) == nil)
    try expectURIMatchesFields(config)
  }

  @Test func parseErrorsUseTheParserMessage() {
    do {
      _ = try MongoConnectionDraft.paste("postgresql://h/db", into: ConnectionConfig())
      Issue.record("expected a parse error")
    } catch {
      #expect(
        MongoConnectionDraft.message(for: error)
          == "The connection string must start with mongodb:// or mongodb+srv://.")
    }
  }

  @Test func connectionStringTabShowsTheUserButNeverThePassword() throws {
    let text = MongoConnectionDraft.connectionString(for: try pastedConfig())
    #expect(text.hasPrefix("mongodb://alice@db.example.com:27018/app?"))
    #expect(!text.contains("s3cr"))
    let reparsed = try MongoURIParser.parse(text)
    #expect(reparsed.username == "alice" && reparsed.password == nil)
    #expect(reparsed.authSource == "admin")
  }

  // MARK: - Field edits

  @Test func fieldEditsRebuildTheStoredURI() throws {
    var config = try pastedConfig()
    config.host = "other.example.com"
    config.port = 27019
    config.database = "shop"
    config.sslMode = .disable
    let rebuilt = MongoConnectionDraft.rebuilt(config)
    let uri = try MongoURIParser.parse(try #require(rebuilt.mongoURI))
    #expect(uri.hosts == [ParsedMongoURI.Host(name: "other.example.com", port: 27019)])
    #expect(uri.database == "shop")
    #expect(!uri.usesTLS)
    #expect(uri.authSource == "admin")
    try expectURIMatchesFields(rebuilt)
    #expect(MongoConnectionDraft.rebuilt(rebuilt) == rebuilt)

    let withAuthSource = MongoConnectionDraft.rebuilt(rebuilt, authSource: "users")
    #expect(MongoConnectionDraft.authSource(of: withAuthSource) == "users")
    let cleared = MongoConnectionDraft.rebuilt(withAuthSource, authSource: "")
    #expect(MongoConnectionDraft.authSource(of: cleared) == "")
    #expect(try MongoURIParser.parse(try #require(cleared.mongoURI)).authSource == nil)
  }

  @Test func invalidFieldsKeepTheLastValidURIAndBlockSaving() throws {
    var config = try pastedConfig()
    config.database = "a.b"
    let rebuilt = MongoConnectionDraft.rebuilt(config, authSource: "users")
    // The stored URI stays parseable with the old database; the auth source edit is kept.
    #expect(try MongoURIParser.parse(try #require(rebuilt.mongoURI)).database == "app")
    #expect(MongoConnectionDraft.authSource(of: rebuilt) == "users")
    #expect(
      MongoConnectionDraft.fieldError(rebuilt)
        == MongoURIParser.ParseError.invalidDatabaseName.errorDescription)
    #expect(!ConnectionFormContent.isFormInputValid(rebuilt))
    #expect(throws: MongoURIParser.ParseError.invalidDatabaseName) {
      try MongoConnectionDraft.prepared(rebuilt)
    }
  }

  @Test func savingStoresAURIThatMatchesTheFields() throws {
    var config = ConnectionFormContent.newFormDraft(databaseType: .mongodb)
    config.host = "db.example.com"
    config.port = 27018
    config.database = "app"
    config.username = "alice"
    config.password = "secret"
    config.sslMode = .verifyFull
    let saved = try MongoConnectionDraft.prepared(config)
    try expectURIMatchesFields(saved)
    #expect(saved.password == "secret")
    #expect(!(saved.mongoURI ?? "").contains("secret"))

    let srv = try MongoConnectionDraft.paste(
      "mongodb+srv://bob:pw@cluster0.example.net/app", into: config
    ).config
    try expectURIMatchesFields(try MongoConnectionDraft.prepared(srv))
  }

  @Test func hostWithURIDelimitersIsAFieldError() throws {
    var config = ConnectionFormContent.newFormDraft(databaseType: .mongodb)
    for host in ["evil?tls=false", "evil/db", "evil#x", "user@evil", "a,evil", "evil host"] {
      config.host = host
      let rebuilt = MongoConnectionDraft.rebuilt(config)
      #expect(
        MongoConnectionDraft.fieldError(rebuilt)
          == MongoURIParser.ParseError.invalidHost.errorDescription, "\(host)")
      #expect(!ConnectionFormContent.isFormInputValid(rebuilt), "\(host)")
      #expect(throws: MongoURIParser.ParseError.invalidHost) {
        try MongoConnectionDraft.prepared(rebuilt)
      }
    }
    // The query is not split off into the stored URI.
    config.host = "evil?tls=false"
    let stored = try MongoURIParser.parse(
      try #require(MongoConnectionDraft.rebuilt(config).mongoURI))
    #expect(stored.hosts.first?.name != "evil")
    #expect(stored.tls == nil)

    for host in ["db.example.com", "::1"] {
      config.host = host
      #expect(MongoConnectionDraft.fieldError(MongoConnectionDraft.rebuilt(config)) == nil)
    }
  }

  @Test func databaseAndUserAreOptional() {
    var config = ConnectionFormContent.newFormDraft(databaseType: .mongodb)
    config.host = "localhost"
    #expect(ConnectionFormContent.isFormInputValid(config))
    config.host = ""
    #expect(!ConnectionFormContent.isFormInputValid(config))
  }

  // MARK: - Engine

  @Test func newMongoDBFormStartsOn27017WithoutTLS() {
    let draft = ConnectionFormContent.formAfterEngineChange(
      fieldsEngine: .postgresql, newType: .mongodb)
    #expect(draft?.port == 27017)
    #expect(draft?.sslMode == .disable)
  }

  @Test func switchingToPostgreSQLClearsTheMongoURI() throws {
    let mongo = try pastedConfig()
    let draft = ConnectionFormContent.formAfterEngineChange(
      fieldsEngine: .mongodb, newType: .postgresql)
    #expect(draft != nil && draft?.mongoURI == nil)
    var switched = mongo
    switched.databaseType = .postgresql
    #expect(MongoConnectionDraft.rebuilt(switched).mongoURI == nil)
    #expect(try MongoConnectionDraft.prepared(switched).mongoURI == nil)
  }

  // MARK: - Sections and pickers

  @Test func tlsModesAreDisableAndVerifyFull() {
    #expect(MongoConnectionDraft.sslModes(for: .mongodb) == [.disable, .verifyFull])
    #expect(MongoConnectionDraft.sslModes(for: .postgresql) == SSLMode.allCases)
    var config = ConnectionFormContent.newFormDraft(databaseType: .mongodb)
    config.sslMode = .prefer
    #expect(MongoConnectionDraft.rebuilt(config).sslMode == .verifyFull)
  }

  @Test func reviewIsHiddenForMongoDB() {
    #expect(MongoConnectionDraft.commitStyles(for: .mongodb) == [.immediate, .confirm, .password])
    #expect(MongoConnectionDraft.commitStyles(for: .postgresql) == CommitStyle.allCases)
  }

  @Test func mongoDBOffersACustomCAButNoClientCertificate() {
    #expect(
      ConnectionFormContent.certificateFields(for: .mongodb, sslMode: .verifyFull) == .customCA)
    #expect(ConnectionFormContent.certificateFields(for: .mongodb, sslMode: .disable) == .none)
    #expect(
      ConnectionFormContent.certificateFields(for: .postgresql, sslMode: .verifyFull)
        == .clientCertificateAndCA)
  }

  // MARK: - TLS warning

  @Test func tlsOffWarnsOnlyForRemoteHosts() throws {
    var config = ConnectionFormContent.newFormDraft(databaseType: .mongodb)
    for host in ["localhost", "127.0.0.1", "::1"] {
      config.host = host
      #expect(MongoConnectionDraft.tlsWarning(for: MongoConnectionDraft.rebuilt(config)) == nil)
    }
    config.host = "db.example.com"
    #expect(MongoConnectionDraft.tlsWarning(for: MongoConnectionDraft.rebuilt(config)) != nil)
    config.sslMode = .verifyFull
    #expect(MongoConnectionDraft.tlsWarning(for: MongoConnectionDraft.rebuilt(config)) == nil)

    let srv = try MongoConnectionDraft.paste(
      "mongodb+srv://cluster0.example.net/?tls=false", into: config
    ).config
    #expect(srv.sslMode == .disable)
    #expect(MongoConnectionDraft.tlsWarning(for: srv) != nil)

    let seeds = try MongoConnectionDraft.paste(
      "mongodb://localhost:27017,db2.example.com:27017/", into: config
    ).config
    #expect(MongoConnectionDraft.tlsWarning(for: seeds) != nil)
  }
}
