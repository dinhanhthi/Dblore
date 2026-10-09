// DatabaseCapabilitiesTests.swift
// DatabaseType.capabilities: PostgreSQL keeps today's features; SQLite is available as beta;
// DuckDB is a file engine offered only when its plugin is installed.

import Foundation
import Testing

@testable import Dblore

@Suite("Database Capabilities")
struct DatabaseCapabilitiesTests {

  @Test("PostgreSQL keeps today's features, reconnect cancel, and still requires a host")
  func postgresqlCapabilities() {
    let capabilities = DatabaseType.postgresql.capabilities
    #expect(capabilities == Self.postgresql)
    // Host stays required: the form gates on usesNetwork, and PostgreSQL uses the network.
    #expect(capabilities.usesNetwork)
  }

  @Test("SQLite is available as beta, without network, password, or SSL")
  func sqliteCapabilities() {
    let capabilities = DatabaseType.sqlite.capabilities
    #expect(capabilities == Self.sqlite)
    #expect(capabilities.isAvailable)
    #expect(!capabilities.usesNetwork)
    #expect(!capabilities.usesPassword)
    #expect(!capabilities.supportsSSL)
  }

  @Test("DuckDB is a file engine without staged edits, import, or FK lookup")
  func duckdbCapabilities() {
    let capabilities = DatabaseType.duckdb.capabilities
    #expect(capabilities == Self.duckdb)
    #expect(!capabilities.supportsRowStaging)
    #expect(!capabilities.supportsDataImport)
    #expect(!capabilities.supportsForeignKeyLookup)
    #expect(capabilities.requiresPlugin)
  }

  @Test("Every engine has an explicit capability set", arguments: DatabaseType.allCases)
  func everyEngineHasExplicitCapabilities(type: DatabaseType) throws {
    let expected = try #require(Self.expected[type], "No expected capabilities for \(type)")
    #expect(type.capabilities == expected)
  }

  @Test("The picker hides DuckDB while its plugin is not installed")
  func pickerHidesDuckDBWithoutPlugin() {
    let types = DatabaseType.connectionPickerTypes(
      showExperimental: false, isPluginInstalled: { _ in false })
    #expect(types == [.postgresql, .sqlite])
  }

  @Test("The picker lists DuckDB once its plugin is installed")
  func pickerListsDuckDBWithPlugin() {
    let types = DatabaseType.connectionPickerTypes(
      showExperimental: false, isPluginInstalled: { $0 == .duckdb })
    #expect(types == [.postgresql, .sqlite, .duckdb])
  }

  @Test("Showing experimental engines does not list DuckDB without its plugin")
  func experimentalToggleDoesNotBypassPlugin() {
    let types = DatabaseType.connectionPickerTypes(
      showExperimental: true, isPluginInstalled: { _ in false })
    #expect(!types.contains(.duckdb))
  }

  @Test("By default the picker treats the DuckDB plugin as not installed")
  func pickerDefaultProviderHidesDuckDB() {
    #expect(!DatabaseType.connectionPickerTypes(showExperimental: false).contains(.duckdb))
  }

  private static let expected: [DatabaseType: DatabaseCapabilities] = [
    .postgresql: postgresql, .sqlite: sqlite, .duckdb: duckdb,
  ]

  private static let postgresql = DatabaseCapabilities(
    usesNetwork: true,
    usesPassword: true,
    supportsSSL: true,
    supportsSchemas: true,
    supportsRolesAndUsers: true,
    supportsFunctions: true,
    supportsServerCursor: true,
    supportsSessionBrakes: true,
    cancelStrategy: .reconnect,
    cappedReadResetsSession: true,
    supportsExplainJSON: true,
    supportsExplainAnalyze: true,
    supportsUpdateOnly: true,
    supportsRowStaging: true,
    supportsDataImport: true,
    supportsForeignKeyLookup: true,
    requiresPlugin: false,
    isAvailable: true
  )

  private static let sqlite = DatabaseCapabilities(
    usesNetwork: false,
    usesPassword: false,
    supportsSSL: false,
    supportsSchemas: false,
    supportsRolesAndUsers: false,
    supportsFunctions: false,
    supportsServerCursor: false,
    supportsSessionBrakes: false,
    cancelStrategy: .interrupt,
    cappedReadResetsSession: false,
    supportsExplainJSON: false,
    supportsExplainAnalyze: false,
    supportsUpdateOnly: false,
    supportsRowStaging: true,
    supportsDataImport: true,
    supportsForeignKeyLookup: true,
    requiresPlugin: false,
    isAvailable: true
  )

  private static let duckdb = DatabaseCapabilities(
    usesNetwork: false,
    usesPassword: false,
    supportsSSL: false,
    supportsSchemas: true,
    supportsRolesAndUsers: false,
    supportsFunctions: false,
    supportsServerCursor: false,
    supportsSessionBrakes: false,
    cancelStrategy: .interrupt,
    cappedReadResetsSession: false,
    supportsExplainJSON: false,
    supportsExplainAnalyze: true,
    supportsUpdateOnly: false,
    supportsRowStaging: false,
    supportsDataImport: false,
    supportsForeignKeyLookup: false,
    requiresPlugin: true,
    isAvailable: true
  )
}
