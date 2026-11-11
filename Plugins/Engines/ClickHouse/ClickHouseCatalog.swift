// ClickHouseCatalog.swift
// Catalog reads of the ClickHouse engine, from system.tables and system.columns: databases are
// the schemas (system, INFORMATION_SCHEMA and information_schema left out), View and
// MaterializedView tables are the views, and there are no foreign keys. Rows are never edited
// (`editTable` answers null). Functions, procedures, triggers, users, roles, definitions and
// type enrichment answer `unsupported`, which the app reads as empty.
//
// Names from the app go in as `{name:String}` parameters, never into the SQL text; only the
// row count quotes them, as backtick identifiers with backslash escapes.

import Foundation

struct ClickHouseCatalog {
  /// Databases that are not the user's
  static let hiddenDatabases = "('system', 'INFORMATION_SCHEMA', 'information_schema')"
  static let viewEngines = "('View', 'MaterializedView')"

  let connection: ClickHouseConnection

  func read(_ request: EngineRequest.Catalog) throws -> EngineCatalogResult {
    switch request.read {
    case .tables: return .tables(try tables())
    case .views: return .views(try views())
    case .allColumns: return .allColumns(try allColumns())
    case .foreignKeys: return .foreignKeys([])
    case .editTable: return .editTable(nil)
    case .primaryKey:
      let (database, table) = try Self.qualifiedName(request.args)
      return .primaryKey(try primaryKey(database: database, table: table).compactMap(\.column))
    case .rowCount:
      return .rowCount(
        try rowCount(
          database: try Self.string(request.args, "schema"),
          table: try Self.string(request.args, "table")))
    case .tableStructure:
      return .tableStructure(
        try tableStructure(
          database: try Self.string(request.args, "schema"),
          table: try Self.string(request.args, "table")))
    default:
      throw EngineFailure(
        code: .unsupported, message: "This catalog read is not supported by ClickHouse.")
    }
  }

  // MARK: Reads

  private func tables() throws -> [EngineCatalog.Table] {
    try connection.rows(
      """
      SELECT database, name, total_rows FROM system.tables
      WHERE database NOT IN \(Self.hiddenDatabases) AND engine NOT IN \(Self.viewEngines)
        AND NOT is_temporary
      ORDER BY database, name
      """
    ).compactMap { row in
      guard let database = Self.text(row, 0), let name = Self.text(row, 1) else { return nil }
      return EngineCatalog.Table(schema: database, name: name, rowCount: Self.int(row, 2))
    }
  }

  private func views() throws -> [EngineCatalog.View] {
    try connection.rows(
      """
      SELECT database, name, as_select FROM system.tables
      WHERE database NOT IN \(Self.hiddenDatabases) AND engine IN \(Self.viewEngines)
      ORDER BY database, name
      """
    ).compactMap { row in
      guard let database = Self.text(row, 0), let name = Self.text(row, 1) else { return nil }
      let definition = Self.text(row, 2)
      return EngineCatalog.View(
        schema: database, name: name, definition: definition?.isEmpty == false ? definition : nil)
    }
  }

  /// `{"database.table": [Column]}` for every table and view
  private func allColumns() throws -> [String: [EngineCatalog.Column]] {
    let rows = try connection.rows(
      """
      SELECT database, table, name, type, is_in_primary_key, default_kind FROM system.columns
      WHERE database NOT IN \(Self.hiddenDatabases) AND database != ''
      ORDER BY database, table, position
      """)
    var relations: [String: [EngineCatalog.Column]] = [:]
    for row in rows {
      guard let database = Self.text(row, 0), let table = Self.text(row, 1),
        let name = Self.text(row, 2), let type = Self.text(row, 3)
      else { continue }
      let kind = Self.text(row, 5) ?? ""
      relations["\(database).\(table)", default: []].append(
        EngineCatalog.Column(
          name: name, type: type, isNullable: ClickHouseFormat.isNullable(type),
          isPrimaryKey: Self.int(row, 4) == 1,
          isGenerated: kind == "MATERIALIZED" || kind == "ALIAS"))
    }
    return relations
  }

  /// The primary key's parts in key order: a column name, or an expression's text
  private func primaryKey(database: String?, table: String) throws -> [EngineCatalog.IndexKey] {
    let key: String?
    if let database {
      key = try connection.rows(
        "SELECT primary_key FROM system.tables WHERE database = {db:String} AND name = {t:String}",
        parameters: ["db": database, "t": table]
      ).first.flatMap { Self.text($0, 0) }
    } else {
      key = try connection.rows(
        "SELECT primary_key FROM system.tables WHERE database = currentDatabase() AND name = {t:String}",
        parameters: ["t": table]
      ).first.flatMap { Self.text($0, 0) }
    }
    return Self.keyParts(key ?? "").map { part in
      Self.isPlainName(part)
        ? EngineCatalog.IndexKey(column: Self.unquoted(part))
        : EngineCatalog.IndexKey(expression: part)
    }
  }

