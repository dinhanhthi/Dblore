// DatabaseCapabilitiesTests.swift
// DatabaseType.capabilities: PostgreSQL keeps today's features; SQLite is available as beta;
// DuckDB is a file engine offered only when its plugin is installed. MongoDB is hidden until
// experimental engines are shown.

import Foundation
import Testing

@testable import Dblore

@Suite("Database Capabilities")
struct DatabaseCapabilitiesTests {

  @Test("Every engine has an explicit capability set", arguments: DatabaseType.allCases)
  func everyEngineHasExplicitCapabilities(type: DatabaseType) throws {
    let expected = try #require(Self.expected[type], "No expected capabilities for \(type)")
    #expect(type.capabilities == expected)
  }

  @Test("The picker hides DuckDB while its plugin is not installed")
  func pickerHidesDuckDBWithoutPlugin() {
    let types = DatabaseType.connectionPickerTypes(
      showExperimental: false, isPluginInstalled: { _ in false })
    #expect(types == [.postgresql, .sqlite, .mysql])
  }

  @Test("The picker lists DuckDB once its plugin is installed")
  func pickerListsDuckDBWithPlugin() {
    let types = DatabaseType.connectionPickerTypes(
      showExperimental: false, isPluginInstalled: { $0 == .duckdb })
    #expect(types == [.postgresql, .sqlite, .duckdb, .mysql])
  }

  @Test("Showing experimental engines does not list DuckDB without its plugin")
  func experimentalToggleDoesNotBypassPlugin() {
    let types = DatabaseType.connectionPickerTypes(
      showExperimental: true, isPluginInstalled: { _ in false })
    #expect(!types.contains(.duckdb))
  }

  @Test("MongoDB is listed only when experimental engines are shown")
  func pickerListsMongoDBOnlyWhenExperimental() {
    #expect(!DatabaseType.connectionPickerTypes(showExperimental: false).contains(.mongodb))
    #expect(
      DatabaseType.connectionPickerTypes(showExperimental: true)
        == [.postgresql, .sqlite, .mysql, .mongodb])
  }

  private static let expected: [DatabaseType: DatabaseCapabilities] = [
    .postgresql: postgresql, .sqlite: sqlite, .duckdb: duckdb, .mysql: mysql, .mongodb: mongodb,
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
    isAvailable: true,
    queryLanguage: .sql,
    supportsTransactions: true,
    supportsStructure: true,
    supportsSQLDump: true
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
    isAvailable: true,
    queryLanguage: .sql,
    supportsTransactions: true,
    supportsStructure: true,
    supportsSQLDump: true
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
    isAvailable: true,
    queryLanguage: .sql,
    supportsTransactions: true,
    supportsStructure: true,
    supportsSQLDump: false
  )

  private static let mysql = DatabaseCapabilities(
    usesNetwork: true,
    usesPassword: true,
    supportsSSL: true,
    supportsSchemas: false,
    supportsRolesAndUsers: false,
    supportsFunctions: true,
    supportsServerCursor: false,
    supportsSessionBrakes: true,
    cancelStrategy: .interrupt,
    cappedReadResetsSession: false,
    supportsExplainJSON: true,
    supportsExplainAnalyze: true,
    supportsUpdateOnly: false,
    supportsRowStaging: true,
    supportsDataImport: true,
    supportsForeignKeyLookup: true,
    requiresPlugin: false,
    isAvailable: true,
    queryLanguage: .sql,
    supportsTransactions: true,
    supportsStructure: true,
    supportsSQLDump: true
  )

  private static let mongodb = DatabaseCapabilities(
    usesNetwork: true,
    usesPassword: true,
    supportsSSL: true,
    supportsSchemas: false,
    supportsRolesAndUsers: false,
    supportsFunctions: false,
    supportsServerCursor: false,
    supportsSessionBrakes: true,
    cancelStrategy: .interrupt,
    cappedReadResetsSession: false,
    supportsExplainJSON: false,
    supportsExplainAnalyze: false,
    supportsUpdateOnly: false,
    supportsRowStaging: false,
    supportsDataImport: false,
    supportsForeignKeyLookup: false,
    requiresPlugin: false,
    isAvailable: false,
    queryLanguage: .mongosh,
    supportsTransactions: false,
    supportsStructure: false,
    supportsSQLDump: false
  )
}
