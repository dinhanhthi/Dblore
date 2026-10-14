// StructureDDLBuilder.swift
// DDL for a list of `StructureChange` against a loaded `TableStructure`. The statements come back
// in run order, and the structure editor previews exactly these strings.
//
// Identifiers always go through `dialect.quoteIdentifier`; the table is always written
// `schema.table`. Type text, DEFAULT and CHECK expressions are the one exception to "values are
// always binds" (DDL takes no binds): they are written as typed, after `checkedText` lexes them
// with the dialect tokenizer and rejects comments, `;`, a top-level `,` (another ALTER action),
// unbalanced parentheses, unterminated quotes and control characters other than tab, newline
// and carriage return.
//
// Names in changes are loaded names; renames run last. PostgreSQL order:
// 1. DROP INDEX, one statement each
// 2. one ALTER TABLE: DROP CONSTRAINT, DROP COLUMN, ADD COLUMN, ALTER COLUMN (TYPE, SET/DROP
//    DEFAULT, SET/DROP NOT NULL), ADD CONSTRAINT, each group in the order given
// 3. CREATE INDEX, one statement each (no CONCURRENTLY: it cannot run in a transaction)
// 4. RENAME COLUMN, one ALTER TABLE each (PostgreSQL does not combine RENAME with other actions)
// MySQL and SQLite: see their extensions. DuckDB is view-only: any change throws.

import Foundation

nonisolated enum StructureDDLError: Error, Equatable, LocalizedError {
  /// Type text or an expression that could end or extend the statement
  case invalidText(String)
  /// The engine (or this server version) cannot make the change
  case unsupported(String)
  /// A change names a column the loaded table does not have
  case unknownColumn(String)

  var errorDescription: String? {
    switch self {
    case .invalidText(let message), .unsupported(let message): message
    case .unknownColumn(let name): "The table has no column \"\(name)\"."
    }
  }
}

