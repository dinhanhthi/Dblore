// SQLDialect.swift
// Quote, literal, and statement-fragment rules for PostgreSQL, SQLite, DuckDB, and MySQL,
// plus the MongoDB marker: no SQL identifiers, every other member PostgreSQL-shaped.

import Foundation

/// Identifier quoting failed.
nonisolated enum SQLDialectError: Error, Equatable, Sendable {
  /// `name` contains a NUL (`U+0000`) and cannot be placed in SQL text.
  case nulInIdentifier
  /// The dialect is `SQLDialect.mongodb`, which has no SQL identifiers.
  case notSQL
}

/// How one database spells identifiers, literals, and a few statement fragments.
/// `mongodb` is a marker, not a SQL dialect: the text entry points (classifier, splitter,
/// tokenizer, parameter rewriter) delegate to the mongosh code, `quoteIdentifier` and
/// `qualified` throw `notSQL`, and the other members return the PostgreSQL value without the
/// `pg_catalog` qualification; capability guards keep those SQL paths unreachable for MongoDB.
nonisolated struct SQLDialect: Sendable, Equatable {
  private enum Engine: Sendable, Equatable {
    case postgresql
    case sqlite
    case duckdb
    case mysql
    case mongodb
  }

  private let engine: Engine

  static let postgresql = SQLDialect(engine: .postgresql)
  static let sqlite = SQLDialect(engine: .sqlite)
  static let duckdb = SQLDialect(engine: .duckdb)
  static let mysql = SQLDialect(engine: .mysql)
  static let mongodb = SQLDialect(engine: .mongodb)

  /// Name used in prompts ("PostgreSQL", "SQLite", "DuckDB", "MySQL").
  var promptName: String {
    switch engine {
    case .postgresql, .mongodb: "PostgreSQL"
    case .sqlite: "SQLite"
    case .duckdb: "DuckDB"
    case .mysql: "MySQL"
    }
  }

  /// Schema omitted by `qualified` when the caller passes it explicitly (PostgreSQL keeps it).
  /// MySQL has none: its schema is the connected database, so any named schema stays.
  var defaultSchema: String {
    switch engine {
    case .postgresql, .mongodb: "public"
    case .sqlite, .duckdb: "main"
    case .mysql: ""
    }
  }

  /// Whether `UPDATE ONLY` is meaningful (PostgreSQL inheritance).
  var supportsUpdateOnly: Bool {
    switch engine {
    case .postgresql, .mongodb: true
    case .sqlite, .duckdb, .mysql: false
    }
  }

  /// Whether `UPDATE ... SET c = DEFAULT` is valid (PostgreSQL `UPDATE`, MySQL `UPDATE` docs).
  /// SQLite and MongoDB have none; DuckDB grid edits stay off (`supportsRowStaging`).
  var supportsDefaultInUpdate: Bool {
    switch engine {
    case .postgresql, .mysql: true
    case .sqlite, .duckdb, .mongodb: false
    }
  }

  /// SQLite and MySQL (default `_ci` collations) `LIKE` fold case, and neither has `ILIKE`.
  /// PostgreSQL and DuckDB `LIKE` do not (`ILIKE` does).
  var likeIsCaseInsensitive: Bool {
    switch engine {
    case .sqlite, .mysql: true
    case .postgresql, .duckdb, .mongodb: false
    }
  }

  /// `"name"` with embedded `"` doubled; MySQL `` `name` `` with embedded `` ` `` doubled.
  /// Rejects a NUL anywhere in `name`, and every name on MongoDB (`notSQL`).
  func quoteIdentifier(_ name: String) throws -> String {
    let quote: Unicode.Scalar
    switch engine {
    case .postgresql, .sqlite, .duckdb: quote = "\""
    case .mysql: quote = "`"
    case .mongodb: throw SQLDialectError.notSQL
    }
    guard !name.unicodeScalars.contains("\0") else {
      throw SQLDialectError.nulInIdentifier
    }
    let quoteText = String(quote)
    return quoteText + Self.escapingScalars(name, [quote: quoteText + quoteText]) + quoteText
  }

  /// `name` bare when it is a plain lowercase identifier (`[a-z_][a-z0-9_]*`) and no reserved
  /// word, else `quoteIdentifier(name)`. A bare name reads the same as the quoted one on every
  /// engine (PostgreSQL folds an unquoted name to lower case, and it is already lower case).
  /// Only safe for the column part of a qualified name (`alias.column`): the reserved words
  /// below are not every engine's, and most of them are fine after a dot.
  func quoteIdentifierIfNeeded(_ name: String) throws -> String {
    if case .mongodb = engine { throw SQLDialectError.notSQL }
    let isPlain = name.utf8.enumerated().allSatisfy { offset, byte in
      byte == UInt8(ascii: "_") || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
        || (offset > 0 && byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }
    guard isPlain, !name.isEmpty, !Self.reservedWords.contains(name) else {
      return try quoteIdentifier(name)
    }
    return name
  }

  /// Words a bare identifier may not be in some engine (the SQL standard's and PostgreSQL's
  /// reserved words, common MySQL 8 ones, many of them often a column's name, and SQLite
  /// keywords it does not take as a name after a dot)
  private static let reservedWords: Set<String> = [
    "add", "all", "alter", "analyse", "analyze", "and", "any", "array", "as", "asc",
    "asymmetric", "authorization", "autoincrement", "between", "binary", "both", "by", "case",
    "cast", "check", "collate",
    "collation", "column", "commit", "condition", "constraint", "create", "cross",
    "current_catalog",
    "current_date", "current_role", "current_schema", "current_time", "current_timestamp",
    "current_user", "database", "default", "deferrable", "delete", "desc", "describe",
    "distinct", "div", "do", "drop", "else", "end", "escape", "except", "exists", "explain",
    "false",
    "fetch", "for", "foreign", "freeze", "from", "full", "glob", "grant", "group", "groups",
    "having",
    "ilike", "in", "index", "indexed", "initially", "inner", "insert", "intersect", "interval",
    "into",
    "is", "isnull", "join", "key", "keys", "lag", "lateral", "lead", "leading", "left", "like",
    "limit", "load", "localtime", "localtimestamp", "lock", "match", "mod", "natural", "not",
    "nothing", "notnull", "null", "offset", "on", "only", "or", "order", "outer", "over",
    "overlaps",
    "partition", "placing", "primary", "procedure", "range", "rank", "read", "references",
    "regexp", "rename", "replace", "returning", "right", "row", "rows", "schema", "select",
    "session_user", "set", "show", "similar", "some", "symmetric", "system", "system_user",
    "table", "tablesample", "then", "to", "trailing", "transaction", "trigger", "true", "union",
    "unique",
    "update", "usage", "use", "user", "using", "values", "variadic", "verbose", "when", "where",
    "window", "with", "write",
  ]

  /// `text` with each scalar in `map` replaced by its text. Walks scalars, not `Character`s: a
  /// quote followed by a combining mark is one `Character` that is not equal to the bare quote.
  static func escapingScalars(_ text: String, _ map: [Unicode.Scalar: String]) -> String {
    var escaped = ""
    for scalar in text.unicodeScalars {
      if let replacement = map[scalar] {
        escaped += replacement
      } else {
        escaped.unicodeScalars.append(scalar)
      }
    }
    return escaped
  }

  /// Text for a `--` comment, in every dialect: each line break (which would end the comment
  /// and turn the rest, e.g. of a quoted identifier, into live SQL) becomes a visible escape
  static func lineCommentSafe(_ text: String) -> String {
    var safe = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\n": safe += "\\n"
      case "\r": safe += "\\r"
      case "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}":
        safe += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
      default: safe.unicodeScalars.append(scalar)
      }
    }
    return safe
  }

  /// `quoteIdentifier(name)` for a nil schema, else `schema.name`. Other dialects drop their
  /// default schema; PostgreSQL keeps every schema, `public` too, so an app-run statement never
  /// resolves a default-schema relation through the user's `search_path`.
  func qualified(schema: String?, name: String) throws -> String {
    let quotedName = try quoteIdentifier(name)
    guard let schema, engine == .postgresql || schema != defaultSchema else {
      return quotedName
    }
    return try quoteIdentifier(schema) + "." + quotedName
  }

  /// SQL literal for a result cell. JSON is quoted text, not a PostgreSQL json cast. A date
  /// is zoned (`literal(_:wallClock: false)`).
  func literal(_ value: CellValue) -> String {
    literal(value, wallClock: false)
  }

  /// SQL literal for a cell of a column whose `ColumnInfo.wallClock` is `wallClock`. A naive
  /// date is its stored wall clock (`CellValue.outputString(wallClock: true)`); a zoned date is
  /// its bind text (`DateBindText`: UTC with six fractional digits, MySQL without a zone).
  func literal(_ value: CellValue, wallClock: Bool) -> String {
    switch value {
    case .null:
      "NULL"
    case .bool(let flag):
      flag ? "TRUE" : "FALSE"
    case .int(let number):
      String(number)
    case .double(let number):
      doubleLiteral(number)
    case .string(let text), .json(let text):
      quoteLiteral(text)
    case .decimal(let text):
      // Bare only as plain digits; NaN, Infinity and any other text are a quoted string
      DecimalText.isPlain(text) ? text : quoteLiteral(text)
    case .date(let date):
      quoteLiteral(
        wallClock
          ? value.outputString(wallClock: true) : DateBindText.string(from: date, dialect: self))
    case .data(let data):
      dataLiteral(data)
    }
  }

  /// PostgreSQL and DuckDB `$n`, SQLite `?n`. `index` is written as given (1-based).
  /// MySQL is a bare `?`: binds are positional, so `index` is ignored.
  func placeholder(_ index: Int) -> String {
    switch engine {
    case .postgresql, .duckdb, .mongodb: "$\(index)"
    case .sqlite: "?\(index)"
    case .mysql: "?"
    }
  }

  func limitOffset(limit: Int, offset: Int) -> String {
    "LIMIT \(limit) OFFSET \(offset)"
  }

  /// PostgreSQL `EXPLAIN` with optional ANALYZE, BUFFERS, and FORMAT.
  /// SQLite is always `EXPLAIN QUERY PLAN`. DuckDB is `EXPLAIN (FORMAT <format>)` or
  /// `EXPLAIN (ANALYZE, FORMAT <format>)` (the plan view reads JSON), and `EXPLAIN` or
  /// `EXPLAIN ANALYZE` (text) without a format, with `buffers` ignored. MySQL is
  /// `EXPLAIN ANALYZE` (format ignored), `EXPLAIN FORMAT=<format>`, or `EXPLAIN`, with `buffers`
  /// ignored.
  func explainPrefix(analyze: Bool, buffers: Bool, format: String?) -> String {
    switch engine {
    case .sqlite:
      return "EXPLAIN QUERY PLAN"
    case .duckdb:
      guard let format else { return analyze ? "EXPLAIN ANALYZE" : "EXPLAIN" }
      let options = (analyze ? ["ANALYZE"] : []) + ["FORMAT \(format.uppercased())"]
      return "EXPLAIN (\(options.joined(separator: ", ")))"
    case .mysql:
      if analyze { return "EXPLAIN ANALYZE" }
      if let format { return "EXPLAIN FORMAT=\(format.uppercased())" }
      return "EXPLAIN"
    case .postgresql, .mongodb:
      var options: [String] = []
      if analyze { options.append("ANALYZE") }
      if buffers { options.append("BUFFERS") }
      if let format { options.append("FORMAT \(format.uppercased())") }
      if options.isEmpty {
        return "EXPLAIN"
      }
      return "EXPLAIN (\(options.joined(separator: ", ")))"
    }
  }

  /// `column` as text for `LIKE`: PostgreSQL `::text`, DuckDB `::VARCHAR`, MySQL `CAST(.. AS CHAR)`,
  /// SQLite unchanged.
  func likeSubject(_ column: String) -> String {
    switch engine {
    case .postgresql, .mongodb: "\(column)::text"
    case .sqlite: column
    case .duckdb: "\(column)::VARCHAR"
    case .mysql: "CAST(\(column) AS CHAR)"
    }
  }

  /// `column`, `pattern` and `escape` are SQL fragments, inserted unchanged; `escape` follows
  /// the comparison as `ESCAPE escape`. SQLite and MySQL lower both sides (a MySQL `_bin`
  /// collation makes `LIKE` case-sensitive), the form Find a Value in Every Table searches with.
  func caseInsensitiveLike(column: String, pattern: String, escape: String? = nil) -> String {
    let comparison =
      switch engine {
      case .postgresql, .mongodb: "\(column)::text ILIKE \(pattern)"
      case .sqlite: "LOWER(\(column)) LIKE LOWER(\(pattern))"
      case .duckdb: "\(column)::VARCHAR ILIKE \(pattern)"
      case .mysql: "LOWER(CAST(\(column) AS CHAR)) LIKE LOWER(\(pattern))"
      }
    return escape.map { "\(comparison) ESCAPE \($0)" } ?? comparison
  }

  // MARK: - PostgreSQL qualification
  // On `.postgresql` these name `pg_catalog`'s operators, functions and built-in types, so a
  // statement on user data never runs an object planted in a schema on the `search_path`. Every
  // other dialect (MongoDB too) gets the unqualified text the builders write today.

  /// `lhs op rhs`; PostgreSQL `lhs OPERATOR(pg_catalog.op) rhs` unless `operand` is `.bare`
  func comparison(
    _ lhs: String, _ op: SQLComparison, _ rhs: String, operand: SQLOperandKind = .qualified
  ) -> String {
    guard engine == .postgresql, operand == .qualified else {
      return "\(lhs) \(op.rawValue) \(rhs)"
    }
    return "\(lhs) OPERATOR(pg_catalog.\(op.rawValue)) \(rhs)"
  }

  /// `column [NOT] IN (items)`. PostgreSQL has no qualified `IN`: an OR chain of `=` (an AND
  /// chain of `<>` when `negated`) in parentheses; never `= ANY (ARRAY[...])`, whose quoted items
  /// would make a `text[]`. `items` are SQL fragments, at least one.
  func inList(
    _ column: String, _ items: [String], negated: Bool = false,
    operand: SQLOperandKind = .qualified
  ) -> String {
    guard engine == .postgresql else {
      return "\(column) \(negated ? "NOT " : "")IN (\(items.joined(separator: ", ")))"
    }
    let terms = items.map {
      comparison(column, negated ? .notEqual : .equal, $0, operand: operand)
    }
    return "(" + terms.joined(separator: negated ? " AND " : " OR ") + ")"
  }

  /// `column [NOT] LIKE pattern [ESCAPE escape]`, case-insensitive (`ILIKE`, or both sides
  /// lowered on SQLite and MySQL) when asked. Fragments are inserted unchanged. PostgreSQL is
  /// `column::pg_catalog.text OPERATOR(pg_catalog.~~)` (`~~*`, `!~~`, `!~~*`), and an escape
  /// becomes `pg_catalog.like_escape(pattern, escape)`: `ESCAPE` only follows the keyword.
  func like(
    column: String, pattern: String, escape: String? = nil, negated: Bool = false,
    caseInsensitive: Bool = false
  ) -> String {
    if engine == .postgresql {
      let op = (negated ? "!~~" : "~~") + (caseInsensitive ? "*" : "")
      let operand = escape.map { function("like_escape", pattern, $0) } ?? pattern
      return "\(cast(column, to: "text")) OPERATOR(pg_catalog.\(op)) \(operand)"
    }
    if caseInsensitive && !negated {
      return caseInsensitiveLike(column: column, pattern: pattern, escape: escape)
    }
    let keyword = caseInsensitive && !likeIsCaseInsensitive ? "ILIKE" : "LIKE"
    let fullPattern = escape.map { "\(pattern) ESCAPE \($0)" } ?? pattern
    return "\(likeSubject(column)) \(negated ? "NOT " : "")\(keyword) \(fullPattern)"
  }

  /// `CAST(expression AS type)`; PostgreSQL `expression::type` with a built-in name that is no
  /// SQL keyword in `pg_catalog` (`text`, `uuid`, `int4`, `"char"`, their arrays). Keyword names
  /// (`integer`, `character varying(20)`, `timestamp with time zone`) are bound by the parser
  /// itself and stay; user and extension types keep the given name.
  func cast(_ expression: String, to type: String) -> String {
    guard engine == .postgresql else { return "CAST(\(expression) AS \(type))" }
    let type = type.trimmingCharacters(in: .whitespaces)
    let parts = TypeName.parts(type)
    let isBuiltIn =
      parts.count == 1
      && (parts[0].quoted
        ? parts[0].name == "char" : TypeName.postgresBuiltIns.contains(parts[0].name))
    return "\(expression)::\(isBuiltIn ? "pg_catalog." : "")\(type)"
  }

  /// `name(arguments)`; PostgreSQL `pg_catalog.name(arguments)`
  func function(_ name: String, _ arguments: String...) -> String {
    "\(engine == .postgresql ? "pg_catalog." : "")\(name)(\(arguments.joined(separator: ", ")))"
  }

  /// Text concatenation: `lhs || rhs`, MySQL `CONCAT(lhs, rhs)`, PostgreSQL
  /// `lhs OPERATOR(pg_catalog.||) rhs`
  func concatenation(_ lhs: String, _ rhs: String) -> String {
    switch engine {
    case .postgresql: "\(lhs) OPERATOR(pg_catalog.||) \(rhs)"
    case .mysql: "CONCAT(\(lhs), \(rhs))"
    case .sqlite, .duckdb, .mongodb: "\(lhs) || \(rhs)"
    }
  }

  /// `'text'`, with `'` doubled. PostgreSQL text that contains `\` is `E'...'`:
  /// every `\` becomes `\\` and every `'` becomes `''`, so those characters stay
  /// data with `standard_conforming_strings` on or off. SQLite and DuckDB never use `E`: their
  /// plain strings have no backslash escapes. MySQL plain strings do: every `\` becomes `\\`
  /// with no prefix.
  private func quoteLiteral(_ text: String) -> String {
    let doubledQuotes = Self.escapingScalars(text, ["'": "''"])
    guard text.unicodeScalars.contains("\\") else {
      return "'\(doubledQuotes)'"
    }
    let escaped = Self.escapingScalars(text, ["'": "''", "\\": "\\\\"])
    switch engine {
    case .postgresql, .mongodb: return "E'\(escaped)'"
    case .mysql: return "'\(escaped)'"
    case .sqlite, .duckdb: return "'\(doubledQuotes)'"
    }
  }

  private func doubleLiteral(_ number: Double) -> String {
    if number.isFinite { return String(number) }
    switch engine {
    case .sqlite, .mysql:
      return "NULL"
    case .postgresql, .mongodb:
      let type = engine == .postgresql ? "pg_catalog.float8" : "float8"
      if number.isNaN { return "'NaN'::\(type)" }
      return number > 0 ? "'Infinity'::\(type)" : "'-Infinity'::\(type)"
    case .duckdb:
      if number.isNaN { return "'NaN'::DOUBLE" }
      return number > 0 ? "'Infinity'::DOUBLE" : "'-Infinity'::DOUBLE"
    }
  }

  private func dataLiteral(_ data: Data) -> String {
    switch engine {
    case .postgresql, .mongodb:
      return "'\\x\(data.hexDigits())'"
    case .sqlite, .mysql:
      return "X'\(data.hexDigits(uppercase: true))'"
    case .duckdb:
      return "'\(data.hexDigits(uppercase: true, bytePrefix: "\\x"))'::BLOB"
    }
  }
}

