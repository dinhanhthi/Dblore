// StructureChange.swift
// One edit the structure editor makes to a loaded `TableStructure`. `StructureDDLBuilder` turns a
// list of them into DDL. Every column, constraint and index name is a name as loaded (or as added
// by `addColumn`): renames run after every other change, and the table rename runs last. Type
// text and DEFAULT / CHECK expressions are typed by the user and written into the SQL as they
// are, after validation. A table comment is written as a string literal. Character set and
// collation names are never quoted: they must be one word found in the server's lists.

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
  /// The table's new name, in the same schema / database
  case renameTable(newName: String)
  /// Nil (or empty) removes the comment
  case setTableComment(String?)
  /// MySQL: the table's default character set and collation for new columns
  /// (`DEFAULT CHARSET=… COLLATE=…`). Names must be in the server's loaded lists.
  case setTableCharset(charset: String, collation: String)
  /// MySQL: converts every character column and the table default (`CONVERT TO CHARACTER SET`),
  /// rewriting each row
  case convertTableCharset(charset: String, collation: String)
  /// MySQL: the next AUTO_INCREMENT value (`AUTO_INCREMENT=n`)
  case setAutoIncrement(UInt64)

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
    /// One entry per column, or empty for all ASC with the default NULLS order. NULLS is
    /// written on PostgreSQL only.
    var sortOrder: [TableStructure.Index.KeyOrder] = []
  }
}