nonisolated enum StructureDDLBuilder {
  /// The engine and the version facts the DDL depends on
  enum Engine: Sendable, Equatable {
    case postgresql
    case mysql(MySQLServerInfo)
    /// `sqlite3_libversion_number()` (`SQLiteLibraryVersion.current`)
    case sqlite(libraryVersion: Int)
    case duckdb

    var dialect: SQLDialect {
      switch self {
      case .postgresql: .postgresql
      case .mysql: .mysql
      case .sqlite: .sqlite
      case .duckdb: .duckdb
      }
    }
  }

  static func build(
    changes: [StructureChange], structure: TableStructure, engine: Engine
  ) throws -> [String] {
    guard !changes.isEmpty else { return [] }
    if engine == .duckdb {
      throw StructureDDLError.unsupported("DuckDB tables are view-only in the structure editor.")
    }
    try validate(changes, structure: structure, dialect: engine.dialect)
    switch engine {
    case .postgresql: return try postgresStatements(changes, structure: structure)
    case .mysql(let server):
      return try mysqlStatements(changes, structure: structure, server: server)
    case .sqlite(let version):
      return try sqliteStatements(changes, structure: structure, libraryVersion: version)
    case .duckdb: return []
    }
  }

  // MARK: - PostgreSQL

  private static func postgresStatements(
    _ changes: [StructureChange], structure: TableStructure
  ) throws -> [String] {
    let dialect = SQLDialect.postgresql
    let q = dialect.quoteIdentifier
    let table = try tableName(structure, dialect: dialect)
    var dropIndexes: [String] = []
    var dropConstraints: [String] = []
    var dropColumns: [String] = []
    var addColumns: [String] = []
    var alterColumns: [String] = []
    var addConstraints: [String] = []
    var createIndexes: [String] = []
    var renames: [String] = []
    for change in changes {
      switch change {
      case .addColumn(let column):
        addColumns.append(
          "ADD COLUMN \(try q(column.name)) \(column.type)"
            + (column.isNullable ? "" : " NOT NULL")
            + (column.defaultExpression.map { " DEFAULT \($0)" } ?? ""))
      case .alterColumnType(let column, let type):
        alterColumns.append("ALTER COLUMN \(try q(column)) TYPE \(type)")
      case .setDefault(let column, let expression):
        alterColumns.append("ALTER COLUMN \(try q(column)) SET DEFAULT \(expression)")
      case .dropDefault(let column):
        alterColumns.append("ALTER COLUMN \(try q(column)) DROP DEFAULT")
      case .setNotNull(let column):
        alterColumns.append("ALTER COLUMN \(try q(column)) SET NOT NULL")
      case .dropNotNull(let column):
        alterColumns.append("ALTER COLUMN \(try q(column)) DROP NOT NULL")
      case .renameColumn(let column, let newName):
        renames.append("ALTER TABLE \(table) RENAME COLUMN \(try q(column)) TO \(try q(newName))")
      case .dropColumn(let column):
        dropColumns.append("DROP COLUMN \(try q(column))")
      case .addConstraint(let constraint):
        addConstraints.append(
          "ADD " + (try constraintDefinition(constraint, dialect: dialect, renamed: [:])))
      case .dropConstraint(let name, _):
        dropConstraints.append("DROP CONSTRAINT \(try q(name))")
      case .createIndex(let index):
        createIndexes.append(
          "CREATE \(index.isUnique ? "UNIQUE " : "")INDEX \(try q(index.name)) ON \(table)"
            + (index.method.map { " USING \($0)" } ?? "")
            + " (\(try quotedList(index.columns, dialect: dialect)))")
      case .dropIndex(let name):
        dropIndexes.append("DROP INDEX \(try q(structure.schema)).\(try q(name))")
      }
    }
    let actions = dropConstraints + dropColumns + addColumns + alterColumns + addConstraints
    let alter = actions.isEmpty ? [] : ["ALTER TABLE \(table) " + actions.joined(separator: ", ")]
    return dropIndexes + alter + createIndexes + renames
  }

  // MARK: - Shared helpers

  /// `schema.table`, or just the table when the schema is empty
  static func tableName(_ structure: TableStructure, dialect: SQLDialect) throws -> String {
    let name = try dialect.quoteIdentifier(structure.name)
    guard !structure.schema.isEmpty else { return name }
    return try dialect.quoteIdentifier(structure.schema) + "." + name
  }

  /// `"a", "b"`, each name replaced by its entry in `renamed` when present
  static func quotedList(
    _ names: [String], dialect: SQLDialect, renamed: [String: String] = [:]
  ) throws -> String {
    try names.map { try dialect.quoteIdentifier(renamed[$0] ?? $0) }.joined(separator: ", ")
  }

  /// `[CONSTRAINT name] PRIMARY KEY (...) | UNIQUE (...) | FOREIGN KEY ... | CHECK (expr)`.
  /// Column names go through `renamed` (MySQL renames in the same ALTER TABLE).
  static func constraintDefinition(
    _ constraint: TableStructure.Constraint, dialect: SQLDialect, renamed: [String: String]
  ) throws -> String {
    let name = try constraint.name.map { "CONSTRAINT \(try dialect.quoteIdentifier($0)) " } ?? ""
    let columns = try quotedList(constraint.columns, dialect: dialect, renamed: renamed)
    switch constraint.kind {
    case .primaryKey:
      return name + "PRIMARY KEY (\(columns))"
    case .unique:
      return name + "UNIQUE (\(columns))"
    case .check(let expression):
      return name + "CHECK (\(expression))"
    case .foreignKey(let reference):
      let target =
        try dialect.quoteIdentifier(reference.schema) + "."
        + dialect.quoteIdentifier(reference.table)
      return name + "FOREIGN KEY (\(columns)) REFERENCES \(target) "
        + "(\(try quotedList(reference.columns, dialect: dialect)))"
        + action("ON UPDATE", reference.onUpdate) + action("ON DELETE", reference.onDelete)
    }
  }

  private static func action(_ clause: String, _ action: ForeignKeyAction) -> String {
    switch action {
    case .noAction: ""
    case .restrict: " \(clause) RESTRICT"
    case .cascade: " \(clause) CASCADE"
    case .setNull: " \(clause) SET NULL"
    case .setDefault: " \(clause) SET DEFAULT"
    }
  }

  static func loadedColumn(
    _ name: String, in structure: TableStructure
  ) throws
    -> TableStructure.Column
  {
    guard let column = structure.columns.first(where: { $0.name == name }) else {
      throw StructureDDLError.unknownColumn(name)
    }
    return column
  }

  // MARK: - Validation

  private static func validate(
    _ changes: [StructureChange], structure: TableStructure, dialect: SQLDialect
  ) throws {
    for change in changes {
      switch change {
      case .addColumn(let column):
        try checkedName(column.name)
        try checkedText(column.type, "type", dialect: dialect)
        if let expression = column.defaultExpression {
          try checkedText(expression, "default", dialect: dialect)
        }
      case .alterColumnType(let name, let type):
        _ = try loadedColumn(name, in: structure)
        try checkedText(type, "type", dialect: dialect)
      case .setDefault(let name, let expression):
        let column = try loadedColumn(name, in: structure)
        try checkedText(expression, "default", dialect: dialect)
        if column.identity != nil || column.generated != nil {
          throw StructureDDLError.unsupported(
            "\"\(name)\" is an identity or generated column: it cannot have a default.")
        }
      case .dropDefault(let name), .setNotNull(let name), .dropNotNull(let name),
        .dropColumn(let name):
        _ = try loadedColumn(name, in: structure)
      case .renameColumn(let name, let newName):
        _ = try loadedColumn(name, in: structure)
        try checkedName(newName)
      case .addConstraint(let constraint):
        if let name = constraint.name { try checkedName(name) }
        if case .check(let expression) = constraint.kind {
          try checkedText(expression, "check", dialect: dialect)
        } else if constraint.columns.isEmpty {
          throw StructureDDLError.invalidText("A constraint needs at least one column.")
        }
      case .dropConstraint(let name, _), .dropIndex(let name):
        try checkedName(name)
      case .createIndex(let index):
        try checkedName(index.name)
        guard !index.columns.isEmpty else {
          throw StructureDDLError.invalidText("An index needs at least one column.")
        }
        if let method = index.method,
          method.isEmpty || !method.unicodeScalars.allSatisfy(isASCIIWordCharacter)
        {
          throw StructureDDLError.invalidText("An index method is one word (btree, hash, ...).")
        }
      }
    }
  }

  private static func checkedName(_ name: String) throws {
    guard !name.isEmpty else { throw StructureDDLError.invalidText("A name cannot be empty.") }
  }

  private static func isASCIIWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
    scalar.isASCII
      && (scalar == "_" || scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
  }

  /// Rejects type or expression text that is empty, holds a comment, `;` or a control character
  /// (NUL, ESC, ...; tab, newline and carriage return are kept), has a `,` outside parentheses,
  /// unbalanced parentheses or an unterminated quote. The text is lexed inside
  /// `(` `)` with the dialect tokenizer: the wrapper must close last, so a quote or comment that
  /// swallows it, or a `)` that closes it early, is caught.
  static func checkedText(_ text: String, _ what: String, dialect: SQLDialect) throws {
    let invalid = StructureDDLError.invalidText(
      "The \(what) \"\(text)\" must be one SQL fragment: no comments, semicolons or commas "
        + "outside parentheses, and balanced parentheses and quotes.")
    guard text.unicodeScalars.contains(where: { !SQLTokenizer.isWhitespace($0) }) else {
      throw StructureDDLError.invalidText("The \(what) cannot be empty.")
    }
    guard
      !text.unicodeScalars.contains(where: {
        $0.value < 0x20 && !"\t\n\r".unicodeScalars.contains($0)
      })
    else {
      throw StructureDDLError.invalidText("The \(what) cannot contain control characters.")
    }
    let tokenizer = SQLTokenizer(dialect: dialect)
    let scalars = Array(("(" + text + ")").unicodeScalars)
    var depth = 0
    var closed = false
    var i = 0
    while i < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: i)
      switch lexeme.kind {
      case .comment, .executableComment:
        throw invalid
      case .symbol:
        switch scalars[i] {
        case "(": depth += 1
        case ")":
          depth -= 1
          if depth == 0 {
            guard lexeme.range.upperBound == scalars.count else { throw invalid }
            closed = true
          }
        case ";": throw invalid
        case "," where depth == 1: throw invalid
        default: break
        }
      default:
        break
      }
      i = lexeme.range.upperBound
    }
    // An unterminated quote or block comment swallows the closing wrapper
    guard closed else { throw invalid }
  }
}
