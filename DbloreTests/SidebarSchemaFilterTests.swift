// SidebarSchemaFilterTests.swift
// A hidden schema leaves only the sidebar: autocomplete and schema search still see it, and the
// choice is saved on the connection's saved row like its color and group.

import Foundation
import Testing

@testable import Dblore

@Suite("Sidebar schema filter")
@MainActor
struct SidebarSchemaFilterTests {
  /// Remember on and no password (nothing reaches the Keychain); a unique host finds this
  /// test's row.
  private static func config() -> ConnectionConfig {
    ConnectionConfig(
      host: "schema-filter-\(UUID().uuidString).example", database: "app", username: "ada")
  }

  private static func workspace(_ config: ConnectionConfig) -> WorkspaceManager {
    WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(
          capabilities: DatabaseType.postgresql.capabilities)))
  }

  @Test(
    "A hidden schema is absent from the sidebar sections and present in autocomplete and search")
  func hiddenSchemaStaysOutOfSidebarOnly() async {
    var config = Self.config()
    config.hiddenSchemas = ["audit"]
    let manager = Self.workspace(config)
    manager.connectionState = .connected
    manager.databaseTables = [
      DatabaseTable(
        schema: "public", name: "users", columns: [DatabaseColumn(name: "id", type: "int4")]),
      DatabaseTable(
        schema: "audit", name: "audit_log",
        columns: [DatabaseColumn(name: "logged_at", type: "timestamptz")]),
    ]
    // As the schema load does: autocomplete gets every loaded table
    manager.autocompleteProvider.update(tables: manager.databaseTables)

    let hidden = Set(manager.workspace.connectionConfig?.hiddenSchemas ?? [])
    let schemas = manager.databaseTables.map(\.schema)
    #expect(SidebarSectionModel.filtersSchemas(.postgresql))
    #expect(
      SidebarSectionModel.listedSchemas(schemas, hidden: hidden, defaultSchema: "public")
        == ["public"])
    #expect(SidebarSectionModel.hiddenSchemasLabel(schemas, hidden: hidden) == "1 hidden")
    // Every schema hidden (the default one too) lists none: the tab shows its own empty state
    #expect(
      SidebarSectionModel.listedSchemas(
        schemas, hidden: ["public", "audit"], defaultSchema: "public"
      ).isEmpty)

    let text = "SELECT * FROM audit_"
    let suggestions = manager.autocompleteProvider.getSuggestions(
      for: text, at: text.utf16.count, dialect: .postgresql)
    #expect(suggestions.contains { $0.text == "audit_log" })

    await manager.loadSchemaGraph()
    await manager.performSchemaSearch(query: "audit_log", caseSensitive: false)
    #expect(manager.schemaSearchState.matches.contains { $0.tableName == "audit.audit_log" })
  }

  @Test("Hiding a schema saves it on the saved row, and saves from outside the form keep it")
  func hiddenSchemasSync() throws {
    let name = "SidebarSchemaFilterTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let saved = Self.config()
    #expect(SessionManager.saveConnection(saved, defaults: defaults, passwords: NoPasswordStore()))
    let manager = Self.workspace(saved)

    manager.setHiddenSchemas(
      ["audit", "audit", ""], defaults: defaults, passwords: NoPasswordStore())

    #expect(manager.workspace.connectionConfig?.hiddenSchemas == ["audit"])
    #expect(manager.editingConnectionConfig.hiddenSchemas == ["audit"])
    let row = SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore())
      .first { $0.config.host == saved.host }
    #expect(row?.config.hiddenSchemas == ["audit"])
    // An opened file without them (an older build wrote it), and a new form draft of the
    // connection (no form edits them), take the saved row's
    #expect(
      WorkspaceManager.keepingSavedAppearance(saved, defaults: defaults).hiddenSchemas == ["audit"])
    #expect(
      WorkspaceManager.keepingSavedHiddenSchemas(saved, defaults: defaults).hiddenSchemas
        == ["audit"])
    // A draft retargeted at an unsaved connection does not carry this one's hidden schemas
    var retargeted = manager.editingConnectionConfig
    retargeted.host = "other-\(UUID().uuidString).example"
    #expect(
      WorkspaceManager.keepingSavedHiddenSchemas(
        retargeted, current: manager.workspace.connectionConfig, defaults: defaults
      ).hiddenSchemas.isEmpty)
  }

  @Test("Hiding a schema on a connection without a saved row adds no row to Recents")
  func hiddenSchemasWithoutSavedRow() throws {
    let name = "SidebarSchemaFilterTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let manager = Self.workspace(Self.config())

    manager.setHiddenSchemas(["audit"], defaults: defaults, passwords: NoPasswordStore())

    #expect(manager.workspace.connectionConfig?.hiddenSchemas == ["audit"])
    #expect(SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore()).isEmpty)
    // The form's draft of this same connection keeps them on connect
    #expect(
      WorkspaceManager.keepingSavedHiddenSchemas(
        manager.editingConnectionConfig, current: manager.workspace.connectionConfig,
        defaults: defaults
      ).hiddenSchemas == ["audit"])
  }
}
