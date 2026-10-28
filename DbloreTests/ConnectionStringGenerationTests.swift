// ConnectionStringGenerationTests.swift
// The PostgreSQL Connection String tab (`ConnectionFormContent.generateConnectionString(_:)` and
// `parsed(_:into:generatedFrom:)`): the generated URL never shows the saved password, reading it
// back keeps the password, a URL for another target without a password clears it, and typing the
// generated target back restores it.

import Foundation
import Testing

@testable import Dblore

@Suite @MainActor
struct ConnectionStringGenerationTests {
  private let config = ConnectionConfig(
    databaseType: .postgresql,
    host: "db.example.com",
    port: 5433,
    database: "app",
    username: "alice",
    password: "s3cr3t",
    sslMode: .require,
    timeoutSeconds: 30
  )

  @Test func generatedURLHasNoPassword() throws {
    let text = ConnectionFormContent.generateConnectionString(config)
    #expect(!text.contains("s3cr3t"))
    let url = try #require(URL(string: text))
    #expect(url.password == nil)
    #expect(url.user == "alice")
    #expect(url.host == "db.example.com")
  }

  @Test func readingTheGeneratedURLBackKeepsThePassword() throws {
    let text = ConnectionFormContent.generateConnectionString(config)
    let parsed = try ConnectionFormContent.parsed(text, into: config, generatedFrom: config)
    #expect(parsed.password == "s3cr3t")
    #expect(parsed.host == config.host && parsed.port == config.port)
    #expect(parsed.database == config.database && parsed.username == config.username)
  }

  @Test func urlForAnotherHostWithoutPasswordClearsIt() throws {
    let parsed = try ConnectionFormContent.parsed(
      "postgresql://alice@other.example.com:5433/app", into: config, generatedFrom: config)
    #expect(parsed.password == "")
    #expect(parsed.host == "other.example.com")
  }

  @Test func editedURLTypedBackRestoresThePassword() throws {
    let text = ConnectionFormContent.generateConnectionString(config)
    let edited = try ConnectionFormContent.parsed(
      text.replacingOccurrences(of: "db.example.com", with: "db.example.co"), into: config,
      generatedFrom: config)
    #expect(edited.password == "")
    // Each keystroke parses into the config the previous one left
    let typedBack = try ConnectionFormContent.parsed(text, into: edited, generatedFrom: config)
    #expect(typedBack.password == "s3cr3t")
    #expect(typedBack.host == config.host)
  }
}
