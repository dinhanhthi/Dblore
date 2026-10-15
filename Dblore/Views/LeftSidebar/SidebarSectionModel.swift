//
//  SidebarSectionModel.swift
//  Dblore
//
//  Which Public tab sections the left sidebar shows for a query language, and the context
//  menu actions of their rows. SQL connections keep their sections and menus; MongoDB shows
//  only Collections and Views, whose rows offer Open, Copy Name and Insert find(); collections
//  also offer Build Aggregation...
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

  /// A row menu item added by this model. SQL rows get none (their menus stay as they are).
  enum RowAction: Equatable, Sendable {
    /// Opens the relation in the data viewer, as a click on the row does.
    case open
    case copyName
    /// Inserts `text` at the cursor of the active cell.
    case insert(String)
    /// Opens the aggregation builder on the collection.
    case buildAggregation

    var title: String {
      switch self {
      case .open: "Open"
      case .copyName: "Copy Name"
      case .insert: "Insert find()"
      case .buildAggregation: "Build Aggregation..."
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

  /// Menu items of the table, collection or view row named `name`.
  static func rowActions(for kind: Kind, name: String, language: QueryLanguage) -> [RowAction] {
    guard language == .mongosh, kind == .tables || kind == .views else { return [] }
    let actions: [RowAction] = [.open, .copyName, .insert(findSnippet(collection: name))]
    return kind == .tables ? actions + [.buildAggregation] : actions
  }

  /// `db.getCollection("<name>").find({})`, the name escaped as a double-quoted string.
  static func findSnippet(collection name: String) -> String {
    "db.getCollection(\(MongoRelaxedJSON.render(.string(name), as: .mongosh))).find({})"
  }
}
