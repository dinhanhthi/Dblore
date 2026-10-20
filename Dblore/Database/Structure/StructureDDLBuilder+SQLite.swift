// StructureDDLBuilder+SQLite.swift
// SQLite: only the ALTERs it runs directly, one statement each, never a table rebuild. Order as
// PostgreSQL: DROP INDEX, DROP COLUMN, ADD COLUMN, CREATE INDEX, RENAME COLUMN, then the table
// RENAME TO (a bare name: the table stays in its schema).
// - ADD COLUMN: no PRIMARY KEY, UNIQUE or STORED generated column; NOT NULL needs a non-NULL
//   default; the default must be constant (no CURRENT_TIME / DATE / TIMESTAMP, no parentheses).
// - RENAME COLUMN needs 3.25.0, DROP COLUMN 3.35.0.
// - DROP COLUMN is refused for primary key, unique, indexed, foreign key (either side, within
//   this table) and generated columns. A column used in a CHECK, an expression index, another
//   column's generation expression or another table's foreign key is not visible here: SQLite
//   itself rejects the statement.
// - Everything else (type, default, nullability, constraints, table comments) throws.

import Foundation

nonisolated extension StructureDDLBuilder {
  static func sqliteStatements(
    _ changes: [StructureChange], structure: TableStructure, libraryVersion: Int
  ) throws -> [String] {
    let dialect = SQLDialect.sqlite
    let q = dialect.quoteIdentifier
    let table = try tableName(structure, dialect: dialect)
    var dropIndexes: [String] = []
    var dropColumns: [String] = []
    var addColumns: [String] = []
    var createIndexes: [String] = []
    var renames: [String] = []
    var tableRename: String?
    for change in changes {
      switch change {
      case .addColumn(let column):
        try checkSQLiteAddColumn(column)
        addColumns.append(
          "ALTER TABLE \(table) ADD COLUMN " + (try columnDefinition(column, dialect: dialect)))
      case .renameColumn(let column, let newName):
        try requireSQLite(3_025_000, libraryVersion, for: "Renaming a column")
        renames.append("ALTER TABLE \(table) RENAME COLUMN \(try q(column)) TO \(try q(newName))")
      case .dropColumn(let column):
        try requireSQLite(3_035_000, libraryVersion, for: "Dropping a column")
        try checkSQLiteDropColumn(column, in: structure)
        dropColumns.append("ALTER TABLE \(table) DROP COLUMN \(try q(column))")
      case .createIndex(let index):
        guard index.method == nil else {
          throw StructureDDLError.unsupported("SQLite indexes have no method.")
        }
        createIndexes.append(
          "CREATE \(index.isUnique ? "UNIQUE " : "")INDEX "
            + "\(try q(structure.schema)).\(try q(index.name)) ON \(try q(structure.name)) "
            + "(\(try quotedList(index.columns, dialect: dialect)))")
      case .dropIndex(let name):
        dropIndexes.append("DROP INDEX \(try q(structure.schema)).\(try q(name))")
      case .renameTable(let newName):
        tableRename = "ALTER TABLE \(table) RENAME TO \(try q(newName))"
      case .setTableComment:
        throw StructureDDLError.unsupported("SQLite tables have no comments.")
      case .alterColumnType, .setDefault, .dropDefault, .setNotNull, .dropNotNull,
        .addConstraint, .dropConstraint:
        throw StructureDDLError.unsupported(
          "This change is not supported on SQLite: it needs a table rebuild.")
      }
    }
    return dropIndexes + dropColumns + addColumns + createIndexes + renames
      + [tableRename].compactMap { $0 }
  }

  private static func requireSQLite(_ minimum: Int, _ version: Int, for what: String) throws {
    guard version < minimum else { return }
    func text(_ number: Int) -> String {
      "\(number / 1_000_000).\(number / 1_000 % 1_000).\(number % 1_000)"
    }
    throw StructureDDLError.unsupported(
      "\(what) needs SQLite \(text(minimum)) or later (this is \(text(version))).")
  }

  private static func checkSQLiteAddColumn(_ column: StructureChange.NewColumn) throws {
    let tokenizer = SQLTokenizer(dialect: .sqlite)
    let typeWords = Set(tokenizer.tokens(column.type).filter { $0.kind == .word }.map(\.text))
    if !typeWords.isDisjoint(with: ["PRIMARY", "UNIQUE", "STORED"]) {
      throw StructureDDLError.unsupported(
        "SQLite cannot add a PRIMARY KEY, UNIQUE or STORED generated column.")
    }
    let defaultTokens = column.defaultExpression.map { tokenizer.tokens($0) } ?? []
    if defaultTokens.contains(where: {
      ($0.kind == .word && ["CURRENT_TIME", "CURRENT_DATE", "CURRENT_TIMESTAMP"].contains($0.text))
        || ($0.kind == .symbol && $0.text == "(")
    }) {
      throw StructureDDLError.unsupported("SQLite can only add a column with a constant default.")
    }
    let isNullDefault =
      defaultTokens.isEmpty
      || (defaultTokens.count == 1 && defaultTokens[0].kind == .word
        && defaultTokens[0].text == "NULL")
    if !column.isNullable && isNullDefault {
      throw StructureDDLError.unsupported(
        "SQLite can only add a NOT NULL column with a non-NULL default.")
    }
  }

  private static func checkSQLiteDropColumn(_ name: String, in structure: TableStructure) throws {
    let column = try loadedColumn(name, in: structure)
    let inConstraint = structure.constraints.contains { constraint in
      if constraint.columns.contains(name) { return true }
      if case .foreignKey(let reference) = constraint.kind {
        return reference.table == structure.name && reference.columns.contains(name)
      }
      return false
    }
    let indexed = structure.indexes.contains { $0.keys.contains(.column(name)) }
    guard !inConstraint, !indexed, column.generated == nil else {
      throw StructureDDLError.unsupported(
        "SQLite cannot drop \"\(name)\": it is generated, indexed, or part of a key or "
          + "constraint.")
    }
  }
}
