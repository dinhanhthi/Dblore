import Foundation

nonisolated enum ImportSQLBuilder {
  enum Error: Swift.Error, Equatable, Sendable {
    case invalidColumns
    case invalidRowWidth
    case bindLimitExceeded
    case invalidBoolean
  }

  struct Column: Sendable, Equatable {
    var name: String
    var kind: ImportTypeInference.Kind
  }

  static func createTable(
    schema: String?, table: String, columns: [Column], dialect: SQLDialect
  ) throws -> BoundStatement {
    guard !columns.isEmpty else { throw Error.invalidColumns }
    let relation = try dialect.qualified(schema: schema, name: table)
    let definitions = try columns.map { column in
      try dialect.quoteIdentifier(column.name) + " " + column.kind.sqlType(dialect: dialect)
    }.joined(separator: ", ")
    return BoundStatement(
      sql: "CREATE TABLE \(relation) (\(definitions))", values: [], expectedRows: nil)
  }

  static func insertStatements(
    schema: String?, table: String, columns: [String], rows: [[String?]],
    dialect: SQLDialect, bindLimit: Int? = nil
  ) throws -> [BoundStatement] {
    try insertStatements(
      schema: schema, table: table,
      columns: columns.map { Column(name: $0, kind: .text) }, rows: rows,
      dialect: dialect, bindLimit: bindLimit)
  }

  static func insertStatements(
    schema: String?, table: String, columns: [Column], rows: [[String?]],
    dialect: SQLDialect, bindLimit: Int? = nil
  ) throws -> [BoundStatement] {
    guard !columns.isEmpty else { throw Error.invalidColumns }
    let maximumBinds = bindLimit ?? (dialect == .postgresql ? 65_535 : 999)
    let chunkSize = min(1_000, maximumBinds / columns.count)
    guard chunkSize > 0 else { throw Error.bindLimitExceeded }
    let relation = try dialect.qualified(schema: schema, name: table)
    let names = try columns.map { try dialect.quoteIdentifier($0.name) }.joined(separator: ", ")
    let prefix = "INSERT INTO \(relation) (\(names)) VALUES "
    var statements: [BoundStatement] = []
    for start in stride(from: 0, to: rows.count, by: chunkSize) {
      try Task.checkCancellation()
      let chunk = rows[start..<min(start + chunkSize, rows.count)]
      var values: [String?] = []
      values.reserveCapacity(chunk.count * columns.count)
      for (offset, row) in chunk.enumerated() {
        if offset.isMultiple(of: 256) { try Task.checkCancellation() }
        guard row.count == columns.count else { throw Error.invalidRowWidth }
        for (value, column) in zip(row, columns) {
          values.append(try bindValue(value, kind: column.kind, dialect: dialect))
        }
      }
      var placeholder = 1
      let tuples = chunk.map { row in
        let markers = columns.map { column in
          defer { placeholder += 1 }
          let marker = dialect.placeholder(placeholder)
          return dialect == .sqlite && column.kind == .boolean
            ? "CAST(\(marker) AS INTEGER)" : marker
        }
        return "(" + markers.joined(separator: ", ") + ")"
      }
      statements.append(
        BoundStatement(
          sql: prefix + tuples.joined(separator: ", "),
          values: values, expectedRows: chunk.count))
    }
    return statements
  }

  private static func bindValue(
    _ raw: String?, kind: ImportTypeInference.Kind, dialect: SQLDialect
  ) throws -> String? {
    guard let value = ImportTypeInference.normalizedValue(raw) else { return nil }
    guard dialect == .sqlite, kind == .boolean else { return value }
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true": return "1"
    case "false": return "0"
    default: throw Error.invalidBoolean
    }
  }

  static func summaryText(
    createTable: BoundStatement?, schema: String?, table: String, columns: [String],
    rowCount: Int, dialect: SQLDialect
  ) throws -> String {
    let relation = try dialect.qualified(schema: schema, name: table)
    let names = try columns.map(dialect.quoteIdentifier).joined(separator: ", ")
    let insert = "INSERT INTO \(relation) (\(names)) -- \(rowCount) rows from file"
    guard let createTable else { return insert }
    return createTable.sql + ";\n" + insert
  }
}
