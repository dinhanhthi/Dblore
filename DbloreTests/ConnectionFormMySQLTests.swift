// ConnectionFormMySQLTests.swift
// The connection form for MySQL / MariaDB: default port, required database, no SSH, no
// connection string tab, the SSL section and its help text, the picker entry and the icon.
// The footer "No SSL" and "Unverified SSL" badges follow how the session is protected; the live cases read it
// through `DatabaseConnectionManager.mysqlTransport` (opt-in `.requiresMySQL`).

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct ConnectionFormMySQLTests {
  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  // MARK: - Port

  @Test func switchingToMySQLStartsOn3306() {
    let draft = ConnectionFormContent.formAfterEngineChange(
      fieldsEngine: .postgresql, newType: .mysql)
    #expect(draft?.databaseType == .mysql)
    #expect(draft?.port == 3306)
    let back = ConnectionFormContent.formAfterEngineChange(
      fieldsEngine: .mysql, newType: .postgresql)
    #expect(back?.port == 5432)
  }

  @Test func loadedMySQLFieldsKeepTheirPort() {
    // A history row or an owner draft already belongs to MySQL: the form keeps every field.
    #expect(
      ConnectionFormContent.formAfterEngineChange(fieldsEngine: .mysql, newType: .mysql) == nil)
    #expect(
      ConnectionFormContent.formAfterEngineChange(
        fieldsEngine: .postgresql, newType: .mysql, draftReplaced: true) == nil)
  }

  // MARK: - Required fields

  @Test func databaseIsRequired() {
    var config = ConnectionConfig(
      databaseType: .mysql, host: "localhost", port: 3306, database: "", username: "root")
    #expect(!ConnectionFormContent.isFormInputValid(config))
    config.database = "app"
    #expect(ConnectionFormContent.isFormInputValid(config))
  }

  // MARK: - Sections

  // MARK: - Picker and icon

  // MARK: - SSL badges

  @Test func encryptedMySQLHidesTheNoSSLBadge() {
    for mode in [SSLMode.allow, .prefer] {
      let config = ConnectionConfig(databaseType: .mysql, sslMode: mode)
      for transport in [MySQLTransport.encryptedUnverified, .verified] {
        #expect(
          FooterView.noSSLTooltip(for: config, isConnected: true, transport: transport) == nil)
      }
    }
  }

  @Test func plaintextFallbackShowsTheNoSSLBadge() {
    for mode in [SSLMode.allow, .prefer] {
      let config = ConnectionConfig(databaseType: .mysql, sslMode: mode)
      #expect(
        FooterView.noSSLTooltip(for: config, isConnected: true, transport: .plaintext)
          == "SSL mode \(mode.displayName): the server offered no SSL, so the connection is "
          + "unencrypted")
      #expect(
        FooterView.unverifiedSSLTooltip(for: config, isConnected: true, transport: .plaintext)
          == nil)
    }
    let disabled = ConnectionConfig(databaseType: .mysql, sslMode: .disable)
    #expect(
      FooterView.noSSLTooltip(for: disabled, isConnected: true, transport: .plaintext)
        == "SSL mode Disable: the connection is unencrypted")
  }

  @Test func unknownTransportKeepsTheConfigBasedBadge() {
    let config = ConnectionConfig(databaseType: .mysql, sslMode: .prefer)
    #expect(
      FooterView.noSSLTooltip(for: config, isConnected: true)
        == "SSL mode Prefer: the connection may be unencrypted")
    #expect(FooterView.unverifiedSSLTooltip(for: config, isConnected: true, transport: nil) == nil)
    #expect(
      FooterView.noSSLTooltip(for: config, isConnected: false, transport: .plaintext) == nil)
  }

  @Test(arguments: [SSLMode.allow, .prefer, .require])
  func encryptedWithoutVerificationShowsTheUnverifiedBadge(_ mode: SSLMode) {
    let config = ConnectionConfig(databaseType: .mysql, sslMode: mode)
    #expect(
      FooterView.unverifiedSSLTooltip(
        for: config, isConnected: true, transport: .encryptedUnverified)
        == "SSL mode \(mode.displayName): encrypted, but the server certificate is not "
        + "verified, so an active man in the middle can intercept the connection and the password")
    #expect(
      FooterView.unverifiedSSLTooltip(
        for: config, isConnected: false, transport: .encryptedUnverified) == nil)
  }

  // MARK: - Live transport state

  @Test("Disable to MariaDB reports a plaintext connection", .requiresMySQL)
  func disableReportsPlaintext() async throws {
    let manager = DatabaseConnectionManager()
    #expect(await manager.mysqlTransport == nil)
    try await manager.connect(
      config: MySQLSessionTests.config(port: TestMySQLDatabase.mariaDBPort, sslMode: .disable))
    #expect(await manager.mysqlTransport == .plaintext)
    await manager.disconnect()
    #expect(await manager.mysqlTransport == nil)
  }

  @Test(
    "Allow, Prefer and Require to MariaDB's self-signed auto TLS connect encrypted, not verified",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [SSLMode.allow, .prefer, .require])
  func selfSignedTLSIsEncryptedNotVerified(_ mode: SSLMode) async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(
      config: MySQLSessionTests.config(port: TestMySQLDatabase.mariaDBPort, sslMode: mode))
    #expect(await manager.mysqlTransport == .encryptedUnverified)
    let policy = ProtectionPolicy(protectionLevel: .none)
    let cipher = try await manager.execute(
      userSQL: "SHOW SESSION STATUS LIKE 'Ssl_cipher'", policy: policy)
    #expect(cipher.rows.count == 1)
    #expect(cipher.rows.first?.last != .string(""))
    await manager.disconnect()
  }

  @Test(
    "Verify CA and Verify Full refuse MariaDB's self-signed certificate without plain-text retry",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [SSLMode.verifyCa, .verifyFull])
  func selfSignedTLSFailsVerification(_ mode: SSLMode) async throws {
    let manager = DatabaseConnectionManager()
    await #expect(throws: DatabaseError.self) {
      try await manager.connect(
        config: MySQLSessionTests.config(port: TestMySQLDatabase.mariaDBPort, sslMode: mode))
    }
    #expect(await manager.mysqlTransport == nil)
    #expect(await !manager.isConnected)
  }

  @Test(
    "Prefer through a proxy that strips SSL reports the plaintext fallback", .requiresMySQL,
    .timeLimit(.minutes(1)))
  func preferFallbackReportsPlaintext() async throws {
    let proxy = try await NoTLSServer.start(upstreamPort: TestMySQLDatabase.port)
    let manager = DatabaseConnectionManager()
    do {
      try await manager.connect(
        config: MySQLSessionTests.config(port: proxy.port, sslMode: .prefer))
      #expect(await manager.mysqlTransport == .plaintext)
    } catch {
      await proxy.stop()
      throw error
    }
    await manager.disconnect()
    await proxy.stop()
  }

  @Test(
    "Verify Full with the fixture CA reports a verified connection", .requiresMySQL,
    .requiresMySQLTLS, .timeLimit(.minutes(1)))
  func fixtureCAReportsVerified() async throws {
    var config = MySQLSessionTests.config(port: TestMySQLDatabase.port, sslMode: .verifyFull)
    config.clientCertificate = ClientCertificateInfo(
      subject: "dblore test client", expiry: nil, hasCA: true)
    let manager = DatabaseConnectionManager()
    try await MySQLSessionTests.withMaterial(for: config) {
      try await manager.connect(config: config)
    }
    #expect(await manager.mysqlTransport == .verified)
    await manager.disconnect()
  }
}
