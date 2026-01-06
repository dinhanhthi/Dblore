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
  var rowCount: Int?

  nonisolated init(
    schema: String,
    name: String,
    columns: [DatabaseColumn] = [],
    isExpanded: Bool = false,
    rowCount: Int? = nil
  ) {
    self.schema = schema
    self.name = name
    self.columns = columns
    self.isExpanded = isExpanded
    self.rowCount = rowCount
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

  /// Returns the appropriate SF Symbol icon name for this column's data type
  var typeIcon: String {
    if isPrimaryKey {
      return "key"
    }

    let lowercasedType = type.lowercased()

    // Numeric types
    if lowercasedType.contains("int") || lowercasedType.contains("serial")
      || lowercasedType.contains("bigserial") || lowercasedType.contains("smallserial")
    {
      return "textformat.123"
    }

    if lowercasedType.contains("numeric") || lowercasedType.contains("decimal")
      || lowercasedType.contains("float") || lowercasedType.contains("double")
      || lowercasedType.contains("real") || lowercasedType.contains("money")
    {
      return "number"
    }

    // Text types
    if lowercasedType.contains("char") || lowercasedType.contains("text")
      || lowercasedType.contains("varchar") || lowercasedType.contains("string")
    {
      return "textformat"
    }

    // Boolean
    if lowercasedType.contains("bool") {
      return "checklist"
    }

    // Date/Time types
    if lowercasedType.contains("date") || lowercasedType.contains("time")
      || lowercasedType.contains("timestamp")
    {
      return "calendar"
    }

    // JSON types
    if lowercasedType.contains("json") {
      return "curlybraces"
    }

    // Binary types
    if lowercasedType.contains("byte") || lowercasedType.contains("blob")
      || lowercasedType.contains("binary")
    {
      return "01.square"
    }

    // UUID
    if lowercasedType.contains("uuid") {
      return "number.square"
    }

    // Array types
    if lowercasedType.contains("array") || lowercasedType.contains("[]") {
      return "list.bullet"
    }

    // Default fallback
    return "questionmark.circle"
  }
}