extension Data {
  /// Two hex digits per byte, each pair after `bytePrefix`. Written straight into the string's
  /// buffer: a multi-megabyte value takes milliseconds, not the seconds of a per-byte
  /// `String(format:)`.
  nonisolated func hexDigits(uppercase: Bool = false, bytePrefix: String = "") -> String {
    let digits: StaticString = uppercase ? "0123456789ABCDEF" : "0123456789abcdef"
    let prefix = Array(bytePrefix.utf8)
    let length = count * (2 + prefix.count)
    return String(unsafeUninitializedCapacity: length) { buffer in
      digits.withUTF8Buffer { table in
        withUnsafeBytes { bytes in
          var index = 0
          for byte in bytes {
            for character in prefix {
              buffer[index] = character
              index += 1
            }
            buffer[index] = table[Int(byte >> 4)]
            buffer[index + 1] = table[Int(byte & 0x0f)]
            index += 2
          }
        }
      }
      return length
    }
  }
}

/// A comparison `SQLDialect.comparison` writes
nonisolated enum SQLComparison: String, Sendable, CaseIterable {
  case equal = "="
  case notEqual = "<>"
  case less = "<"
  case lessOrEqual = "<="
  case greater = ">"
  case greaterOrEqual = ">="
}

/// Whether a PostgreSQL comparison on a column names `pg_catalog`'s operator. Only a fixed list
/// of extension base types (and their arrays) keeps the bare operator, because `pg_catalog` has
/// none for them (a qualified `=` would make a citext filter case-sensitive or fail on PostGIS).
/// Every other type text qualifies: built-ins, arrays, enums, domains, composites, ranges,
/// unknown names and a missing type, so an unlisted extension type fails visibly. A caller that
/// knows a domain's base type passes that instead (the data viewer, from the cached user types).
nonisolated enum SQLOperandKind: Sendable, Equatable {
  case qualified
  case bare

  /// `columnType` is the schema's `format_type` text (`DatabaseColumn.type`), never a result's
  /// `ColumnInfo.type`; the schema prefix, quotes, typmod and `[]` are ignored
  init(columnType: String?) {
    let name = columnType.flatMap { TypeName.parts($0).last?.name }
    self = name.map(Self.extensionTypes.contains) == true ? .bare : .qualified
  }

  private static let extensionTypes: Set<String> = [
    "citext", "geometry", "geography", "hstore", "ltree", "lquery", "ltxtquery", "cube", "isbn",
    "isbn13", "issn", "issn13", "ean13", "ismn", "ismn13", "upc",
  ]
}

