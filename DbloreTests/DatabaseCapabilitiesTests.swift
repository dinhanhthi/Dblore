// DatabaseCapabilitiesTests.swift
// DatabaseType.capabilities: PostgreSQL keeps today's features; SQLite is available as beta;
// DuckDB is a file engine offered only when its plugin is installed. MongoDB is listed after
// MySQL. ClickHouse is a network plugin engine (no transactions, edits, import or dump); SQL
// Server is a network plugin engine with transactions, keyed grid edits and foreign key lookup
// (no structure editing, dump, import, user types, roles or Explain).

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

  @Test("An engine requires a plugin exactly when it names one", arguments: DatabaseType.allCases)
  func requiresPluginMatchesPluginID(type: DatabaseType) {
    #expect(type.capabilities.requiresPlugin == (type.pluginID != nil))
  }

  @Test("The picker hides DuckDB while its plugin is not installed")
  func pickerHidesDuckDBWithoutPlugin() {
    let types = DatabaseType.connectionPickerTypes(
      showExperimental: false, isPluginInstalled: { _ in false })
    #expect(types == [.postgresql, .sqlite, .mysql, .mongodb])
  }

  @Test("The picker lists DuckDB once its plugin is installed")
  func pickerListsDuckDBWithPlugin() {
    let types = DatabaseType.connectionPickerTypes(
      showExperimental: false, isPluginInstalled: { $0 == .duckdb })
    #expect(types == [.postgresql, .sqlite, .duckdb, .mysql, .mongodb])
  }

  @Test("Showing experimental engines does not list DuckDB without its plugin")
  func experimentalToggleDoesNotBypassPlugin() {
    let types = DatabaseType.connectionPickerTypes(
      showExperimental: true, isPluginInstalled: { _ in false })
    #expect(!types.contains(.duckdb))
  }

  @Test("MongoDB is listed after MySQL without experimental engines")
  func pickerListsMongoDBWithoutExperimental() {
    let types = DatabaseType.connectionPickerTypes(
      showExperimental: false, isPluginInstalled: { _ in false })
    #expect(types.last == .mongodb)
    #expect(types.firstIndex(of: .mysql).map { $0 + 1 } == types.firstIndex(of: .mongodb))
  }

  @Test("A SQL Server tab names a table outside dbo, so dbo.t and sales.t differ")
  @MainActor
  func sqlServerNamesNonDefaultSchema() {
    var state = DataViewerState(schema: "dbo", name: "orders", orderColumns: [])
    state.databaseType = .sqlserver
    #expect(state.title == "orders")
    state.schema = "sales"
    #expect(state.title == "sales.orders")
    #expect(SidebarSectionModel.filtersSchemas(.sqlserver))
  }

  private static let expected: [DatabaseType: DatabaseCapabilities] = [
    .postgresql: postgresql, .sqlite: sqlite, .duckdb: duckdb, .mysql: mysql, .mongodb: mongodb,
    .clickhouse: clickhouse, .sqlserver: sqlserver,
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
    cancelStrategy: .interrupt,
    cappedReadResetsSession: true,
    supportsExplainJSON: true,
    supportsExplainAnalyze: true,
    supportsUpdateOnly: true,
    supportsDefaultInUpdate: true,
    supportsRowStaging: true,
    supportsDataImport: true,
    supportsForeignKeyLookup: true,
    requiresPlugin: false,
    isAvailable: true,
    queryLanguage: .sql,
    supportsTransactions: true,
    supportsStructure: true,
    supportsSQLDump: true,
    supportsUserTypes: true
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
    supportsDefaultInUpdate: false,
    supportsRowStaging: true,
    supportsDataImport: true,
    supportsForeignKeyLookup: true,
    requiresPlugin: false,
    isAvailable: true,
    queryLanguage: .sql,
    supportsTransactions: true,
    supportsStructure: true,
    supportsSQLDump: true,
    supportsUserTypes: false
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
    supportsDefaultInUpdate: false,
    supportsRowStaging: false,
    supportsDataImport: true,
    supportsForeignKeyLookup: false,
    requiresPlugin: true,
    isAvailable: true,
    queryLanguage: .sql,
    supportsTransactions: true,
    supportsStructure: true,
    supportsSQLDump: true,
    supportsUserTypes: false
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
    supportsDefaultInUpdate: true,
    supportsRowStaging: true,
    supportsDataImport: true,
    supportsForeignKeyLookup: true,
    requiresPlugin: false,
    isAvailable: true,
    queryLanguage: .sql,
    supportsTransactions: true,
    supportsStructure: true,
    supportsSQLDump: true,
    supportsUserTypes: false
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
    supportsDefaultInUpdate: false,
    supportsRowStaging: false,
    supportsDataImport: false,
    supportsForeignKeyLookup: false,
    requiresPlugin: false,
    isAvailable: true,
    queryLanguage: .mongosh,
    supportsTransactions: false,
    supportsStructure: false,
    supportsSQLDump: false,
    supportsUserTypes: false
  )

  private static let clickhouse = DatabaseCapabilities(
    usesNetwork: true,
    usesPassword: true,
    supportsSSL: true,
    supportsSchemas: true,
    supportsRolesAndUsers: false,
    supportsFunctions: false,
    supportsServerCursor: false,
    supportsSessionBrakes: true,
    cancelStrategy: .interrupt,
    cappedReadResetsSession: false,
    supportsExplainJSON: false,
    supportsExplainAnalyze: false,
    supportsUpdateOnly: false,
    supportsDefaultInUpdate: false,
    supportsRowStaging: false,
    supportsDataImport: false,
    supportsForeignKeyLookup: false,
    requiresPlugin: true,
    isAvailable: true,
    queryLanguage: .sql,
    supportsTransactions: false,
    supportsStructure: false,
    supportsSQLDump: false,
    supportsUserTypes: false
  )

  private static let sqlserver = DatabaseCapabilities(
    usesNetwork: true,
    usesPassword: true,
    supportsSSL: true,
    supportsSchemas: true,
    supportsRolesAndUsers: false,
    supportsFunctions: true,
    supportsServerCursor: false,
    supportsSessionBrakes: true,
    cancelStrategy: .interrupt,
    cappedReadResetsSession: false,
    supportsExplainJSON: false,
    supportsExplainAnalyze: false,
    supportsUpdateOnly: false,
    supportsDefaultInUpdate: true,
    supportsRowStaging: true,
    supportsDataImport: false,
    supportsForeignKeyLookup: true,
    requiresPlugin: true,
    isAvailable: true,
    queryLanguage: .sql,
    supportsTransactions: true,
    supportsStructure: false,
    supportsSQLDump: false,
    supportsUserTypes: false
  )
}
