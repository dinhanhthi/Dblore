//
//  SidebarSectionModel.swift
//  Dblore
//
//  Which Public tab sections the left sidebar shows for a query language, and the context
//  menu actions of their rows. SQL connections keep their sections and menus; MongoDB shows
//  only Collections and Views, whose rows offer Open, Copy Name and Insert find(); collections
//  also offer Build Aggregation..., then both Export Collection... (a read, so also on read-only
//  connections). Collections add Import Documents... when the connection takes writes. When the
//  schema may change, collections add Rename and Drop, views Edit View, Duplicate and Drop.
//  PostgreSQL, MySQL and SQLite tables add Rename and Drop Table (the structure editor's flows)
//  and the Tables header New Table... when the schema may change; DuckDB stays view-only.
//

import Foundation

nonisolated enum SidebarSectionModel {
  typealias QueryLanguage = DatabaseCapabilities.QueryLanguage

  /// A Public tab section. `tables` holds MongoDB collections.
  enum Kind: Hashable, Sendable {
    case tables, views, functions, procedures, triggers
  }

  struct Section: Equatable, Sendable {
    let kind: Kind
    let title: String
    let icon: String
  }

  /// A row menu item added by this model. SQL tables get only Rename and Drop.
  enum RowAction: Equatable, Sendable {
    /// Opens the relation in the data viewer, as a click on the row does.
    case open
    case copyName
    /// Inserts `text` at the cursor of the active cell.
    case insert(String)
    /// Opens the aggregation builder on the collection.
    case buildAggregation
    /// Exports the collection or view as Extended JSON or CSV. A read: never schema-changing.
    case exportCollection
    /// Imports a JSON, NDJSON or CSV file into the collection. Offered only when import is allowed.
    case importDocuments
    /// Schema changes, engine-neutral. Offered only when the schema may change.
    case rename
    case drop
    case duplicate
    /// Edits a view's definition.
    case editDefinition

    var title: String {
      switch self {
      case .open: "Open"
      case .copyName: "Copy Name"
      case .insert: "Insert find()"
      case .buildAggregation: "Build Aggregation..."
      case .exportCollection: "Export Collection..."
      case .importDocuments: "Import Documents..."
      case .rename: "Rename…"
      case .drop: "Drop…"
      case .duplicate: "Duplicate…"
      case .editDefinition: "Edit View…"
      }
    }

    /// `title`, except Drop on an SQL table row, which names what it drops
    func title(for language: QueryLanguage) -> String {
      switch (self, language) {
      case (.drop, .sql): "Drop Table…"
      default: title
      }
    }
  }

  /// Public tab sections in display order.
  static func sections(for language: QueryLanguage) -> [Section] {
    switch language {
    case .sql:
      [
        Section(kind: .tables, title: "Tables", icon: "tablecells"),
        Section(kind: .views, title: "Views", icon: "eye"),
        Section(kind: .functions, title: "Functions", icon: "function"),
        Section(kind: .procedures, title: "Procedures", icon: "gearshape.2"),
        Section(kind: .triggers, title: "Triggers", icon: ObjectSourceRef.Kind.trigger.iconName),
      ]
    case .mongosh:
      [
        Section(kind: .tables, title: "Collections", icon: "tablecells"),
        Section(kind: .views, title: "Views", icon: "eye"),
      ]
    }
  }

  /// Two or more schemas get one group each. A MongoDB connection lists one database, flat.
  static func groupsBySchema(_ language: QueryLanguage) -> Bool {
    language == .sql
  }

  /// The Security tab (Users and Roles). MongoDB has none.
  static func showsSecurityTab(_ language: QueryLanguage) -> Bool {
    language == .sql
  }

  /// The table row's structure menu item. Nil (MongoDB) hides it; DuckDB is view-only by type.
  static func structureMenuTitle(for type: DatabaseType) -> String? {
    guard type.capabilities.supportsStructure else { return nil }
    return type == .duckdb ? "View Structure..." : "Edit Structure..."
  }

  /// The engines whose tables Dblore creates, renames and drops (DuckDB is view-only, MongoDB
  /// has collections)
  static func supportsTableChanges(_ type: DatabaseType) -> Bool {
    switch type {
    case .postgresql, .mysql, .sqlite: true
    case .duckdb, .mongodb: false
    }
  }

  /// The section header's create item. Nil shows none.
  static func createActionTitle(for kind: Kind, databaseType: DatabaseType) -> String? {
    switch (databaseType, kind) {
    case (.mongodb, .tables): "New Collection…"
    case (.mongodb, .views): "New View…"
    case (.postgresql, .tables), (.mysql, .tables), (.sqlite, .tables): "New Table…"
    default: nil
    }
  }

  /// Menu items of the table, collection or view row named `name`. Without `canChangeSchema`
  /// (the default, fail-closed) no item changes the schema, without `canImportDocuments` (the
  /// default) no collection offers an import; destructive items come last. SQL tables get Rename
  /// and Drop only; the caller passes `canChangeSchema` false where `supportsTableChanges` is.
  static func rowActions(
    for kind: Kind, name: String, language: QueryLanguage, canChangeSchema: Bool = false,
    canImportDocuments: Bool = false
  ) -> [RowAction] {
    if language == .sql {
      return kind == .tables && canChangeSchema ? [.rename, .drop] : []
    }
    guard kind == .tables || kind == .views else { return [] }
    let actions: [RowAction] = [.open, .copyName, .insert(findSnippet(collection: name))]
    if kind == .tables {
      return actions + [.buildAggregation, .exportCollection]
        + (canImportDocuments ? [.importDocuments] : [])
        + (canChangeSchema ? [.rename, .drop] : [])
    }
    return actions + [.exportCollection]
      + (canChangeSchema ? [.editDefinition, .duplicate, .drop] : [])
  }

  /// `db.getCollection("<name>").find({})`, the name escaped as a double-quoted string.
  static func findSnippet(collection name: String) -> String {
    "db.getCollection(\(MongoRelaxedJSON.render(.string(name), as: .mongosh))).find({})"
  }
}
