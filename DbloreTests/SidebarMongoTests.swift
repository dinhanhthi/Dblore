// SidebarMongoTests.swift
// The left sidebar section model: MongoDB shows only Collections and Views with Open, Copy Name
// and Insert find() menus (the name escaped), collections also Build Aggregation...; SQL
// connections keep their sections and menus (tables add Rename and Drop Table). Rename, Drop, Edit
// View and Duplicate only when the schema may change.

import Foundation
import Testing

@testable import Dblore

@Suite("Sidebar Mongo sections")
struct SidebarMongoTests {
  @Test("MongoDB shows only Collections and Views, flat, without the Security tab")
  func mongoSections() {
    let sections = SidebarSectionModel.sections(for: .mongosh)
    #expect(sections.map(\.title) == ["Collections", "Views"])
    #expect(sections.map(\.kind) == [.tables, .views])
    #expect(!SidebarSectionModel.groupsBySchema(.mongosh))
    #expect(!SidebarSectionModel.showsSecurityTab(.mongosh))
    #expect(SidebarSectionModel.structureMenuTitle(for: .mongodb) == nil)
  }

  @Test("a PostgreSQL connection keeps its sections, schema groups, Security tab and menus")
  func postgresKeepsSections() {
    let language = DatabaseType.postgresql.capabilities.queryLanguage
    #expect(
      SidebarSectionModel.sections(for: language).map(\.title) == [
        "Tables", "Views", "Functions", "Procedures", "Triggers",
      ])
    #expect(
      SidebarSectionModel.sections(for: language, supportsUserTypes: true).map(\.title).suffix(2)
        == ["Sequences", "Types"])
    #expect(SidebarSectionModel.groupsBySchema(language))
    #expect(SidebarSectionModel.showsSecurityTab(language))
    #expect(SidebarSectionModel.structureMenuTitle(for: .postgresql) != nil)
    for kind in [SidebarSectionModel.Kind.tables, .views, .functions, .procedures, .triggers] {
      #expect(SidebarSectionModel.rowActions(for: kind, name: "users", language: language).isEmpty)
    }
    // Tables add Rename and Drop Table when the schema may change (CreateTableModelTests)
  }

  @Test("collection and view rows offer Open, Copy Name, Insert find(); collections also Build")
  func mongoRowActions() {
    let language = DatabaseType.mongodb.capabilities.queryLanguage
    let find = SidebarSectionModel.RowAction.insert(#"db.getCollection("orders").find({})"#)
    let collection = SidebarSectionModel.rowActions(
      for: .tables, name: "orders", language: language)
    #expect(collection == [.open, .copyName, find, .buildAggregation, .exportCollection])
    #expect(
      collection.map(\.title) == [
        "Open", "Copy Name", "Insert find()", "Build Aggregation...", "Export Collection...",
      ])
    let view = SidebarSectionModel.rowActions(for: .views, name: "orders", language: language)
    #expect(view == [.open, .copyName, find, .exportCollection])
  }

  @Test("schema changes appear only with canChangeSchema, destructive items last")
  func mongoSchemaRowActions() {
    let find = SidebarSectionModel.RowAction.insert(#"db.getCollection("orders").find({})"#)
    let collection = SidebarSectionModel.rowActions(
      for: .tables, name: "orders", language: .mongosh, canChangeSchema: true)
    #expect(
      collection == [.open, .copyName, find, .buildAggregation, .exportCollection, .rename, .drop])
    #expect(collection.suffix(2).map(\.title) == ["Rename…", "Drop…"])
    let view = SidebarSectionModel.rowActions(
      for: .views, name: "orders", language: .mongosh, canChangeSchema: true)
    #expect(
      view == [.open, .copyName, find, .exportCollection, .editDefinition, .duplicate, .drop])
    #expect(view.suffix(3).map(\.title) == ["Edit View…", "Duplicate…", "Drop…"])
  }

  @Test("Import Documents shows only on collection rows when import is allowed, before Rename")
  func mongoImportRowAction() {
    let find = SidebarSectionModel.RowAction.insert(#"db.getCollection("orders").find({})"#)
    // Fail-closed default: disconnected or read-only connections pass false
    #expect(
      !SidebarSectionModel.rowActions(for: .tables, name: "orders", language: .mongosh)
        .contains(.importDocuments))
    let collection = SidebarSectionModel.rowActions(
      for: .tables, name: "orders", language: .mongosh, canChangeSchema: true,
      canImportDocuments: true)
    #expect(
      collection == [
        .open, .copyName, find, .buildAggregation, .exportCollection, .importDocuments, .rename,
        .drop,
      ])
    #expect(SidebarSectionModel.RowAction.importDocuments.title == "Import Documents...")
    let view = SidebarSectionModel.rowActions(
      for: .views, name: "orders", language: .mongosh, canImportDocuments: true)
    #expect(!view.contains(.importDocuments))
    #expect(
      SidebarSectionModel.rowActions(
        for: .tables, name: "users", language: .sql, canImportDocuments: true
      ).isEmpty)
  }

  @Test("import is allowed on a connected MongoDB workspace with a schema read, not read-only")
  @MainActor
  func canImportDocuments() {
    var config = ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    manager.schemaConnectionEpoch = 1
    #expect(!manager.canImportDocuments)  // disconnected
    manager.connectionState = .connected
    #expect(manager.canImportDocuments)
    manager.schemaConnectionEpoch = nil
    #expect(!manager.canImportDocuments)  // no schema read since the connect
    manager.schemaConnectionEpoch = 1
    config.protectionLevel = .schemaOnly
    manager.workspace.connectionConfig = config
    #expect(manager.canImportDocuments)
    config.protectionLevel = .readOnly
    manager.workspace.connectionConfig = config
    #expect(!manager.canImportDocuments)
    // The table import stays off for MongoDB
    #expect(!manager.canImportData)
  }

  @Test("the inserted find escapes backslash, quote and control characters, and parses back")
  func findSnippetEscapesName() throws {
    let name = "a\"b\\c\nd\te\u{1}f.g"
    let snippet = SidebarSectionModel.findSnippet(collection: name)
    #expect(snippet == #"db.getCollection("a\"b\\c\nd\te\u0001f.g").find({})"#)

    guard case .find(let collection, _, _, _, _, _, _) = try MongoshParser.parse(snippet) else {
      Issue.record("not a find: \(snippet)")
      return
    }
    #expect(collection == name)
  }
}
