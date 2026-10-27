// ImportMatchPlanner.swift
// Which file rows of an import into an existing table are already there, by a match key (the
// primary key or a unique index of plain columns), and what each row then does in the chosen
// `ImportMode`. Pure: it builds the bound reads, one per chunk of rows the bind limit allows,
// and classifies the rows from the counts the reads return. The caller runs the reads.
// A read is `SELECT pos, COUNT(*) FROM (<positioned key rows>) v JOIN <table> t ON t.k = v.k ...
// GROUP BY pos`. Positions are integer literals (file row indexes); every key value is a bind.
// PostgreSQL, SQLite and DuckDB list the rows in VALUES, MySQL/MariaDB in a UNION ALL derived
// table. Each read passes `ReadOnlyQueryGuard`.
// - PostgreSQL and DuckDB bind untyped text, and a VALUES list has no target column to type it,
//   so each key bind is cast to its column's type. PostgreSQL drops the type modifier, the type
//   a bind compared with the column (`WHERE k = $1`) takes: an explicit cast to `varchar(n)`,
//   `char(n)` or `numeric(p,s)` truncates or rounds, which could match another row, and
//   `character` / `bit` without a length mean length 1, so they become `bpchar` / `varbit`.
//   DuckDB keeps the type as its catalog shows it.
// - SQLite compares through the column's affinity and collation (the column is the left side).
// - MySQL/MariaDB build the derived table in the connection's utf8mb4 (`SET NAMES utf8mb4`):
//   a string key compares as `v.k COLLATE <collation>`, or as `CONVERT(v.k USING <charset>)
//   COLLATE <collation>` for another character set, so the column's collation decides (MySQL
//   "Collation of Expressions"; otherwise errors 1267 and 1253). A value the character set
//   cannot hold would convert to `?` and is refused for its row. Text compared with a number
//   compares as double (precision lost above 2^53, `'abc'` equals 0), so integer keys compare
//   with `CAST(v.k AS SIGNED|UNSIGNED)` and DECIMAL keys with `CAST(v.k AS DECIMAL(p,s))`, once
//   the client has refused text that is not a value of the column's type (those casts only
//   warn, then clamp, truncate or round). FLOAT / DOUBLE keys must be finite numbers. Other
//   types compare as they are.
// A NULL key part never matches (SQL equality): the row is not read and counts 0.
// Nothing here is sent to a database.

import Foundation

/// What an import into an existing table does with a file row, by whether its match key is
/// already in the table
nonisolated enum ImportMode: Sendable, Equatable, CaseIterable {
  /// Insert every row; a row whose key exists is refused
  case insert
  /// Update the rows whose key exists; skip the others
  case update
  /// Update the rows whose key exists; insert the others
  case insertOrUpdate
  /// Insert the rows whose key is new; skip the others
  case insertSkippingExisting
}

