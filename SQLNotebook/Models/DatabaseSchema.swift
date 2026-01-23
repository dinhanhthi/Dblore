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

// MARK: - Database Views

/// Represents a database view
struct DatabaseView: Identifiable, Sendable {
  let id = UUID()
  let schema: String
  let name: String
  var columns: [DatabaseColumn]
  var isExpanded: Bool
  var definition: String?  // View definition/SQL

  nonisolated init(
    schema: String,
    name: String,
    columns: [DatabaseColumn] = [],
    isExpanded: Bool = false,
    definition: String? = nil
  ) {
    self.schema = schema
    self.name = name
    self.columns = columns
    self.isExpanded = isExpanded
    self.definition = definition
  }

  /// Full qualified name: schema.view
  var qualifiedName: String {
    "\(schema).\(name)"
  }
}

// MARK: - Database Functions

/// Represents a database function
struct DatabaseFunction: Identifiable, Sendable {
  let id = UUID()
  let schema: String
  let name: String
  let returnType: String
  let arguments: String
  var definition: String?  // Function definition/SQL
  var isExpanded: Bool

  nonisolated init(
    schema: String,
    name: String,
    returnType: String,
    arguments: String = "",
    definition: String? = nil,
    isExpanded: Bool = false
  ) {
    self.schema = schema
    self.name = name
    self.returnType = returnType
    self.arguments = arguments
    self.definition = definition
    self.isExpanded = isExpanded
  }

  /// Full qualified name: schema.function
  var qualifiedName: String {
    "\(schema).\(name)"
  }

  /// Display signature: function(args) -> returnType
  var signature: String {
    "\(name)(\(arguments)) → \(returnType)"
  }
}

// MARK: - Database Procedures

/// Represents a database procedure (stored procedure)
struct DatabaseProcedure: Identifiable, Sendable {
  let id = UUID()
  let schema: String
  let name: String
  let arguments: String
  var definition: String?  // Procedure definition/SQL
  var isExpanded: Bool

  nonisolated init(
    schema: String,
    name: String,
    arguments: String = "",
    definition: String? = nil,
    isExpanded: Bool = false
  ) {
    self.schema = schema
    self.name = name
    self.arguments = arguments
    self.definition = definition
    self.isExpanded = isExpanded
  }

  /// Full qualified name: schema.procedure
  var qualifiedName: String {
    "\(schema).\(name)"
  }

  /// Display signature: procedure(args)
  var signature: String {
    "\(name)(\(arguments))"
  }
}

// MARK: - Database Users

/// Represents a database user/role
struct DatabaseUser: Identifiable, Sendable {
  let id = UUID()
  let name: String
  let canLogin: Bool
  let isSuperuser: Bool
  let canCreateDB: Bool
  let canCreateRole: Bool
  let connectionLimit: Int?
  var isExpanded: Bool

  nonisolated init(
    name: String,
    canLogin: Bool = true,
    isSuperuser: Bool = false,
    canCreateDB: Bool = false,
    canCreateRole: Bool = false,
    connectionLimit: Int? = nil,
    isExpanded: Bool = false
  ) {
    self.name = name
    self.canLogin = canLogin
    self.isSuperuser = isSuperuser
    self.canCreateDB = canCreateDB
    self.canCreateRole = canCreateRole
    self.connectionLimit = connectionLimit
    self.isExpanded = isExpanded
  }

  /// Display attributes for the user
  var attributes: [String] {
    var attrs: [String] = []
    if isSuperuser { attrs.append("Superuser") }
    if canCreateDB { attrs.append("Create DB") }
    if canCreateRole { attrs.append("Create Role") }
    if !canLogin { attrs.append("No Login") }
    if let limit = connectionLimit, limit >= 0 {
      attrs.append("Limit: \(limit)")
    }
    return attrs
  }
}

// MARK: - Database Roles

/// Represents a database role
struct DatabaseRole: Identifiable, Sendable {
  let id = UUID()
  let name: String
  let canLogin: Bool
  let isSuperuser: Bool
  let canCreateDB: Bool
  let canCreateRole: Bool
  var members: [String]  // List of role members
  var isExpanded: Bool

  nonisolated init(
    name: String,
    canLogin: Bool = false,
    isSuperuser: Bool = false,
    canCreateDB: Bool = false,
    canCreateRole: Bool = false,
    members: [String] = [],
    isExpanded: Bool = false
  ) {
    self.name = name
    self.canLogin = canLogin
    self.isSuperuser = isSuperuser
    self.canCreateDB = canCreateDB
    self.canCreateRole = canCreateRole
    self.members = members
    self.isExpanded = isExpanded
  }

  /// Display attributes for the role
  var attributes: [String] {
    var attrs: [String] = []
    if isSuperuser { attrs.append("Superuser") }
    if canCreateDB { attrs.append("Create DB") }
    if canCreateRole { attrs.append("Create Role") }
    if canLogin { attrs.append("Can Login") }
    return attrs
  }
}
