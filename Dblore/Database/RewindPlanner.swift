// RewindPlanner.swift
// The Data Rewind inverse statements for chosen entries: newest entry first and each entry's
// rows in reverse, every statement expecting one row.
// - An UPDATE goes back to the before-image: `SET <changed columns> = <before>` WHERE the key is
//   the after-image's AND every changed column still reads as the after-image.
// - A DELETE is undone by an INSERT of every captured column but the generated ones, with
//   PostgreSQL `OVERRIDING SYSTEM VALUE` when it writes a `GENERATED ALWAYS` identity column.
// - An INSERT is undone by a DELETE by key WHERE every other column still reads as inserted.
// The checks compare the capture's own text form with null-safe equality (PostgreSQL
// `col::text COLLATE "C" IS NOT DISTINCT FROM`, MySQL `CAST(CAST(col AS CHAR) AS BINARY) <=>
// CAST(? AS BINARY)` or `HEX(col) <=>`, SQLite `quote(col) IS`): the after-image is that text,
// PostgreSQL `json` has no equality operator, a nondeterministic PostgreSQL collation can fold
// case ("C" compares bytes), and MySQL's collations fold case and (`_bin` included) ignore
// trailing spaces. The MySQL text and the bind are both in the connection charset (utf8mb4,
// `MySQLSession`), so the binary comparison is byte for byte on MySQL and MariaDB. PostgreSQL
// `bpchar::text` drops the trailing spaces, but `char(n)` stores 'a' and 'a ' as one value, so
// no change goes unseen; SQLite compares `quote()` text with BINARY. A failed check matches no
// row, so the batch's row count stops the whole rewind. The MySQL row check (0 changed rows
// counts as 1 when it finds the row) repeats the whole WHERE, so a failed check is never a
// success.
// The store file is outside the database and is untrusted: the relation is rebuilt from schema
// and table (the stored server text must name the same table and is never sent), names are
// quoted by the dialect and must be live columns, the key must be the live primary key, and
// values go through `RewindCaptureSQL.bind`.

import Foundation

/// Schema (MySQL: database) and table of a rewound entry
nonisolated struct RewindTableName: Hashable, Sendable {
  var schema: String
  var table: String
}

/// What the live table says about the columns a rewind writes.
nonisolated struct RewindTable: Sendable, Equatable {
  var columns: Set<String>
  /// Key columns in key order
  var primaryKey: [String]
  /// Never written (`TableStructure.Column.generated`)
  var generatedColumns: Set<String> = []
  /// PostgreSQL `GENERATED ALWAYS AS IDENTITY`: an INSERT writing one needs
  /// `OVERRIDING SYSTEM VALUE`
  var identityAlwaysColumns: Set<String> = []

  init(
    columns: Set<String>, primaryKey: [String], generatedColumns: Set<String> = [],
    identityAlwaysColumns: Set<String> = []
  ) {
    self.columns = columns
    self.primaryKey = primaryKey
    self.generatedColumns = generatedColumns
    self.identityAlwaysColumns = identityAlwaysColumns
  }

  init(_ structure: TableStructure) {
    columns = Set(structure.columns.map(\.name))
    primaryKey = structure.constraints.first { $0.kind == .primaryKey }?.columns ?? []
    generatedColumns = Set(structure.columns.filter { $0.generated != nil }.map(\.name))
    identityAlwaysColumns = Set(structure.columns.filter { $0.identity == .always }.map(\.name))
  }
}

/// The inverse statements of a rewind, in run order, and the rows left out.
nonisolated struct RewindInverse: Sendable, Equatable {
  /// The edited row a statement undoes, to say which row stopped a rewind
  nonisolated struct Origin: Sendable, Equatable {
    var entryID: Int64
    var created: Date
    var table: String
    /// The edit's operation (an undone DELETE runs an INSERT)
    var operation: RewindRow.Operation
    /// `id = 5` in the capture's text form; empty when the key was not captured
    var key: String
  }

  /// A row with no images or key: listed, and left out only with the user's consent
  nonisolated struct Skipped: Sendable, Equatable {
    var origin: Origin
    var reason: String
  }

  var statements: [BoundStatement] = []
  /// Each statement with its values as literals, as sent
  var previews: [String] = []
  var origins: [Origin] = []
  var skipped: [Skipped] = []
  /// Entries rewound, newest first
  var entryIDs: [Int64] = []

  var preview: String { previews.joined(separator: "\n") }
}

