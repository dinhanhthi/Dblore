// StructureChange.swift
// One edit the structure editor makes to a loaded `TableStructure`. `StructureDDLBuilder` turns a
// list of them into DDL. Every column, constraint and index name is a name as loaded (or as added
// by `addColumn`): renames run after every other change. Type text and DEFAULT / CHECK
// expressions are typed by the user and written into the SQL as they are, after validation.

import Foundation

nonisolated enum StructureChange: Sendable, Equatable {
  case addColumn(NewColumn)
  case alterColumnType(column: String, type: String)
  case setDefault(column: String, expression: String)
  case dropDefault(column: String)
  case setNotNull(column: String)
  case dropNotNull(column: String)
  case renameColumn(column: String, newName: String)
  case dropColumn(column: String)
  /// Unnamed when `name` is nil (the engine picks one)
  case addConstraint(TableStructure.Constraint)
  /// `kind` picks the MySQL syntax (DROP PRIMARY KEY / INDEX / FOREIGN KEY / CHECK)
  case dropConstraint(name: String, kind: ConstraintKind)
  case createIndex(NewIndex)
  case dropIndex(name: String)

  struct NewColumn: Sendable, Equatable {
    var name: String
    /// User-typed type text (`varchar(20)`, `int unsigned`)
    var type: String
    var isNullable: Bool
    /// User-typed DEFAULT expression. Nil for none.
    var defaultExpression: String?
  }

  enum ConstraintKind: Sendable, Equatable {
    case primaryKey
    case unique
    case foreignKey
    case check
  }

  struct NewIndex: Sendable, Equatable {
    var name: String
    /// Key columns in order
    var columns: [String]
    var isUnique: Bool
    /// `btree`, `hash`, `gin`, ... (one word). Nil for the engine default.
    var method: String?
  }
}
