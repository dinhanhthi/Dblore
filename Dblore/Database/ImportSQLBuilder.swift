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

    init(name: String, kind: ImportTypeInference.Kind) {
      self.name = name
      self.kind = kind
    }
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
    guard rows.allSatisfy({ $0.count == columns.count }) else { throw Error.invalidRowWidth }
    let maximumBinds = bindLimit ?? (dialect == .postgresql ? 65_535 : 999)
    let chunkSize = min(1_000, maximumBinds / columns.count)
    guard chunkSize > 0 else { throw Error.bindLimitExceeded }
    let relation = try dialect.qualified(schema: schema, name: table)
    let names = try columns.map { try dialect.quoteIdentifier($0.name) }.joined(separator: ", ")
    let prefix = "INSERT INTO \(relation) (\(names)) VALUES "
    let preparedRows = try rows.map { row in
      try zip(row, columns).map { value, column in
        try bindValue(value, kind: column.kind, dialect: dialect)
      }
    }
    var statements: [BoundStatement] = []
    for start in stride(from: 0, to: preparedRows.count, by: chunkSize) {
      let chunk = preparedRows[start..<min(start + chunkSize, preparedRows.count)]
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
          values: chunk.flatMap { $0 }, expectedRows: chunk.count))
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
