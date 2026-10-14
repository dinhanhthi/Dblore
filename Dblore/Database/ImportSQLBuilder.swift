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
    dialect: SQLDialect, bindLimit: Int? = nil, maxChunkBytes: Int? = nil
  ) throws -> [BoundStatement] {
    try insertStatements(
      schema: schema, table: table,
      columns: columns.map { Column(name: $0, kind: .text) }, rows: rows,
      dialect: dialect, bindLimit: bindLimit, maxChunkBytes: maxChunkBytes)
  }

  static func insertStatements(
    schema: String?, table: String, columns: [Column], rows: [[String?]],
    dialect: SQLDialect, bindLimit: Int? = nil, maxChunkBytes: Int? = nil
  ) throws -> [BoundStatement] {
    guard !columns.isEmpty else { throw Error.invalidColumns }
    let maximumBinds = bindLimit ?? defaultBindLimit(dialect)
    let chunkSize = min(1_000, maximumBinds / columns.count)
    guard chunkSize > 0 else { throw Error.bindLimitExceeded }
    let relation = try dialect.qualified(schema: schema, name: table)
    let names = try columns.map { try dialect.quoteIdentifier($0.name) }.joined(separator: ", ")
    let prefix = "INSERT INTO \(relation) (\(names)) VALUES "
    let timestamps = dialect == .mysql ? ImportTypeInference.TimestampParser() : nil
    var statements: [BoundStatement] = []
    var chunk: [[String?]] = []
    var chunkBytes = 0
    func flush() {
      guard !chunk.isEmpty else { return }
      var placeholder = 1
      let tuples = chunk.map { _ in
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
      chunk = []
      chunkBytes = 0
    }
    for (offset, row) in rows.enumerated() {
      if offset.isMultiple(of: 256) { try Task.checkCancellation() }
      guard row.count == columns.count else { throw Error.invalidRowWidth }
      let values = try zip(row, columns).map { value, column in
        try bindValue(value, kind: column.kind, dialect: dialect, timestamps: timestamps)
      }
      let rowBytes = maxChunkBytes == nil ? 0 : Self.boundBytes(values)
      if chunk.count == chunkSize
        || (maxChunkBytes.map { chunkBytes + rowBytes > $0 } == true && !chunk.isEmpty)
      {
        flush()
      }
      chunk.append(values)
      chunkBytes += rowBytes
    }
    flush()
    return statements
  }

  /// Largest MySQL INSERT payload: half the session's `max_allowed_packet`, and never above
  /// 8 MiB because mysql-nio writes each command as one packet (no split at 16 MiB). Unknown:
  /// 8 MiB (MariaDB's default limit is 16 MB).
  static func mysqlChunkByteCap(maxAllowedPacket: Int?) -> Int {
    let mysqlNIOPacketLimit = 16 * 1_024 * 1_024
    return min(maxAllowedPacket ?? mysqlNIOPacketLimit, mysqlNIOPacketLimit) / 2
  }

  /// Bytes a row's binds add to a COM_STMT_EXECUTE payload: the text plus the type, length and
  /// NULL-bitmap overhead (at most 12 bytes per bind).
  private static func boundBytes(_ values: [String?]) -> Int {
    values.reduce(0) { $0 + ($1?.utf8.count ?? 0) + 12 }
  }

  /// PostgreSQL and MySQL prepared statements take 65535 placeholders; SQLite and DuckDB 999.
  private static func defaultBindLimit(_ dialect: SQLDialect) -> Int {
    switch dialect {
    case .postgresql, .mysql: 65_535
    case .sqlite, .duckdb: 999
    default: 999
    }
  }

  /// SQLite and MySQL store booleans as integers, so "true"/"false" bind as 1 and 0. MySQL
  /// DATETIME refuses ISO 8601 `T`, `Z` and offsets, so a timestamp `timestamps` parses binds
  /// as UTC `YYYY-MM-DD HH:MM:SS.ffffff` (the session time zone is UTC); other text is sent as
  /// is and the server reports it.
  private static func bindValue(
    _ raw: String?, kind: ImportTypeInference.Kind, dialect: SQLDialect,
    timestamps: ImportTypeInference.TimestampParser?
  ) throws -> String? {
    guard let value = ImportTypeInference.normalizedValue(raw) else { return nil }
    if kind == .timestamp, let timestamps {
      guard let date = timestamps.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
      else {
        return value
      }
      return CellUpdateStatement.inputText(.date(date), dialect: .mysql)
    }
    guard kind == .boolean else { return value }
    switch dialect {
    case .sqlite, .mysql: break
    default: return value
    }
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