/// The parts of a PostgreSQL type text
nonisolated enum TypeName {
  /// The dot-separated name parts before any typmod `(` or `[]`: a quoted part unquoted (`""`
  /// undoubled), an unquoted part trimmed and lowercased as PostgreSQL folds it
  static func parts(_ text: String) -> [(name: String, quoted: Bool)] {
    var parts: [(name: String, quoted: Bool)] = []
    var name = ""
    var quoted = false
    var inQuotes = false
    func finish() {
      parts.append(
        quoted ? (name, true) : (name.trimmingCharacters(in: .whitespaces).lowercased(), false))
    }
    let scalars = Array(text.unicodeScalars)
    var index = 0
    scan: while index < scalars.count {
      let scalar = scalars[index]
      index += 1
      if inQuotes {
        if scalar != "\"" {
          name.unicodeScalars.append(scalar)
        } else if index < scalars.count, scalars[index] == "\"" {
          name += "\""
          index += 1
        } else {
          inQuotes = false
        }
        continue
      }
      switch scalar {
      case "\"":
        inQuotes = true
        quoted = true
      case ".":
        finish()
        name = ""
        quoted = false
      case "(", "[":
        break scan
      default:
        name.unicodeScalars.append(scalar)
      }
    }
    finish()
    return parts
  }

  /// `pg_catalog` type names that are no SQL keyword (`"char"` is matched quoted, apart)
  static let postgresBuiltIns: Set<String> = [
    "text", "date", "uuid", "bytea", "json", "jsonb", "jsonpath", "xml", "int2", "int4", "int8",
    "float4", "float8", "bool", "oid", "tid", "xid", "xid8", "cid", "inet", "cidr", "macaddr",
    "macaddr8", "money", "name", "bpchar", "varbit", "timestamptz", "timetz", "point", "line",
    "lseg", "box", "path", "polygon", "circle", "regclass", "regtype", "regproc", "regprocedure",
    "regoper", "regoperator", "regnamespace", "regrole", "regconfig", "regdictionary",
    "regcollation", "tsvector", "tsquery", "pg_lsn", "pg_snapshot", "txid_snapshot",
    "int4range", "int8range", "numrange", "tsrange", "tstzrange", "daterange", "int4multirange",
    "int8multirange", "nummultirange", "tsmultirange", "tstzmultirange", "datemultirange",
  ]
}
