//
//  CommandPaletteItem.swift
//  Dblore
//
//  One palette row. Later UI renders it; later perform switches on the case.
//

import Foundation

/// A row copied into the palette. Values are the ids those actions need.
/// Nothing here is stored on disk.
nonisolated enum CommandPaletteItem: Equatable, Identifiable, Sendable {
  case table(schema: String, name: String)
  case view(schema: String, name: String)
  case function(schema: String, name: String, arguments: String)
  /// View Source: a function, procedure or trigger opened read-only
  case source(ObjectSourceRef)
  case tab(id: UUID, title: String)
  case favorite(id: UUID, name: String, sql: String)
  case action(id: String, title: String)
  case history(id: Int64, sql: String)

  var id: String {
    switch self {
    case .table(let schema, let name):
      "table:\(schema).\(name)"
    case .view(let schema, let name):
      "view:\(schema).\(name)"
    case .function(let schema, let name, let arguments):
      "function:\(schema).\(name)(\(arguments))"
    case .source(let ref):
      "source:\(ref.key)"
    case .tab(let id, _):
      "tab:\(id.uuidString)"
    case .favorite(let id, _, _):
      "favorite:\(id.uuidString)"
    case .action(let id, _):
      "action:\(id)"
    case .history(let id, _):
      "history:\(id)"
    }
  }

  /// Label for the row. History shows the recorded SQL.
  var title: String {
    switch self {
    case .table(_, let name), .view(_, let name):
      name
    case .function(_, let name, _):
      name
    case .source(let ref):
      ref.title
    case .tab(_, let title), .action(_, let title):
      title
    case .favorite(_, let name, _):
      name
    case .history(_, let sql):
      sql
    }
  }

  /// Haystacks for `SidebarEntityFilter.score`. A keyword may hit any one of them.
  var searchTexts: [String] {
    switch self {
    case .table(let schema, let name), .view(let schema, let name):
      return [name, schema, "\(schema).\(name)"]
    case .function(let schema, let name, let arguments):
      var texts = [name, schema, "\(schema).\(name)"]
      if !arguments.isEmpty {
        texts.append("\(name)(\(arguments))")
      }
      return texts
    case .source(let ref):
      var texts = [ref.name, ref.schema, "\(ref.schema).\(ref.name)", ref.title, "View Source"]
      if let table = ref.table { texts.append(table) }
      return texts
    case .tab(_, let title), .action(_, let title):
      return [title]
    case .favorite(_, let name, let sql):
      return [name, sql]
    case .history(_, let sql):
      return [sql]
    }
  }
}

/// The table, view and function rows of a loaded schema with their lowercased search keys, and
/// the tables' primary keys. Built off the main actor with the schema, so opening the palette
/// and each keystroke neither copy nor lowercase every name.
nonisolated struct CommandPaletteCatalog: Equatable, Sendable {
  /// Tables, views, then functions, in schema order (the first rows of a snapshot)
  let items: [CommandPaletteItem]
  /// `searchTexts` of each item, lowercased
  let searchKeys: [[String]]
  /// Primary key names in column order of the first table with each schema and name
  let primaryKeys: [CommandPaletteSnapshot.Relation: [String]]

  init(tables: [DatabaseTable], views: [DatabaseView], functions: [DatabaseFunction]) {
    var items: [CommandPaletteItem] = []
    items.reserveCapacity(tables.count + views.count + functions.count)
    var primaryKeys: [CommandPaletteSnapshot.Relation: [String]] = [:]
    primaryKeys.reserveCapacity(tables.count)
    for table in tables {
      items.append(.table(schema: table.schema, name: table.name))
      let relation = CommandPaletteSnapshot.Relation(schema: table.schema, name: table.name)
      if primaryKeys[relation] == nil {
        primaryKeys[relation] = table.columns.filter(\.isPrimaryKey).map(\.name)
      }
    }
    for view in views {
      items.append(.view(schema: view.schema, name: view.name))
    }
    for function in functions {
      items.append(
        .function(schema: function.schema, name: function.name, arguments: function.arguments))
    }
    self.items = items
    searchKeys = items.map { $0.searchTexts.map { $0.lowercased() } }
    self.primaryKeys = primaryKeys
  }
}
