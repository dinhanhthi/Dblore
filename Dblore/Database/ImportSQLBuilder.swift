import Foundation

nonisolated enum ImportSQLBuilder {
  enum Error: Swift.Error, Equatable, Sendable {
    case invalidColumns
    case invalidRowWidth
    case bindLimitExceeded
    case invalidBoolean
    /// An UPDATE row whose key has a NULL part or a value its column can't match
    case invalidKey
  }

  /// What a keyed import does with its file rows (`TableImportModel`)
  struct MatchCounts: Sendable, Equatable {
    var inserts: Int
    var updates: Int
    var skips: Int
    var refused: Int
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

  /// Each row's bind text as the INSERT and UPDATE statements send it (blank cells are NULL)
  static func bindRows(
    _ rows: [[String?]], columns: [Column], dialect: SQLDialect
  ) throws -> [[String?]] {
    let timestamps = dialect == .mysql ? ImportTypeInference.TimestampParser() : nil
    var bound: [[String?]] = []
    bound.reserveCapacity(rows.count)
    for (offset, row) in rows.enumerated() {
      if offset.isMultiple(of: 256) { try Task.checkCancellation() }
      guard row.count == columns.count else { throw Error.invalidRowWidth }
      bound.append(
        try zip(row, columns).map { value, column in
          try bindValue(value, kind: column.kind, dialect: dialect, timestamps: timestamps)
        })
    }
    return bound
  }

  /// The key text of `row` (as `bindRows` returns it) that the match read and the UPDATE
  /// bind, in key order. Nil when a key part is NULL, not a column, or a value its column
  /// can't match.
  static func keyText(
    _ row: [String?], columns: [Column], keys: [ImportMatchPlanner.KeyColumn]
  ) -> [String]? {
    var text: [String] = []
    for key in keys {
      guard let index = columns.firstIndex(where: { $0.name == key.name }),
        row.indices.contains(index),
        let value = ImportTypeInference.normalizedValue(row[index]),
        case .text(let bound) = key.bindText(value)
      else { return nil }
      text.append(bound)
    }
    return text
  }

  /// `UPDATE <table> SET <mapped non-key columns> WHERE <key>` for one file row, expecting one
  /// row. The key compares as the match read does (`KeyColumn.equals`, with its cast, COLLATE
  /// or CONVERT). MySQL counts changed rows only, so the statement carries the row check of a
  /// staged UPDATE: a row the write leaves unchanged still counts as the one expected.
  static func updateStatement(
    schema: String?, table: String, columns: [Column], row: [String?],
    keys: [ImportMatchPlanner.KeyColumn], dialect: SQLDialect
  ) throws -> BoundStatement {
    guard row.count == columns.count else { throw Error.invalidRowWidth }
    let values = try bindRows([row], columns: columns, dialect: dialect)[0]
    guard !keys.isEmpty, let keyValues = keyText(values, columns: columns, keys: keys) else {
      throw Error.invalidKey
    }
    let keyNames = Set(keys.map(\.name))
    let assigned = columns.indices.filter { !keyNames.contains(columns[$0].name) }
    guard !assigned.isEmpty else { throw Error.invalidColumns }
    let relation = try dialect.qualified(schema: schema, name: table)
    let assignments = try assigned.enumerated().map { offset, index in
      let marker = dialect.placeholder(offset + 1)
      let value =
        dialect == .sqlite && columns[index].kind == .boolean
        ? "CAST(\(marker) AS INTEGER)" : marker
      return try dialect.quoteIdentifier(columns[index].name) + " = " + value
    }.joined(separator: ", ")
    func condition(after count: Int) throws -> String {
      try keys.enumerated().map { offset, key in
        key.equals(
          try dialect.quoteIdentifier(key.name),
          key.value(dialect.placeholder(count + offset + 1)))
      }.joined(separator: " AND ")
    }
    var statement = BoundStatement(
      sql: "UPDATE \(relation) SET \(assignments) WHERE \(try condition(after: assigned.count))",
      values: assigned.map { values[$0] } + keyValues, expectedRows: 1)
    if dialect == .mysql {
      statement.rowCheck = RowExistenceCheck(
        sql: "SELECT 1 FROM \(relation) WHERE \(try condition(after: 0)) FOR UPDATE",
        values: keyValues)
    }
    return statement
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
  static func defaultBindLimit(_ dialect: SQLDialect) -> Int {
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

  /// History and Safe Mode text of a keyed import: the counts, then the statement kinds it
  /// sends (`update` is one of its UPDATEs, placeholders only). Never file values.
  static func matchSummaryText(
    schema: String?, table: String, columns: [String], update: BoundStatement?,
    counts: MatchCounts, dialect: SQLDialect
  ) throws -> String {
    let relation = try dialect.qualified(schema: schema, name: table)
    let names = try columns.map(dialect.quoteIdentifier).joined(separator: ", ")
    var statements: [String] = []
    if counts.inserts > 0 { statements.append("INSERT INTO \(relation) (\(names))") }
    if counts.updates > 0, let update { statements.append(update.sql) }
    let header =
      "-- From file: \(counts.inserts) to insert, \(counts.updates) to update, "
      + "\(counts.skips) skipped, \(counts.refused) refused"
    return ([header] + (statements.isEmpty ? [] : [statements.joined(separator: ";\n")]))
      .joined(separator: "\n")
  }
}
