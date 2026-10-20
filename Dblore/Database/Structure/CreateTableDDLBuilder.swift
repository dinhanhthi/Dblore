// CreateTableDDLBuilder.swift
// `CREATE TABLE` for a `CreateTableDraft` on PostgreSQL, MySQL and SQLite. The statements come
// back in run order, and the Create Table sheet previews exactly these strings.
//
// Columns render as ADD COLUMN does (`StructureDDLBuilder.columnDefinition`); primary key columns
// are always NOT NULL. Then, inside the parentheses: one table-level PRIMARY KEY (in column
// order), then the UNIQUE and FOREIGN KEY constraints in the order given. Identifiers go through
// `dialect.quoteIdentifier`; type text and DEFAULT expressions are the tested user-text exception
// (`StructureDDLBuilder.checkedText`). A blank comment adds nothing; otherwise it is a string
// literal: PostgreSQL runs a second statement, `COMMENT ON TABLE`; MySQL takes the table option
// `COMMENT = '...'`; SQLite has no table comments and refuses one. SQLite foreign keys name their
// target table bare (its grammar takes no schema there), so it must sit in the same database.
// DuckDB is view-only and refused.

import Foundation

/// What the Create Table sheet builds: a new table in `schema`
nonisolated struct CreateTableDraft: Sendable, Equatable {
  struct Column: Sendable, Equatable {
    var name: String
    /// User-typed type text (`varchar(20)`, `int unsigned`)
    var type: String
    var isNullable = true
    /// User-typed DEFAULT expression. Nil for none.
    var defaultExpression: String?
    var isPrimaryKey = false
  }

  /// Empty writes the table name alone
  var schema: String
  var name: String
  var columns: [Column]
  /// UNIQUE and FOREIGN KEY constraints; the primary key comes from `Column.isPrimaryKey`
  var constraints: [TableStructure.Constraint] = []
  /// Nil or blank for none
  var comment: String?
}

nonisolated enum CreateTableDDLBuilder {
  static func build(
    _ draft: CreateTableDraft, engine: StructureDDLBuilder.Engine
  ) throws -> [String] {
    let dialect: SQLDialect
    switch engine {
    case .postgresql, .mysql, .sqlite: dialect = engine.dialect
    case .duckdb:
      throw StructureDDLError.unsupported("DuckDB tables are view-only in Dblore.")
    }
    let comment = draft.comment.flatMap {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
    }
    try validate(draft, comment: comment, engine: engine, dialect: dialect)

    let quotedName = try dialect.quoteIdentifier(draft.name)
    let table =
      draft.schema.isEmpty
      ? quotedName : try dialect.quoteIdentifier(draft.schema) + "." + quotedName
    var lines = try draft.columns.map { column in
      try StructureDDLBuilder.columnDefinition(
        StructureChange.NewColumn(
          name: column.name, type: column.type,
          isNullable: column.isNullable && !column.isPrimaryKey,
          defaultExpression: column.defaultExpression),
        dialect: dialect)
    }
    let primaryKey = draft.columns.filter(\.isPrimaryKey).map(\.name)
    if !primaryKey.isEmpty {
      lines.append(
        "PRIMARY KEY (\(try StructureDDLBuilder.quotedList(primaryKey, dialect: dialect)))")
    }
    for constraint in draft.constraints {
      lines.append(
        try StructureDDLBuilder.constraintDefinition(
          constraint, dialect: dialect, renamed: [:],
          qualifiesReference: dialect != .sqlite))
    }
    let create =
      "CREATE TABLE \(table) (\n" + lines.map { "  " + $0 }.joined(separator: ",\n") + "\n)"
    guard let comment else { return [create] }
    switch engine {
    case .postgresql:
      return [create, "COMMENT ON TABLE \(table) IS \(dialect.literal(.string(comment)))"]
    case .mysql:
      return [create + " COMMENT = \(dialect.literal(.string(comment)))"]
    case .sqlite, .duckdb:
      return [create]
    }
  }

  // MARK: - Validation

  private static func validate(
    _ draft: CreateTableDraft, comment: String?, engine: StructureDDLBuilder.Engine,
    dialect: SQLDialect
  ) throws {
    try checkedName(draft.name, "table")
    if draft.schema.contains("\0") {
      throw StructureDDLError.invalidText("A schema name cannot contain a NUL character.")
    }
    guard !draft.columns.isEmpty else {
      throw StructureDDLError.invalidText("A table needs at least one column.")
    }
    var seen = Set<String>()
    for column in draft.columns {
      try checkedName(column.name, "column")
      try StructureDDLBuilder.checkedText(column.type, "type", dialect: dialect)
      if let expression = column.defaultExpression {
        try StructureDDLBuilder.checkedText(expression, "default", dialect: dialect)
      }
      // PostgreSQL quoted names are case-sensitive; MySQL and SQLite column names are not
      let key = dialect == .postgresql ? column.name : SQLTokenizer.asciiLowercased(column.name)
      guard seen.insert(key).inserted else {
        throw StructureDDLError.invalidText("The column \"\(column.name)\" is listed twice.")
      }
    }
    let names = Set(draft.columns.map(\.name))
    for constraint in draft.constraints {
      if let name = constraint.name { try checkedName(name, "constraint") }
      guard !constraint.columns.isEmpty else {
        throw StructureDDLError.invalidText("A constraint needs at least one column.")
      }
      if let unknown = constraint.columns.first(where: { !names.contains($0) }) {
        throw StructureDDLError.unknownColumn(unknown)
      }
      switch constraint.kind {
      case .unique:
        break
      case .foreignKey(let reference):
        try checkedName(reference.table, "referenced table")
        guard reference.columns.count == constraint.columns.count else {
          throw StructureDDLError.invalidText(
            "A foreign key needs as many referenced columns as columns.")
        }
        for column in reference.columns { try checkedName(column, "referenced column") }
        if dialect == .sqlite, !reference.schema.isEmpty, reference.schema != draft.schema {
          throw StructureDDLError.unsupported(
            "SQLite foreign keys must reference a table in the same database.")
        }
      case .primaryKey, .check:
        throw StructureDDLError.unsupported(
          "Only unique and foreign key constraints can be added to a new table.")
      }
    }
    if let text = draft.comment, text.contains("\0") {
      throw StructureDDLError.invalidText("A comment cannot contain a NUL character.")
    }
    if comment != nil, case .sqlite = engine {
      throw StructureDDLError.unsupported("SQLite tables have no comments.")
    }
  }

  /// Non-empty and without NUL (the identifier quoting refuses NUL too, with a vaguer error)
  private static func checkedName(_ name: String, _ what: String) throws {
    guard !name.isEmpty else {
      throw StructureDDLError.invalidText("A \(what) name cannot be empty.")
    }
    guard !name.contains("\0") else {
      throw StructureDDLError.invalidText("A \(what) name cannot contain a NUL character.")
    }
  }
}
