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