  /// `count()`: exact
  private func rowCount(database: String, table: String) throws -> Int {
    let rows = try connection.rows(
      "SELECT count() FROM \(Self.quoted(database)).\(Self.quoted(table))")
    guard let count = rows.first.flatMap({ Self.int($0, 0) }) else {
      throw EngineFailure(code: .query, message: "The server did not report the row count.")
    }
    return count
  }

  private func tableStructure(
    database: String, table: String
  ) throws
    -> EngineCatalog.TableStructure
  {
    let parameters = ["db": database, "t": table]
    let columns = try connection.rows(
      """
      SELECT name, type, default_kind, default_expression, comment FROM system.columns
      WHERE database = {db:String} AND table = {t:String}
      ORDER BY position
      """, parameters: parameters
    ).compactMap { row -> EngineCatalog.StructureColumn? in
      guard let name = Self.text(row, 0), let type = Self.text(row, 1) else { return nil }
      let kind = Self.text(row, 2) ?? ""
      let expression = Self.text(row, 3).flatMap { $0.isEmpty ? nil : $0 }
      let comment = Self.text(row, 4).flatMap { $0.isEmpty ? nil : $0 }
      var column = EngineCatalog.StructureColumn(
        name: name, dataType: type, isNullable: ClickHouseFormat.isNullable(type), comment: comment)
      switch kind {
      case "DEFAULT": column.defaultExpression = expression
      case "MATERIALIZED": column.generated = .init(expression: expression, isStored: true)
      case "ALIAS": column.generated = .init(expression: expression, isStored: false)
      default: break
      }
      return column
    }
    guard !columns.isEmpty else {
      throw EngineFailure(code: .query, message: "The table \(database).\(table) was not found.")
    }
    let comment = try connection.rows(
      "SELECT comment FROM system.tables WHERE database = {db:String} AND name = {t:String}",
      parameters: parameters
    ).first.flatMap { Self.text($0, 0) }
    // The primary key orders the data and is not unique
    let key = try primaryKey(database: database, table: table)
    let indexes =
      key.isEmpty
      ? [] : [EngineCatalog.Index(name: "PRIMARY", keys: key, isUnique: false, isPrimary: true)]
    return EngineCatalog.TableStructure(
      schema: database, name: table, comment: comment?.isEmpty == false ? comment : nil,
      columns: columns, indexes: indexes, constraints: [])
  }

  // MARK: Helpers

  private static func string(_ args: [String: EngineJSONValue], _ key: String) throws -> String {
    guard case .string(let value)? = args[key], !value.isEmpty else {
      throw EngineFailure(code: .invalid, message: "The catalog request has no \(key).")
    }
    return value
  }

  /// `name` as `table` (the current database) or `database.table`
  private static func qualifiedName(_ args: [String: EngineJSONValue]) throws -> (String?, String) {
    let name = try string(args, "name")
    guard let dot = name.firstIndex(of: "."), dot != name.startIndex,
      name.index(after: dot) != name.endIndex
    else { return (nil, name) }
    return (String(name[..<dot]), String(name[name.index(after: dot)...]))
  }

  /// A backtick identifier: every backslash and backtick scalar escaped. Per Unicode scalar,
  /// never per Character: a backtick followed by a combining scalar is one Character that String
  /// matching would skip, while the server still reads the backtick.
  static func quoted(_ name: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in name.unicodeScalars {
      if scalar == "\\" || scalar == "`" { out.append("\\") }
      out.append(scalar)
    }
    return "`" + String(out) + "`"
  }

  /// The comma-separated parts of a key expression, commas inside brackets or quotes kept
  static func keyParts(_ key: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    var quote: Character?
    var escaped = false
    for character in key {
      if let open = quote {
        current.append(character)
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == open {
          quote = nil
        }
        continue
      }
      switch character {
      case "'", "`", "\"":
        quote = character
        current.append(character)
      case "(", "[":
        depth += 1
        current.append(character)
      case ")", "]":
        depth -= 1
        current.append(character)
      case "," where depth == 0:
        parts.append(current)
        current = ""
      default: current.append(character)
      }
    }
    parts.append(current)
    return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  /// A bare or backtick-quoted identifier, not an expression
  private static func isPlainName(_ part: String) -> Bool {
    if part.hasPrefix("`") && part.hasSuffix("`") && part.count >= 2 { return true }
    return part.range(of: #"\A[A-Za-z_][A-Za-z0-9_.]*\z"#, options: .regularExpression) != nil
  }

  private static func unquoted(_ part: String) -> String {
    guard part.hasPrefix("`") && part.hasSuffix("`") && part.count >= 2 else { return part }
    var name = ""
    var escaped = false
    for character in part.dropFirst().dropLast() {
      if escaped {
        name.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else {
        name.append(character)
      }
    }
    return name
  }

  private static func text(_ row: [EngineCell], _ index: Int) -> String? {
    guard index < row.count else { return nil }
    switch row[index] {
    case .text(let text), .decimal(let text), .json(let text), .date(let text): return text
    case .int(let value): return String(value)
    default: return nil
    }
  }

  private static func int(_ row: [EngineCell], _ index: Int) -> Int? {
    guard index < row.count else { return nil }
    switch row[index] {
    case .int(let value): return value
    case .bool(let value): return value ? 1 : 0
    default: return nil
    }
  }
}
