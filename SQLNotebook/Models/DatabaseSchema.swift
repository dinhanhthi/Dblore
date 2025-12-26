//
//  DatabaseSchema.swift
//  SQLNotebook
//

import Foundation

/// Represents a database table with its columns
struct DatabaseTable: Identifiable, Sendable {
  let id = UUID()
  let schema: String
  let name: String
  var columns: [DatabaseColumn]
  var isExpanded: Bool

  nonisolated init(
    schema: String,
    name: String,
    columns: [DatabaseColumn] = [],
    isExpanded: Bool = false
  ) {
    self.schema = schema
    self.name = name
    self.columns = columns
    self.isExpanded = isExpanded
  }

  /// Full qualified name: schema.table
  var qualifiedName: String {
    "\(schema).\(name)"
  }
}

/// Represents a column in a database table
struct DatabaseColumn: Identifiable, Sendable {
  let id = UUID()
  let name: String
  let type: String
  let isNullable: Bool
  let isPrimaryKey: Bool

  nonisolated init(
    name: String,
    type: String,
    isNullable: Bool = true,
    isPrimaryKey: Bool = false
  ) {
    self.name = name
    self.type = type
    self.isNullable = isNullable
    self.isPrimaryKey = isPrimaryKey
  }
}
