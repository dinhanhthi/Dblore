// SQLDialect.swift
// Quote, literal, and statement-fragment rules for PostgreSQL, SQLite, DuckDB, MySQL and
// ClickHouse and SQL Server (T-SQL), plus the MongoDB marker: no SQL identifiers, every other
// member PostgreSQL-shaped.

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
    case clickhouse
    case sqlserver
  }

  private let engine: Engine

  static let postgresql = SQLDialect(engine: .postgresql)
  static let sqlite = SQLDialect(engine: .sqlite)
  static let duckdb = SQLDialect(engine: .duckdb)
  static let mysql = SQLDialect(engine: .mysql)
  static let mongodb = SQLDialect(engine: .mongodb)
  static let clickhouse = SQLDialect(engine: .clickhouse)
  static let sqlserver = SQLDialect(engine: .sqlserver)

  /// Name used in prompts ("PostgreSQL", "SQLite", "DuckDB", "MySQL", "ClickHouse SQL",
  /// "SQL Server (T-SQL)").
  var promptName: String {
    switch engine {
    case .postgresql, .mongodb: "PostgreSQL"
    case .sqlite: "SQLite"
    case .duckdb: "DuckDB"
    case .mysql: "MySQL"
    case .clickhouse: "ClickHouse SQL"
    case .sqlserver: "SQL Server (T-SQL)"
    }
  }

  /// Schema omitted by `qualified` when the caller passes it explicitly (PostgreSQL keeps it).
  /// MySQL has none: its schema is the connected database, so any named schema stays.
  /// ClickHouse's is the `default` database and SQL Server's is `dbo`, which `qualified` keeps
  /// as PostgreSQL does.
  var defaultSchema: String {
    switch engine {
    case .postgresql, .mongodb: "public"
    case .sqlite, .duckdb: "main"
    case .clickhouse: "default"
    case .sqlserver: "dbo"
    case .mysql: ""
    }
  }

  /// Whether `UPDATE ONLY` is meaningful (PostgreSQL inheritance).
  var supportsUpdateOnly: Bool {
    switch engine {
    case .postgresql, .mongodb: true
    case .sqlite, .duckdb, .mysql, .clickhouse, .sqlserver: false
    }
  }

  /// Whether `UPDATE ... SET c = DEFAULT` is valid (PostgreSQL `UPDATE`, MySQL and T-SQL
  /// `UPDATE` docs). SQLite and MongoDB have none; DuckDB grid edits stay off
  /// (`supportsRowStaging`).
  var supportsDefaultInUpdate: Bool {
    switch engine {
    case .postgresql, .mysql, .sqlserver: true
    case .sqlite, .duckdb, .mongodb, .clickhouse: false
    }
  }

  /// SQLite and MySQL (default `_ci` collations) `LIKE` fold case, and neither has `ILIKE`.
  /// PostgreSQL and DuckDB `LIKE` do not (`ILIKE` does). SQL Server's depends on the collation,
  /// so it counts as case-sensitive and a case-insensitive match lowers both sides.
  var likeIsCaseInsensitive: Bool {
    switch engine {
    case .sqlite, .mysql: true
    case .postgresql, .duckdb, .mongodb, .clickhouse, .sqlserver: false
    }
  }

  /// `"name"` with embedded `"` doubled; MySQL `` `name` `` with embedded `` ` `` doubled;
  /// ClickHouse `` `name` `` with `\` and `` ` `` backslash-escaped (ClickHouse identifiers take
  /// the string literal escapes); SQL Server `[name]` with embedded `]` doubled. Escapes walk
  /// Unicode scalars (`escapingScalars`). Rejects a NUL anywhere in `name`, and every name on
  /// MongoDB (`notSQL`).
  func quoteIdentifier(_ name: String) throws -> String {
    let quote: Unicode.Scalar
    switch engine {
    case .postgresql, .sqlite, .duckdb: quote = "\""
    case .mysql, .clickhouse: quote = "`"
    case .sqlserver: quote = "]"
    case .mongodb: throw SQLDialectError.notSQL
    }
    guard !name.unicodeScalars.contains("\0") else {
      throw SQLDialectError.nulInIdentifier
    }
    let quoteText = String(quote)
    let escapes: [Unicode.Scalar: String] =
      engine == .clickhouse
      ? ["\\": "\\\\", quote: "\\" + quoteText] : [quote: quoteText + quoteText]
    let opening = engine == .sqlserver ? "[" : quoteText
    return opening + Self.escapingScalars(name, escapes) + quoteText
  }

  /// `name` bare when it is a plain lowercase identifier (`[a-z_][a-z0-9_]*`) and no reserved
  /// word, else `quoteIdentifier(name)`. A bare name reads the same as the quoted one on every
  /// engine (PostgreSQL folds an unquoted name to lower case, and it is already lower case).
  /// Only safe for the column part of a qualified name (`alias.column`): the reserved words
  /// below are not every engine's, and most of them are fine after a dot. ClickHouse and
  /// SQL Server always quote.
  func quoteIdentifierIfNeeded(_ name: String) throws -> String {
    switch engine {
    case .mongodb: throw SQLDialectError.notSQL
    case .clickhouse, .sqlserver: return try quoteIdentifier(name)
    case .postgresql, .sqlite, .duckdb, .mysql: break
    }
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
  /// resolves a default-schema relation through the user's `search_path`. ClickHouse keeps every
  /// database, `default` too: a bare name resolves in the connection's database. SQL Server keeps
  /// every schema, `dbo` too: a bare name resolves in the login's default schema first.
  func qualified(schema: String?, name: String) throws -> String {
    let quotedName = try quoteIdentifier(name)
    guard let schema,
      engine == .postgresql || engine == .clickhouse || engine == .sqlserver
        || schema != defaultSchema
    else {
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
      switch engine {
      case .clickhouse: flag ? "true" : "false"
      case .sqlserver: flag ? "1" : "0"
      case .postgresql, .sqlite, .duckdb, .mysql, .mongodb: flag ? "TRUE" : "FALSE"
      }
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
  /// MySQL is a bare `?`: binds are positional, so `index` is ignored. ClickHouse is the query
  /// parameter `{pN:String}`: the engine plugin sends bind N as `param_pN`; where the server
  /// refuses a `String` against the column's type, `placeholder(_:type:)` types it. SQL Server
  /// is `@pN`: the engine plugin declares bind N as the batch variable `@pN`.
  func placeholder(_ index: Int) -> String {
    switch engine {
    case .postgresql, .duckdb, .mongodb: "$\(index)"
    case .sqlite: "?\(index)"
    case .clickhouse: "{p\(index):String}"
    case .sqlserver: "@p\(index)"
    case .mysql: "?"
    }
  }

  /// `placeholder(index)` typed for a column of `type` (its `ColumnInfo.type`), for a server that
  /// refuses a `String` parameter against a numeric or date column: ClickHouse `{pN:<type>}`.
  /// A type text that could end the placeholder or the statement (anything but ASCII letters,
  /// digits, spaces and `_ ( ) , ' = - / . +`, a `--` or `//`, or an odd count of `'`) stays
  /// `{pN:String}`. Every other
  /// dialect ignores `type`.
  func placeholder(_ index: Int, type: String) -> String {
    guard engine == .clickhouse, Self.isPlainTypeText(type) else { return placeholder(index) }
    return "{p\(index):\(type)}"
  }

  private static func isPlainTypeText(_ type: String) -> Bool {
    let punctuation: Set<Unicode.Scalar> = [" ", "_", "(", ")", ",", "'", "=", "-", "/", ".", "+"]
    return !type.isEmpty && !type.contains("--") && !type.contains("//")
      && type.unicodeScalars.filter({ $0 == "'" }).count.isMultiple(of: 2)
      && type.unicodeScalars.allSatisfy {
        $0.isASCII
          && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || punctuation.contains($0))
      }
  }

  /// `LIMIT limit OFFSET offset`. SQL Server is `OFFSET offset ROWS FETCH NEXT limit ROWS ONLY`,
  /// which needs an `ORDER BY`: a statement without one (`ordered` false) gets
  /// `ORDER BY (SELECT NULL)` first. Every other dialect ignores `ordered`.
  func limitOffset(limit: Int, offset: Int, ordered: Bool = true) -> String {
    guard engine == .sqlserver else { return "LIMIT \(limit) OFFSET \(offset)" }
    return (ordered ? "" : "ORDER BY (SELECT NULL) ")
      + "OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
  }

  /// The first `n` rows: `LIMIT n`, or SQL Server's `limitOffset(limit: n, offset: 0,
  /// ordered: ordered)`
  func limit(_ n: Int, ordered: Bool) -> String {
    engine == .sqlserver ? limitOffset(limit: n, offset: 0, ordered: ordered) : "LIMIT \(n)"
  }

  /// Opens the savepoint `name` (an app-owned name, inserted unchanged): `SAVEPOINT name`, SQL
  /// Server `SAVE TRANSACTION name`
  func savepointSQL(_ name: String) -> String {
    engine == .sqlserver ? "SAVE TRANSACTION \(name)" : "SAVEPOINT \(name)"
  }

  /// Undoes the work since savepoint `name`, keeping the transaction: `ROLLBACK TO SAVEPOINT
  /// name`, SQL Server `ROLLBACK TRANSACTION name`
  func rollbackToSavepointSQL(_ name: String) -> String {
    engine == .sqlserver ? "ROLLBACK TRANSACTION \(name)" : "ROLLBACK TO SAVEPOINT \(name)"
  }

  /// `RELEASE SAVEPOINT name`; nil on SQL Server, which has no release (a savepoint ends with
  /// its transaction)
  func releaseSavepointSQL(_ name: String) -> String? {
    engine == .sqlserver ? nil : "RELEASE SAVEPOINT \(name)"
  }

  /// PostgreSQL `EXPLAIN` with optional ANALYZE, BUFFERS, and FORMAT. ClickHouse and SQL Server
  /// are a plain `EXPLAIN` (text), every option ignored.
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
    case .clickhouse, .sqlserver:
      return "EXPLAIN"
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
  /// ClickHouse `toString(..)`, SQL Server `CAST(.. AS NVARCHAR(MAX))`, SQLite unchanged.
  func likeSubject(_ column: String) -> String {
    switch engine {
    case .postgresql, .mongodb: "\(column)::text"
    case .clickhouse: "toString(\(column))"
    case .sqlserver: "CAST(\(column) AS NVARCHAR(MAX))"
    case .sqlite: column
    case .duckdb: "\(column)::VARCHAR"
    case .mysql: "CAST(\(column) AS CHAR)"
    }
  }

  /// `column`, `pattern` and `escape` are SQL fragments, inserted unchanged; `escape` follows
  /// the comparison as `ESCAPE escape`. SQLite and MySQL lower both sides (a MySQL `_bin`
  /// collation makes `LIKE` case-sensitive), the form Find a Value in Every Table searches with;
  /// so does SQL Server (`lowerLike`).
  func caseInsensitiveLike(column: String, pattern: String, escape: String? = nil) -> String {
    let comparison =
      switch engine {
      case .postgresql, .mongodb: "\(column)::text ILIKE \(pattern)"
      case .clickhouse: "\(likeSubject(column)) ILIKE \(pattern)"
      case .sqlite: "LOWER(\(column)) LIKE LOWER(\(pattern))"
      case .sqlserver: lowerLike(column: column, pattern: pattern, negated: false)
      case .duckdb: "\(column)::VARCHAR ILIKE \(pattern)"
      case .mysql: "LOWER(CAST(\(column) AS CHAR)) LIKE LOWER(\(pattern))"
      }
    return escape.map { "\(comparison) ESCAPE \($0)" } ?? comparison
  }

  /// SQL Server `LOWER(CAST(column AS NVARCHAR(MAX))) [NOT] LIKE LOWER(pattern)`: whether `LIKE`
  /// folds case depends on the collation, so both sides are lowered (T-SQL has no `ILIKE`)
  private func lowerLike(column: String, pattern: String, negated: Bool) -> String {
    "LOWER(\(likeSubject(column))) \(negated ? "NOT " : "")LIKE LOWER(\(pattern))"
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

  /// `lhs op rhs` for a column with the schema read's type data. PostgreSQL always names the
  /// operator's schema: `pg_catalog`'s, or the owning extension's for its listed types
  /// (`OPERATOR(public.=)`), so an operator planted in another schema on the `search_path` is
  /// never chosen. A domain over such a type compares both sides cast to its base type. Every
  /// other dialect writes `comparison(_:_:_:operand:)`'s text.
  func comparison(
    _ lhs: String, _ op: SQLComparison, _ rhs: String, type: PostgresColumnType?
  ) -> String {
    let parts = comparisonParts(lhs, op, type: type)
    return parts.lead + rhs + parts.trail
  }

  /// `comparison(_:_:_:type:)` around a value written later (a bind or a subquery): `lead` goes
  /// before it (`col OPERATOR(public.=) `, with the column cast for a domain), `trail` after it
  /// (`::<compareCast>`, or empty)
  func comparisonParts(
    _ lhs: String, _ op: SQLComparison, type: PostgresColumnType?
  ) -> (lead: String, trail: String) {
    guard engine == .postgresql, let type, SQLOperandKind(column: type) == .bare,
      let schema = type.operatorSchema
    else { return (comparison(lhs, op, "", operand: .qualified), "") }
    let cast = type.compareCast.map { "::\($0)" } ?? ""
    return ("\(lhs)\(cast) OPERATOR(\(schema).\(op.rawValue)) ", cast)
  }

  /// `inList(_:_:negated:operand:)` for a column with the schema read's type data: on PostgreSQL
  /// each term is `comparison(_:_:_:type:)`
  func inList(
    _ column: String, _ items: [String], negated: Bool = false, type: PostgresColumnType?
  ) -> String {
    guard engine == .postgresql else { return inList(column, items, negated: negated) }
    let terms = items.map { comparison(column, negated ? .notEqual : .equal, $0, type: type) }
    return "(" + terms.joined(separator: negated ? " AND " : " OR ") + ")"
  }

  /// `column [NOT] LIKE pattern [ESCAPE escape]`, case-insensitive (`ILIKE`, or both sides
  /// lowered on SQLite, MySQL and SQL Server, negated too on SQL Server) when asked. Fragments
  /// are inserted unchanged. PostgreSQL is `column::pg_catalog.text OPERATOR(pg_catalog.~~)`
  /// (`~~*`, `!~~`, `!~~*`), and an escape
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
    if caseInsensitive && engine == .sqlserver {
      let comparison = lowerLike(column: column, pattern: pattern, negated: negated)
      return escape.map { "\(comparison) ESCAPE \($0)" } ?? comparison
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

  /// Text concatenation: `lhs || rhs`, MySQL `CONCAT(lhs, rhs)`, ClickHouse `concat(lhs, rhs)`,
  /// PostgreSQL `lhs OPERATOR(pg_catalog.||) rhs`
  func concatenation(_ lhs: String, _ rhs: String) -> String {
    switch engine {
    case .postgresql: "\(lhs) OPERATOR(pg_catalog.||) \(rhs)"
    case .clickhouse: "concat(\(lhs), \(rhs))"
    case .mysql, .sqlserver: "CONCAT(\(lhs), \(rhs))"
    case .sqlite, .duckdb, .mongodb: "\(lhs) || \(rhs)"
    }
  }

  /// `'text'`, with `'` doubled. PostgreSQL text that contains `\` is `E'...'`:
  /// every `\` becomes `\\` and every `'` becomes `''`, so those characters stay
  /// data with `standard_conforming_strings` on or off. SQLite and DuckDB never use `E`: their
  /// plain strings have no backslash escapes. MySQL plain strings do: every `\` becomes `\\`
  /// with no prefix. ClickHouse escapes both with a backslash: `\` is `\\`, `'` is `\'`.
  /// SQL Server is `sqlserverLiteral`.
  private func quoteLiteral(_ text: String) -> String {
    if engine == .clickhouse {
      return "'" + Self.escapingScalars(text, ["\\": "\\\\", "'": "\\'"]) + "'"
    }
    if engine == .sqlserver { return Self.sqlserverLiteral(text) }
    let doubledQuotes = Self.escapingScalars(text, ["'": "''"])
    guard text.unicodeScalars.contains("\\") else {
      return "'\(doubledQuotes)'"
    }
    let escaped = Self.escapingScalars(text, ["'": "''", "\\": "\\\\"])
    switch engine {
    case .postgresql, .mongodb: return "E'\(escaped)'"
    case .mysql, .clickhouse, .sqlserver: return "'\(escaped)'"
    case .sqlite, .duckdb: return "'\(doubledQuotes)'"
    }
  }

  /// T-SQL `N'text'` with every `'` scalar doubled; a backslash stays single (T-SQL has no
  /// backslash escapes). The server drops a `\` directly followed by CR or LF together with the
  /// break (line continuation), so the text is cut after each such `\` scalar and the
  /// `N'…'` pieces are joined with `+`, the first cast to `nvarchar(max)` so the sum is not cut
  /// at 4000 characters. Walks scalars, as the server lexes the text: a `\` followed by a
  /// combining mark is no continuation.
  private static func sqlserverLiteral(_ text: String) -> String {
    var pieces: [String.UnicodeScalarView] = []
    var current = String.UnicodeScalarView()
    var previous: Unicode.Scalar?
    for scalar in text.unicodeScalars {
      if previous == "\\", scalar == "\n" || scalar == "\r" {
        pieces.append(current)
        current = String.UnicodeScalarView()
      }
      current.append(scalar)
      previous = scalar
    }
    pieces.append(current)
    let literals = pieces.map { "N'" + escapingScalars(String($0), ["'": "''"]) + "'" }
    guard literals.count > 1 else { return literals[0] }
    return "CAST(\(literals[0]) AS nvarchar(max))"
      + literals.dropFirst().map { " + " + $0 }.joined()
  }

  private func doubleLiteral(_ number: Double) -> String {
    if number.isFinite { return String(number) }
    switch engine {
    case .sqlite, .mysql, .clickhouse, .sqlserver:
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
    case .sqlserver:
      return "0x\(data.hexDigits(uppercase: true))"
    case .clickhouse:
      return "unhex('\(data.hexDigits(uppercase: true))')"
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

/// Whether a PostgreSQL comparison on a column names `pg_catalog`'s operator (`.qualified`) or
/// the owning extension's (`.bare`, written `OPERATOR(<extension schema>.op)` by
/// `comparison(_:_:_:type:)`), because `pg_catalog` has none for a listed extension type (a
/// qualified `=` would make a citext filter case-sensitive or fail on PostGIS). Only the schema
/// read's type data decides it, never a type's name.
nonisolated enum SQLOperandKind: Sendable, Equatable {
  case qualified
  case bare

  /// From the schema read's type data: `.bare` only for an extension type whose operator schema
  /// is known; no type data, or no schema, is `.qualified`
  init(column type: PostgresColumnType?) {
    self = type?.operand == .bare && type?.operatorSchema != nil ? .bare : .qualified
  }
}

/// A PostgreSQL column's type as the schema read classifies it on the server
nonisolated struct PostgresColumnType: Sendable, Equatable {
  /// `pg_attribute.atttypid`
  let oid: UInt32
  /// `.bare` for a listed extension type (through domains), owned by its extension
  let operand: SQLOperandKind
  /// The column's own type, schema-qualified and quoted (`public.cit_dom`, `public.citext[]`);
  /// nil in `pg_catalog`
  let castName: String?
  /// For a domain over a listed extension type: that base type, schema-qualified and quoted
  /// (`public.citext`); both sides of a comparison are cast to it
  let compareCast: String?
  /// For the `.bare` operand: the owning extension's schema, quoted (`public`)
  let operatorSchema: String?
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
    "oidvector", "int2vector", "pg_node_tree", "aclitem",
  ]
}
