// StructureDDLBuilder+MySQL.swift
// MySQL / MariaDB: every change in ONE `ALTER TABLE db.table` (atomic DDL on InnoDB 8), clauses in
// this order: DROP constraint / DROP INDEX, DROP COLUMN, ADD COLUMN, one clause per edited column,
// ADD constraint, ADD INDEX, then the table COMMENT; each group in the order given. A table rename
// is a `RENAME TABLE db.old TO db.new` after it: the statements run one by one, so the ALTER must
// still name the loaded table.
//
// All edits to one column merge into one clause. MODIFY (or CHANGE when renamed) restates the
// full loaded definition and changes only the edited parts: COLUMN_TYPE, CHARACTER SET and
// COLLATE (as the column reports them: the table default is not loaded; dropped when the type
// changes to a non-character type), generated expression, NULL / NOT NULL, DEFAULT, EXTRA
// (AUTO_INCREMENT, ON UPDATE, INVISIBLE) and COMMENT. An EXTRA word it does not know throws
// rather than being lost. A rename alone is RENAME COLUMN on MySQL 8+ and MariaDB 10.5.2+.
// Catalog text restated as is (COLUMN_TYPE, DEFAULT, generated expression, ON UPDATE) goes
// through `checkedText` like typed text; text that fails throws rather than being sent. A spatial
// column is never restated: its SRID is not loaded and MODIFY would drop it. MariaDB refuses NOT
// NULL on a generated column, so such a definition is refused there.
// New constraints and indexes name columns as loaded; renamed ones are written with the new name.
// A new CHECK naming a column renamed in the same batch is refused: the one ALTER TABLE checks
// it against the new names.

import Foundation