nonisolated enum ImportMatchPlanner {
  /// Above this many rows a read is split, whatever the bind limit
  static let maxRowsPerRead = 1_000

  /// What one file row does
  enum Outcome: Sendable, Equatable {
    case insert
    case update
    case skip
    /// Not written, with the reason
    case refused(String)
  }

  /// Why no plan could be built (nothing is read)
  enum Error: Swift.Error, Equatable, LocalizedError {
    case noKey
    /// A key column is not among the imported columns
    case keyNotMapped(String)
    /// A key column is not in the table
    case unknownColumn(String)
    case unsupportedKey(column: String, reason: String)
    case invalidRowWidth
    case bindLimitExceeded
    case readRefused(ReadOnlyQueryGuard.Refusal)

    var errorDescription: String? {
      switch self {
      case .noKey: "Choose a key to match rows on."
      case .keyNotMapped(let column):
        "Import the key column \(column) to match rows on it."
      case .unknownColumn(let column): "The key column \(column) is not in the table."
      case .unsupportedKey(let column, let reason):
        "Rows can't be matched on \(column): \(reason)"
      case .invalidRowWidth: "A file row has a different number of values than the columns."
      case .bindLimitExceeded: "The key has more columns than one read can bind."
      case .readRefused(let refusal): refusal.errorDescription
      }
    }
  }

  struct Plan: Sendable, Equatable {
    /// Bound reads with `expectedRows` nil, classified by `ReadOnlyQueryGuard`. Each returns
    /// `(position, count)` rows for the positions it lists that match.
    var reads: [BoundStatement]
    /// Rows refused before any read, by file row index
    var refusals: [Int: String]
    /// Rows with a NULL key part: never read, never matched
    var nullKeyRows: Set<Int>
    var rowCount: Int
  }

  /// How one key column's file value is bound and compared with the table's value. A write
  /// matches the same row with `equals(target, value(placeholder))` and `bindText`.
  struct KeyColumn: Sendable, Equatable {
    var name: String
    var match: Match

    enum Match: Sendable, Equatable {
      case plain
      /// PostgreSQL / DuckDB: the bind cast to this type
      case cast(String)
      /// MySQL utf8mb4 string
      case collate(String)
      /// MySQL string in another character set
      case convert(characterSet: String, collation: String)
      case signed
      case unsigned
      case decimal(precision: Int, scale: Int)
      /// MySQL FLOAT / DOUBLE: compared as is, the text must be a finite number
      case float
    }

    /// The bind for a non-NULL key value, or why its row is refused
    enum Bind: Sendable, Equatable {
      case text(String)
      case refused(String)
    }

    init(_ column: TableStructure.Column, dialect: SQLDialect) throws {
      name = column.name
      switch dialect {
      case .postgresql, .duckdb:
        guard let type = Self.castType(column.dataType, dialect: dialect) else {
          throw Error.unsupportedKey(
            column: column.name, reason: "its type can't be written as SQL.")
        }
        match = .cast(type)
      case .mysql:
        match = try Self.mysqlMatch(column)
      default:
        match = .plain
      }
    }

    /// The key value in the key rows: the placeholder, cast on PostgreSQL / DuckDB
    func value(_ placeholder: String) -> String {
      if case .cast(let type) = match { return "CAST(\(placeholder) AS \(type))" }
      return placeholder
    }

    /// `target = value`, with the MySQL collation or numeric cast on `value`
    func equals(_ target: String, _ value: String) -> String {
      switch match {
      case .plain, .cast, .float: "\(target) = \(value)"
      case .collate(let collation): "\(target) = \(value) COLLATE \(collation)"
      case .convert(let characterSet, let collation):
        "\(target) = CONVERT(\(value) USING \(characterSet)) COLLATE \(collation)"
      case .signed: "\(target) = CAST(\(value) AS SIGNED)"
      case .unsigned: "\(target) = CAST(\(value) AS UNSIGNED)"
      case .decimal(let precision, let scale):
        "\(target) = CAST(\(value) AS DECIMAL(\(precision),\(scale)))"
      }
    }

    /// The text bound for `value` (normalized, not NULL): numbers trimmed, never through Double
    func bindText(_ value: String) -> Bind {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      switch match {
      case .plain, .cast, .collate:
        return .text(value)
      case .convert(let characterSet, _):
        return ImportMatchPlanner.canRepresent(value, in: characterSet) == true
          ? .text(value)
          : .refused("The \(name) value can't be stored in character set \(characterSet).")
      case .signed:
        return Int64(trimmed) != nil
          ? .text(trimmed) : .refused("The \(name) value is not a whole number in range.")
      case .unsigned:
        return UInt64(trimmed) != nil
          ? .text(trimmed) : .refused("The \(name) value is not a whole number in range.")
      case .decimal(let precision, let scale):
        return Self.fitsDecimal(trimmed, precision: precision, scale: scale)
          ? .text(trimmed)
          : .refused("The \(name) value is not a DECIMAL(\(precision),\(scale)) number.")
      case .float:
        let isNumber =
          !trimmed.isEmpty && trimmed.allSatisfy { "0123456789+-.eE".contains($0) }
          && Double(trimmed)?.isFinite == true
        return isNumber ? .text(trimmed) : .refused("The \(name) value is not a number.")
      }
    }

    /// The type a PostgreSQL / DuckDB key bind is cast to, or nil when the catalog text holds
    /// anything but letters, digits, spaces, `_ ( ) , . [ ]` and paired `"`
    private static func castType(_ dataType: String, dialect: SQLDialect) -> String? {
      let type = dataType.trimmingCharacters(in: .whitespaces)
      let punctuation = Set("_(),.[]\" ".unicodeScalars)
      guard !type.isEmpty,
        type.unicodeScalars.allSatisfy({
          $0.properties.isAlphabetic || ("0"..."9").contains($0) || punctuation.contains($0)
        }),
        type.filter({ $0 == "\"" }).count.isMultiple(of: 2)
      else { return nil }
      guard dialect == .postgresql else { return type }
      // Type modifiers are outside quoted names: the even parts between `"`
      let parts = type.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
      let unmodified = parts.map { offset, part in
        offset.isMultiple(of: 2)
          ? part.replacingOccurrences(
            of: #"\s*\(\s*-?\d+\s*(,\s*-?\d+\s*)?\)"#, with: "", options: .regularExpression)
          : String(part)
      }.joined(separator: "\"")
      var base = Substring(unmodified)
      var arrays = ""
      while base.hasSuffix("[]") {
        base = base.dropLast(2)
        arrays += "[]"
      }
      switch base {
      case "character": return "bpchar" + arrays
      case "bit": return "varbit" + arrays
      default: return unmodified
      }
    }

    private static func mysqlMatch(_ column: TableStructure.Column) throws -> Match {
      if let characterSet = column.characterSet {
        guard let collation = column.collation, isPlainName(characterSet),
          isPlainName(collation)
        else {
          throw Error.unsupportedKey(
            column: column.name, reason: "its character set or collation name is not usable.")
        }
        guard ImportMatchPlanner.canRepresent("", in: characterSet) != nil else {
          throw Error.unsupportedKey(
            column: column.name,
            reason: "matching on character set \(characterSet) is not supported.")
        }
        return characterSet.lowercased() == "utf8mb4"
          ? .collate(collation) : .convert(characterSet: characterSet, collation: collation)
      }
      let type = (column.columnType ?? column.dataType).lowercased()
      switch type.prefix(while: \.isLetter) {
      case "tinyint", "smallint", "mediumint", "int", "integer", "bigint":
        return type.contains("unsigned") ? .unsigned : .signed
      case "decimal", "numeric", "dec", "fixed":
        guard
          let match = type.firstMatch(of: /\((\d{1,2})(?:\s*,\s*(\d{1,2}))?\)/),
          let precision = Int(match.1)
        else { return .decimal(precision: 10, scale: 0) }
        return .decimal(precision: precision, scale: match.2.flatMap { Int($0) } ?? 0)
      case "float", "double", "real":
        return .float
      default:
        return .plain
      }
    }

    /// `^[A-Za-z0-9_]+$`
    private static func isPlainName(_ name: String) -> Bool {
      !name.isEmpty
        && name.unicodeScalars.allSatisfy {
          $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "_")
        }
    }

    /// Plain decimal text whose value DECIMAL(precision, scale) holds without rounding
    private static func fitsDecimal(_ text: String, precision: Int, scale: Int) -> Bool {
      let unsigned = text.first.map { "+-".contains($0) } == true ? text.dropFirst() : text[...]
      let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
      guard (1...2).contains(parts.count), parts.joined().count > 0,
        parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } })
      else { return false }
      let whole = parts[0].drop(while: { $0 == "0" })
      var fraction = parts.count == 2 ? parts[1][...] : ""
      while fraction.last == "0" { fraction = fraction.dropLast() }
      return whole.count <= precision - scale && fraction.count <= scale
    }
  }

  /// The reads for `rows` (values in `columns` order) matched on `keyColumns` of
  /// `schema.table`. `rows` hold the import's bind text; blank values are NULL.
  static func plan(
    schema: String?, table: String, keyColumns: [String], columns: [String], rows: [[String?]],
    structure: TableStructure, dialect: SQLDialect, bindLimit: Int? = nil
  ) throws -> Plan {
    guard !keyColumns.isEmpty else { throw Error.noKey }
    let keys = try keyColumns.map { name in
      guard let index = columns.firstIndex(of: name) else { throw Error.keyNotMapped(name) }
      guard let column = structure.columns.first(where: { $0.name == name }) else {
        throw Error.unknownColumn(name)
      }
      return (index: index, key: try KeyColumn(column, dialect: dialect))
    }
    let chunkSize = min(
      maxRowsPerRead, (bindLimit ?? ImportSQLBuilder.defaultBindLimit(dialect)) / keys.count)
    guard chunkSize > 0 else { throw Error.bindLimitExceeded }
    let relation = try dialect.qualified(schema: schema, name: table)
    let condition = try keys.enumerated().map { offset, entry in
      entry.key.equals(
        "t." + (try dialect.quoteIdentifier(entry.key.name)),
        keyAlias(offset, dialect: dialect))
    }.joined(separator: " AND ")

    var plan = Plan(reads: [], refusals: [:], nullKeyRows: [], rowCount: rows.count)
    var chunk: [(position: Int, binds: [String])] = []
    func flush() throws {
      guard !chunk.isEmpty else { return }
      plan.reads.append(
        try read(
          chunk, keys: keys.map(\.key), relation: relation, condition: condition,
          dialect: dialect))
      chunk = []
    }
    for (position, row) in rows.enumerated() {
      if position.isMultiple(of: 256) { try Task.checkCancellation() }
      guard row.count == columns.count else { throw Error.invalidRowWidth }
      let values = keys.map { ImportTypeInference.normalizedValue(row[$0.index]) }
      guard !values.contains(nil) else {
        plan.nullKeyRows.insert(position)
        continue
      }
      var binds: [String] = []
      for (value, entry) in zip(values, keys) {
        switch entry.key.bindText(value ?? "") {
        case .text(let text): binds.append(text)
        case .refused(let reason): plan.refusals[position] = plan.refusals[position] ?? reason
        }
      }
      guard plan.refusals[position] == nil else { continue }
      if chunk.count == chunkSize { try flush() }
      chunk.append((position, binds))
    }
    try flush()
    return plan
  }

  /// `outcome(matches:mode:)` for every row of `plan`, with `counts` by row position from its
  /// reads (a position a read did not return counts 0; a NULL-key row always does)
  static func outcomes(_ plan: Plan, counts: [Int: Int], mode: ImportMode) -> [Outcome] {
    (0..<plan.rowCount).map { row in
      if let reason = plan.refusals[row] { return .refused(reason) }
      return outcome(matches: plan.nullKeyRows.contains(row) ? 0 : counts[row] ?? 0, mode: mode)
    }
  }

  /// 0: insert (Update skips); 1: update (Update, Insert or Update), skip (Insert skipping
  /// existing) or refused (Insert); more: refused, the key does not name one row
  static func outcome(matches: Int, mode: ImportMode) -> Outcome {
    guard matches <= 1 else { return .refused("\(matches) rows in the table match this key.") }
    switch (mode, matches == 1) {
    case (.update, false): return .skip
    case (_, false): return .insert
    case (.insert, true): return .refused("A row with this key already exists in the table.")
    case (.update, true), (.insertOrUpdate, true): return .update
    case (.insertSkippingExisting, true): return .skip
    }
  }

  /// Counts by row position from a read's `(position, count)` rows
  static func counts(_ rows: [[CellValue]]) -> [Int: Int] {
    var counts: [Int: Int] = [:]
    for row in rows where row.count >= 2 {
      guard let position = integer(row[0]), let count = integer(row[1]) else { continue }
      counts[position, default: 0] += count
    }
    return counts
  }

  private static func integer(_ value: CellValue) -> Int? {
    switch value {
    case .int(let number): number
    case .string(let text): Int(text)
    default: nil
    }
  }

  /// `v.k<n>`; SQLite names VALUES columns `column1`, `column2`, ... (the position is first)
  private static func keyAlias(_ offset: Int, dialect: SQLDialect) -> String {
    dialect == .sqlite ? "v.column\(offset + 2)" : "v.k\(offset)"
  }

  private static func read(
    _ chunk: [(position: Int, binds: [String])], keys: [KeyColumn], relation: String,
    condition: String, dialect: SQLDialect
  ) throws -> BoundStatement {
    var placeholder = 0
    func next(_ key: KeyColumn) -> String {
      placeholder += 1
      return key.value(dialect.placeholder(placeholder))
    }
    let position: String
    let source: String
    switch dialect {
    case .mysql:
      position = "v.pos"
      source =
        chunk.enumerated().map { offset, row in
          let values = keys.enumerated().map { index, key in
            offset == 0 ? "\(next(key)) AS k\(index)" : next(key)
          }
          return "SELECT \(row.position)\(offset == 0 ? " AS pos" : ""), "
            + values.joined(separator: ", ")
        }.joined(separator: " UNION ALL ") + ") AS v"
    default:
      let names = (0..<keys.count).map { "k\($0)" }.joined(separator: ", ")
      position = dialect == .sqlite ? "v.column1" : "v.pos"
      source =
        "VALUES "
        + chunk.map { row in
          "(\(row.position), " + keys.map(next).joined(separator: ", ") + ")"
        }.joined(separator: ", ") + ") AS v" + (dialect == .sqlite ? "" : "(pos, \(names))")
    }
    let sql =
      "SELECT \(position), COUNT(*) FROM (\(source) JOIN \(relation) AS t ON \(condition) "
      + "GROUP BY \(position)"
    let classified: [ClassifiedStatement]
    do {
      classified = try ReadOnlyQueryGuard.check(sql, dialect: dialect)
    } catch let refusal as ReadOnlyQueryGuard.Refusal {
      throw Error.readRefused(refusal)
    }
    return BoundStatement(
      sql: sql, values: chunk.flatMap(\.binds), expectedRows: nil,
      classified: classified.first)
  }

  /// Whether `characterSet` holds every character of `value`; nil for a character set the
  /// planner does not know (MySQL `latin1` is cp1252; `utf8mb3` / `ucs2` hold the BMP only)
  fileprivate static func canRepresent(_ value: String, in characterSet: String) -> Bool? {
    switch characterSet.lowercased() {
    case "utf8mb4", "utf16", "utf16le", "utf32": true
    case "utf8mb3", "utf8", "ucs2": value.unicodeScalars.allSatisfy { $0.value <= 0xFFFF }
    case "ascii": value.unicodeScalars.allSatisfy(\.isASCII)
    case "latin1": value.canBeConverted(to: .windowsCP1252)
    default: nil
    }
  }
}