nonisolated enum RewindPlannerError: Error, Equatable, LocalizedError {
  /// The entry cannot be rewound safely; nothing of the rewind is planned
  case refused(entryID: Int64, table: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .refused(_, let table, let reason):
      "An edit of \(table) cannot be rewound: \(reason)."
    }
  }
}

extension DatabaseType {
  /// Data viewer edits are recorded and can be rewound (not DuckDB, not MongoDB)
  nonisolated var supportsDataRewind: Bool {
    switch self {
    case .postgresql, .mysql, .sqlite: true
    case .duckdb, .mongodb: false
    }
  }
}

nonisolated enum RewindPlanner {
  /// Why a row without images or key is left out
  static let notCapturedReason = "not captured"

  /// The inverse statements of `entries` (any order) on `engine`, against the live `tables`.
  /// - Throws: `RewindPlannerError.refused` for the first entry that cannot be rewound safely.
  static func plan(
    _ entries: [(entry: RewindEntry, rows: [RewindRow])], tables: [RewindTableName: RewindTable],
    engine: DatabaseType
  ) throws -> RewindInverse {
    let dialect: SQLDialect
    switch engine {
    case .postgresql: dialect = .postgresql
    case .mysql: dialect = .mysql
    case .sqlite: dialect = .sqlite
    case .duckdb, .mongodb:
      throw RewindPlannerError.refused(
        entryID: entries.first?.entry.id ?? 0, table: entries.first?.entry.table ?? "",
        reason: "\(engine.rawValue) has no Data Rewind")
    }
    let ordered = entries.sorted {
      ($0.entry.created, $0.entry.id) > ($1.entry.created, $1.entry.id)
    }
    var inverse = RewindInverse()
    for (entry, rows) in ordered {
      let planner = try EntryPlanner(
        entry: entry, rows: rows, tables: tables, engine: engine, dialect: dialect)
      try planner.append(to: &inverse)
    }
    return inverse
  }
}