nonisolated extension StructureDDLBuilder {
  private struct ColumnEdit {
    var type: String?
    /// Outer nil: unchanged. Inner nil: dropped.
    var defaultExpression: String??
    var isNullable: Bool?
    var newName: String?
  }

  static func mysqlStatements(
    _ changes: [StructureChange], structure: TableStructure, server: MySQLServerInfo
  ) throws -> [String] {
    let dialect = SQLDialect.mysql
    let q = dialect.quoteIdentifier
    var renamed: [String: String] = [:]
    for case .renameColumn(let column, let newName) in changes { renamed[column] = newName }
    var drops: [String] = []
    var dropColumns: [String] = []
    var addColumns: [String] = []
    var edits: [String: ColumnEdit] = [:]
    var editOrder: [String] = []
    var addConstraints: [String] = []
    var addIndexes: [String] = []
    var tableComment: String?
    var tableRename: String?
    func edit(_ column: String, _ apply: (inout ColumnEdit) -> Void) {
      if edits[column] == nil { editOrder.append(column) }
      apply(&edits[column, default: ColumnEdit()])
    }
    for change in changes {
      switch change {
      case .addColumn(let column):
        addColumns.append("ADD COLUMN " + (try columnDefinition(column, dialect: dialect)))
      case .alterColumnType(let column, let type):
        edit(column) { $0.type = type }
      case .setDefault(let column, let expression):
        edit(column) { $0.defaultExpression = .some(expression) }
      case .dropDefault(let column):
        edit(column) { $0.defaultExpression = .some(nil) }
      case .setNotNull(let column):
        edit(column) { $0.isNullable = false }
      case .dropNotNull(let column):
        edit(column) { $0.isNullable = true }
      case .renameColumn(let column, let newName):
        edit(column) { $0.newName = newName }
      case .dropColumn(let column):
        dropColumns.append("DROP COLUMN \(try q(column))")
      case .addConstraint(let constraint):
        if case .check(let expression) = constraint.kind {
          guard supportsChecks(server) else {
            throw StructureDDLError.unsupported("CHECK constraints need MySQL 8.0.16 or later.")
          }
          if mentionsAny(expression, of: renamed.keys) {
            throw StructureDDLError.unsupported("Rename the column first, then add the check.")
          }
        }
        addConstraints.append(
          "ADD " + (try constraintDefinition(constraint, dialect: dialect, renamed: renamed)))
      case .dropConstraint(let name, let kind):
        drops.append(try mysqlDropConstraint(name, kind: kind, server: server))
      case .createIndex(let index):
        addIndexes.append(
          "ADD \(index.isUnique ? "UNIQUE " : "")INDEX \(try q(index.name)) "
            + "(\(try quotedList(index.columns, dialect: dialect, renamed: renamed)))"
            + (index.method.map { " USING \($0)" } ?? ""))
      case .dropIndex(let name):
        drops.append("DROP INDEX \(try q(name))")
      case .renameTable(let newName):
        var renamedTable = structure
        renamedTable.name = newName
        tableRename =
          "RENAME TABLE \(try tableName(structure, dialect: dialect)) "
          + "TO \(try tableName(renamedTable, dialect: dialect))"
      case .setTableComment(let text):
        // An empty comment removes it
        tableComment = "COMMENT = \(dialect.literal(.string(text ?? "")))"
      }
    }
    var columnClauses: [String] = []
    for name in editOrder {
      guard let edit = edits[name] else { continue }
      let column = try loadedColumn(name, in: structure)
      let renameOnly = edit.type == nil && edit.defaultExpression == nil && edit.isNullable == nil
      if let newName = edit.newName, renameOnly, supportsRenameColumn(server) {
        columnClauses.append("RENAME COLUMN \(try q(name)) TO \(try q(newName))")
        continue
      }
      let definition = try mysqlDefinition(column, edit: edit, server: server)
      columnClauses.append(
        try edit.newName.map { "CHANGE COLUMN \(try q(name)) \(try q($0)) \(definition)" }
          ?? "MODIFY COLUMN \(try q(name)) \(definition)")
    }
    let clauses =
      drops + dropColumns + addColumns + columnClauses + addConstraints + addIndexes
      + [tableComment].compactMap { $0 }
    let alter =
      clauses.isEmpty
      ? []
      : [
        "ALTER TABLE \(try tableName(structure, dialect: dialect)) "
          + clauses.joined(separator: ", ")
      ]
    return alter + [tableRename].compactMap { $0 }
  }

  /// True when `expression` has a word or quoted identifier equal (ignoring ASCII case, as
  /// MySQL column names) to one of `names`
  private static func mentionsAny(
    _ expression: String, of names: Dictionary<String, String>.Keys
  ) -> Bool {
    let wanted = Set(names.map(SQLTokenizer.asciiLowercased))
    return SQLTokenizer.tokens(expression, dialect: .mysql).contains {
      ($0.kind == .word || $0.kind == .quotedIdentifier)
        && wanted.contains(SQLTokenizer.asciiLowercased($0.text))
    }
  }

  private static func supportsRenameColumn(_ server: MySQLServerInfo) -> Bool {
    switch server.flavor {
    case .mysql: server.major >= 8
    case .mariadb: (server.major, server.minor, server.patch) >= (10, 5, 2)
    }
  }

  private static func supportsChecks(_ server: MySQLServerInfo) -> Bool {
    server.flavor == .mariadb || (server.major, server.minor, server.patch) >= (8, 0, 16)
  }

  private static func mysqlDropConstraint(
    _ name: String, kind: StructureChange.ConstraintKind, server: MySQLServerInfo
  ) throws -> String {
    let quoted = try SQLDialect.mysql.quoteIdentifier(name)
    switch kind {
    case .primaryKey: return "DROP PRIMARY KEY"
    case .unique: return "DROP INDEX \(quoted)"
    case .foreignKey: return "DROP FOREIGN KEY \(quoted)"
    case .check:
      guard supportsChecks(server) else {
        throw StructureDDLError.unsupported("CHECK constraints need MySQL 8.0.16 or later.")
      }
      return server.flavor == .mariadb ? "DROP CONSTRAINT \(quoted)" : "DROP CHECK \(quoted)"
    }
  }

  /// The loaded column definition with `edit` applied, for MODIFY or CHANGE
  private static func mysqlDefinition(
    _ column: TableStructure.Column, edit: ColumnEdit, server: MySQLServerInfo
  ) throws -> String {
    let loadedType = column.columnType ?? column.dataType
    if isSpatialType(loadedType) {
      throw StructureDDLError.unsupported(
        "Spatial columns cannot be modified here; the SRID is not loaded.")
    }
    if edit.type == nil { try checkedCatalogText(loadedType, "type", column: column) }
    let type = edit.type ?? loadedType
    var parts = [type]
    if edit.type == nil || isCharacterType(type) {
      if let characterSet = column.characterSet {
        parts.append("CHARACTER SET \(try catalogWord(characterSet))")
      }
      if let collation = column.collation { parts.append("COLLATE \(try catalogWord(collation))") }
    }
    let extra = try MySQLExtra(column)
    let isNullable = edit.isNullable ?? column.isNullable
    if let generated = column.generated {
      guard let expression = generated.expression else {
        throw StructureDDLError.unsupported(
          "The generation expression of \"\(column.name)\" is unknown.")
      }
      try checkedCatalogText(expression, "generation expression", column: column)
      parts.append(
        "GENERATED ALWAYS AS (\(expression)) \(generated.isStored ? "STORED" : "VIRTUAL")")
      if !isNullable {
        guard server.flavor == .mysql else {
          throw StructureDDLError.unsupported(
            "MariaDB does not allow NOT NULL on a generated column.")
        }
        parts.append("NOT NULL")
      }
    } else {
      // Explicit NULL: a TIMESTAMP column is otherwise NOT NULL on some servers
      parts.append(isNullable ? "NULL" : "NOT NULL")
      let defaultExpression =
        try edit.defaultExpression
        ?? column.defaultExpression.map { (text: String) -> String in
          let restated = restatedDefault(text, column: column, server: server)
          try checkedCatalogText(restated, "default", column: column)
          return restated
        }
      if let defaultExpression { parts.append("DEFAULT \(defaultExpression)") }
      if extra.autoIncrement { parts.append("AUTO_INCREMENT") }
      if let onUpdate = extra.onUpdate {
        try checkedCatalogText(onUpdate, "ON UPDATE value", column: column)
        parts.append("ON UPDATE \(onUpdate)")
      }
    }
    if extra.invisible { parts.append("INVISIBLE") }
    if let comment = column.comment {
      parts.append("COMMENT \(SQLDialect.mysql.literal(.string(comment)))")
    }
    return parts.joined(separator: " ")
  }

  /// MySQL reads an expression default (EXTRA DEFAULT_GENERATED) back without its parentheses;
  /// `DEFAULT uuid()` is a syntax error, so it is restated as `DEFAULT (uuid())`.
  private static func restatedDefault(
    _ text: String, column: TableStructure.Column, server: MySQLServerInfo
  ) -> String {
    let isExpression = (column.extra ?? "").uppercased().contains("DEFAULT_GENERATED")
    guard server.flavor == .mysql, isExpression, !text.hasPrefix("("),
      !text.uppercased().hasPrefix("CURRENT_TIMESTAMP")
    else { return text }
    return "(\(text))"
  }

  /// `checkedText` for text read from the catalog: a failure means it cannot be restated safely
  private static func checkedCatalogText(
    _ text: String, _ what: String, column: TableStructure.Column
  ) throws {
    do {
      try checkedText(text, what, dialect: .mysql)
    } catch {
      throw StructureDDLError.unsupported(
        "The loaded \(what) of \"\(column.name)\" cannot be restated safely (\(text)).")
    }
  }

  private static func isSpatialType(_ type: String) -> Bool {
    let base = type.prefix { $0.isLetter }.lowercased()
    return [
      "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring",
      "multipolygon", "geometrycollection", "geomcollection",
    ].contains(base)
  }

  private static func isCharacterType(_ type: String) -> Bool {
    let base = type.prefix { $0.isLetter }.lowercased()
    return ["char", "varchar", "tinytext", "text", "mediumtext", "longtext", "enum", "set"]
      .contains(base)
  }

  /// A character set or collation name from the catalog: one word, written as is
  private static func catalogWord(_ name: String) throws -> String {
    guard !name.isEmpty,
      name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    else {
      throw StructureDDLError.unsupported("Unexpected character set or collation \"\(name)\".")
    }
    return name
  }

  /// The attributes in a column's EXTRA that a definition must restate
  private struct MySQLExtra {
    var autoIncrement = false
    var onUpdate: String?
    var invisible = false

    init(_ column: TableStructure.Column) throws {
      autoIncrement = column.identity == .autoIncrement
      let text = column.extra ?? ""
      let words = text.split(separator: " ").map(String.init)
      let unknown = StructureDDLError.unsupported(
        "\"\(column.name)\" has attributes the structure editor cannot keep (\(text)).")
      var k = 0
      while k < words.count {
        switch words[k].lowercased() {
        case "auto_increment": autoIncrement = true
        case "default_generated": break
        case "virtual", "stored", "persistent":
          guard column.generated != nil, k + 1 < words.count,
            words[k + 1].lowercased() == "generated"
          else { throw unknown }
          k += 1
        case "invisible": invisible = true
        case "on":
          guard k + 2 < words.count, words[k + 1].lowercased() == "update" else { throw unknown }
          onUpdate = words[k + 2]
          k += 2
        default: throw unknown
        }
        k += 1
      }
    }
  }
}