/// One entry, checked against the live table, turned into statements.
private nonisolated struct EntryPlanner {
  let entry: RewindEntry
  let rows: [RewindRow]
  let engine: DatabaseType
  let dialect: SQLDialect
  let table: RewindTable
  /// `"schema"."table"`, rebuilt by the dialect
  let relation: String
  let columns: [RewindColumn]
  let names: Set<String>

  init(
    entry: RewindEntry, rows: [RewindRow], tables: [RewindTableName: RewindTable],
    engine: DatabaseType, dialect: SQLDialect
  ) throws {
    self.entry = entry
    self.rows = rows
    self.engine = engine
    self.dialect = dialect
    func refuse(_ reason: String) -> RewindPlannerError {
      .refused(entryID: entry.id, table: entry.table, reason: reason)
    }
    guard entry.engine == engine else { throw refuse("it was recorded on another engine") }
    guard entry.state == .committed || entry.state == .pending else {
      throw refuse("it is \(entry.state.rawValue)")
    }
    guard let schema = entry.schema, !entry.table.isEmpty,
      Self.unquotedParts(entry.qualifiedName, dialect: dialect)
        == RewindTableName(schema: schema, table: entry.table)
    else { throw refuse("the stored table name does not match") }
    guard let table = tables[RewindTableName(schema: schema, table: entry.table)] else {
      throw refuse("the table was not found")
    }
    guard !table.primaryKey.isEmpty else { throw refuse("the table has no primary key") }
    do {
      relation = try dialect.quoteIdentifier(schema) + "." + dialect.quoteIdentifier(entry.table)
      for column in entry.columns { _ = try dialect.quoteIdentifier(column.name) }
    } catch {
      throw refuse("a stored name cannot be quoted")
    }
    names = Set(entry.columns.map(\.name))
    guard names.count == entry.columns.count else { throw refuse("a column is listed twice") }
    guard names.isSubset(of: table.columns) else { throw refuse("a column no longer exists") }
    let keys = Set(table.primaryKey)
    for row in rows {
      guard row.primaryKey.isEmpty || Set(row.primaryKey.keys) == keys else {
        throw refuse("the table's primary key changed")
      }
      for image in [row.before, row.after].compactMap({ $0 }) where Set(image.keys) != names {
        throw refuse("a stored row does not match its columns")
      }
    }
    self.table = table
    self.columns = entry.columns
  }

  /// Appends this entry's statements, rows in reverse, or its skipped rows.
  func append(to inverse: inout RewindInverse) throws {
    for row in rows.reversed() {
      let origin = RewindInverse.Origin(
        entryID: entry.id, created: entry.created, table: entry.table, operation: row.operation,
        key: keyText(row.primaryKey))
      if let reason = skipReason(row) {
        inverse.skipped.append(RewindInverse.Skipped(origin: origin, reason: reason))
        continue
      }
      let built: StatementBuilder?
      do {
        built = try statement(for: row)
      } catch {
        throw RewindPlannerError.refused(
          entryID: entry.id, table: entry.table, reason: "a stored value is not in the read form")
      }
      guard let built else { continue }
      inverse.statements.append(built.bound)
      inverse.previews.append(built.preview + ";")
      inverse.origins.append(origin)
    }
    inverse.entryIDs.append(entry.id)
  }

  /// Why `row` cannot be undone (left out with consent), or nil.
  private func skipReason(_ row: RewindRow) -> String? {
    switch row.operation {
    case .insert where row.primaryKey.isEmpty:
      // Without a generated key in the entry, an explicit key's read after the INSERT failed
      entry.notRewindableReason ?? RewindPlanner.notCapturedReason
    case .insert:
      row.after == nil ? RewindPlanner.notCapturedReason : nil
    case .update:
      row.before == nil || row.after == nil || row.primaryKey.isEmpty
        ? RewindPlanner.notCapturedReason : nil
    case .delete:
      row.before == nil ? RewindPlanner.notCapturedReason : nil
    }
  }

  /// The inverse of `row` (images checked by `skipReason`), or nil when it changed nothing.
  private func statement(for row: RewindRow) throws -> StatementBuilder? {
    switch row.operation {
    case .update:
      guard let before = row.before, let after = row.after else { return nil }
      return try undoUpdate(before: before, after: after)
    case .delete:
      guard let before = row.before else { return nil }
      return try undoDelete(before: before)
    case .insert:
      guard let after = row.after else { return nil }
      return try undoInsert(after: after)
    }
  }

  private func undoUpdate(before: RewindImage, after: RewindImage) throws -> StatementBuilder? {
    let changed = columns.filter {
      !table.generatedColumns.contains($0.name) && before[$0.name] != after[$0.name]
    }
    guard !changed.isEmpty else { return nil }
    var builder = StatementBuilder(dialect: dialect)
    builder.text("UPDATE \(relation) SET ")
    for (index, column) in changed.enumerated() {
      builder.text((index > 0 ? ", " : "") + "\(try quote(column.name)) = ")
      builder.bind(try bind(before, column))
    }
    let keys = Set(table.primaryKey)
    let checked = changed.filter { !keys.contains($0.name) }
    builder.text(" WHERE ")
    try appendCondition(after, checking: checked, to: &builder)
    if engine == .mysql {
      var check = StatementBuilder(dialect: dialect)
      check.text("SELECT 1 FROM \(relation) WHERE ")
      try appendCondition(after, checking: checked, to: &check)
      check.text(" FOR UPDATE")
      builder.rowCheck = RowExistenceCheck(sql: check.sql, values: check.values)
    }
    return builder
  }

  private func undoDelete(before: RewindImage) throws -> StatementBuilder {
    let written = columns.filter { !table.generatedColumns.contains($0.name) }
    var builder = StatementBuilder(dialect: dialect)
    let names = try written.map { try quote($0.name) }.joined(separator: ", ")
    builder.text("INSERT INTO \(relation) (\(names))")
    if engine == .postgresql,
      written.contains(where: { table.identityAlwaysColumns.contains($0.name) })
    {
      builder.text(" OVERRIDING SYSTEM VALUE")
    }
    builder.text(" VALUES (")
    for (index, column) in written.enumerated() {
      if index > 0 { builder.text(", ") }
      builder.bind(try bind(before, column))
    }
    builder.text(")")
    return builder
  }

  private func undoInsert(after: RewindImage) throws -> StatementBuilder {
    let keys = Set(table.primaryKey)
    let checked = columns.filter {
      !keys.contains($0.name) && !table.generatedColumns.contains($0.name)
    }
    var builder = StatementBuilder(dialect: dialect)
    builder.text("DELETE FROM \(relation) WHERE ")
    try appendCondition(after, checking: checked, to: &builder)
    return builder
  }

  /// `<key> = <value> AND … AND <text form of each checked column> <null-safe equal> <stored
  /// text>`, values from `image`.
  private func appendCondition(
    _ image: RewindImage, checking checked: [RewindColumn], to builder: inout StatementBuilder
  ) throws {
    var first = true
    func and() {
      if !first { builder.text(" AND ") }
      first = false
    }
    for key in table.primaryKey {
      guard let column = columns.first(where: { $0.name == key }) else {
        throw RewindCaptureError.noPrimaryKey
      }
      and()
      builder.text("\(try quote(key)) = ")
      builder.bind(try bind(image, column))
    }
    for column in checked {
      guard let text = image[column.name] else {
        throw RewindCaptureError.unexpectedValue(column: column.name)
      }
      and()
      let bytes = engine == .mysql && !SQLDumpDataRenderer.isMySQLHexType(column.typeName)
      builder.text(try comparison(column) + (bytes ? " CAST(" : " "))
      builder.bind(RewindBind(form: .plain, value: SQLBindValue(optionalText: text)))
      if bytes { builder.text(" AS BINARY)") }
    }
  }

  /// The column in the capture's text form and the null-safe equality operator (MySQL text:
  /// as bytes, the bind cast the same way by `appendCondition`).
  private func comparison(_ column: RewindColumn) throws -> String {
    let name = try quote(column.name)
    switch engine {
    case .postgresql:
      // A nondeterministic column collation would carry over through the cast and fold case
      return "\(name)::text COLLATE \"C\" IS NOT DISTINCT FROM"
    case .mysql:
      // HEX digits hold no spaces, so only the text form needs the byte comparison
      return SQLDumpDataRenderer.isMySQLHexType(column.typeName)
        ? "HEX(\(name)) <=>" : "CAST(CAST(\(name) AS CHAR) AS BINARY) <=>"
    case .sqlite:
      return "quote(\(name)) IS"
    case .duckdb, .mongodb:
      throw RewindCaptureError.unsupportedEngine(engine)
    }
  }

  private func bind(_ image: RewindImage, _ column: RewindColumn) throws -> RewindBind {
    guard let text = image[column.name] else {
      throw RewindCaptureError.unexpectedValue(column: column.name)
    }
    return try RewindCaptureSQL.bind(text, column: column, engine: engine)
  }

  private func quote(_ name: String) throws -> String {
    try dialect.quoteIdentifier(name)
  }

  /// `id = 5, k = 'a'` in key order, from the stored text (display only)
  private func keyText(_ key: RewindImage) -> String {
    table.primaryKey.compactMap { name in
      key[name].map { "\(name) = \($0 ?? "NULL")" }
    }.joined(separator: ", ")
  }

  /// Schema and table of server `format('%I.%I')` text (MySQL: two backtick-quoted names), or
  /// nil for any other shape (`CellUpdateStatement.isServerQualifiedName`).
  static func unquotedParts(_ name: String, dialect: SQLDialect) -> RewindTableName? {
    guard CellUpdateStatement.isServerQualifiedName(name, dialect: dialect) else { return nil }
    let quote: Character = dialect == .mysql ? "`" : "\""
    var parts: [String] = []
    var current = ""
    var quoted = false
    var index = name.startIndex
    while index < name.endIndex {
      let character = name[index]
      let next = name.index(after: index)
      if character == quote {
        if quoted, next < name.endIndex, name[next] == quote {
          current.append(quote)
          index = name.index(after: next)
          continue
        }
        quoted.toggle()
      } else if character == ".", !quoted {
        parts.append(current)
        current = ""
      } else {
        current.append(character)
      }
      index = next
    }
    parts.append(current)
    guard parts.count == 2 else { return nil }
    return RewindTableName(schema: parts[0], table: parts[1])
  }
}

/// SQL text and binds built together, with a preview that shows each value as a literal.
private nonisolated struct StatementBuilder {
  let dialect: SQLDialect
  private(set) var sql = ""
  private(set) var values: [String?] = []
  private(set) var preview = ""
  var rowCheck: RowExistenceCheck? = nil

  init(dialect: SQLDialect) {
    self.dialect = dialect
  }

  var bound: BoundStatement {
    BoundStatement(sql: sql, values: values, rowCheck: rowCheck)
  }

  mutating func text(_ text: String) {
    sql += text
    preview += text
  }

  mutating func bind(_ bind: RewindBind) {
    sql += bind.sql(placeholder: dialect.placeholder(values.count + 1))
    switch bind.value {
    case .null:
      values.append(nil)
      preview += bind.sql(placeholder: "NULL")
    case .text(let text):
      values.append(text)
      preview += bind.sql(placeholder: dialect.literal(.string(text)))
    }
  }
}
