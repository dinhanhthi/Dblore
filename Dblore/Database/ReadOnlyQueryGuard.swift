// ReadOnlyQueryGuard.swift
// The check SQL passes before it runs without a human in the loop (MCP run_query, the AI
// Assistant): exactly one statement the dialect classifies as `.read`, that neither changes the
// session's brakes nor its privileges and, on PostgreSQL, calls no `postgresSideEffectFunctions`
// function; on request (the AI Assistant), no DuckDB file read (only queries starting with
// SELECT, WITH, FROM, VALUES or `(` pass that check). Refused SQL is never sent. The guard only
// classifies (a function it does not know may still write): SQL that passes runs under the
// read-only gate on a read-only session (`MCPReadOnlySessionFactory`: PostgreSQL / MySQL inside
// a READ ONLY transaction always rolled back, SQLite on the file opened read-only), MCP on its
// pool's and the AI Assistant on one of its own; AI Assistant DuckDB queries run on the
// workspace session (`WorkspaceManager.runAIQuery`).

import Foundation

nonisolated enum ReadOnlyQueryGuard {
  /// Why SQL was refused before sending
  enum Refusal: Error, Equatable, LocalizedError {
    case empty
    case multipleStatements
    case notRead
    case sideEffectFunction
    case fileAccess

    var errorDescription: String? {
      switch self {
      case .empty: "The SQL is empty. Nothing was sent to the database."
      case .multipleStatements:
        "Only a single statement runs automatically. Nothing was sent to the database."
      case .notRead:
        "Only a single read-only statement (SELECT, SHOW, …) runs automatically. "
          + "Nothing was sent to the database."
      case .sideEffectFunction:
        "The query calls a PostgreSQL function that does not run automatically (locks, "
          + "sessions, files, sequences, settings, sleeps or remote SQL). "
          + "Nothing was sent to the database."
      case .fileAccess:
        "On DuckDB only SELECT queries that read no files run automatically. "
          + "Nothing was sent to the database."
      }
    }
  }

  /// `sql` classified for `dialect`, or the first `Refusal` it hits. `refuseFileAccess` also
  /// refuses DuckDB file reads (`readsDuckDBFiles`), for SQL written from untrusted text.
  static func check(
    _ sql: String, dialect: SQLDialect, refuseFileAccess: Bool = false
  ) throws -> [ClassifiedStatement] {
    let statements = SQLStatementClassifier.classify(sql, dialect: dialect)
    guard let statement = statements.first else { throw Refusal.empty }
    guard statements.count == 1 else { throw Refusal.multipleStatements }
    guard statement.kind == .read, !statement.resetsSessionBrakes,
      !statement.changesPrivileges
    else { throw Refusal.notRead }
    if dialect == .postgresql, callsPostgresSideEffectFunction(sql) {
      throw Refusal.sideEffectFunction
    }
    if refuseFileAccess, dialect == .duckdb, readsDuckDBFiles(sql) {
      throw Refusal.fileAccess
    }
    return statements
  }

  /// DuckDB table functions that read local or remote files or run SQL text the classifier never
  /// sees (`query_table`; `query` and `getenv` are already refused by the classifier), besides
  /// the `duckDBFileFunctionPrefixes` families and every `*_SCAN` (`iceberg_scan`, …) (uppercase)
  static let duckDBFileFunctions: Set<String> = ["GLOB", "QUERY_TABLE"]

  /// Name prefixes (uppercase) of DuckDB file-reading function families
  static let duckDBFileFunctionPrefixes: [String] = ["READ_", "PARQUET_", "SNIFF_", "ST_READ"]

  /// Leading keywords of the DuckDB queries `readsDuckDBFiles` checks. Other reads (`TABLE`,
  /// `SUMMARIZE`, `DESCRIBE`, `PIVOT`, `SHOW`, …) take a table without FROM, which DuckDB may
  /// read as a file.
  private static let duckDBQueryStarts: Set<String> = ["SELECT", "WITH", "FROM", "VALUES"]

  /// Words after which a string literal or path-like quoted identifier is a table DuckDB reads
  /// as a file (`TABLE` / `SUMMARIZE` / `DESCRIBE` / `PIVOT` / `SHOW` also as subqueries)
  private static let duckDBTableKeywords: Set<String> = [
    "FROM", "JOIN", "TABLE", "SUMMARIZE", "DESCRIBE", "DESC", "PIVOT", "UNPIVOT", "PIVOT_WIDER",
    "PIVOT_LONGER", "SHOW",
  ]

  /// Keywords (and `;`) that end the FROM list of their query level
  private static let fromListEnds: Set<String> = [
    "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "QUALIFY", "WINDOW", "UNION", "EXCEPT",
    "INTERSECT",
  ]

  /// A statement not starting with a `duckDBQueryStarts` keyword or `(`, a call (name directly
  /// followed by `(`, not a column-list alias) to a DuckDB file function, or a table that DuckDB
  /// reads as a file: a string literal, or a quoted identifier that looks like a path
  /// (`namesFile`), right after a `duckDBTableKeywords` word or a comma of a FROM list, or
  /// after `(` signs that follow one (`FROM ("x.csv" CROSS JOIN t)`).
  static func readsDuckDBFiles(_ sql: String) -> Bool {
    let tokens = SQLTokenizer.tokens(sql, dialect: .duckdb)
    guard let first = tokens.first,
      first.isSymbol("(") || first.keyword.map(duckDBQueryStarts.contains) == true
    else { return true }
    // Paren depths whose FROM list the scan is in
    var fromLists: Set<Int> = []
    // The current token sits where DuckDB takes a table
    var tablePosition = false
    for index in tokens.indices {
      let token = tokens[index]
      if token.isWord("FROM") {
        fromLists.insert(token.depth)
      } else if token.isSymbol(")") {
        fromLists.remove(token.depth + 1)
      } else if token.isSymbol(";") || token.keyword.map(fromListEnds.contains) == true {
        fromLists.remove(token.depth)
      }
      if tablePosition, namesFile(token) { return true }
      if callsDuckDBFileFunction(tokens, at: index) { return true }
      tablePosition =
        token.keyword.map(duckDBTableKeywords.contains) == true
        || (token.isSymbol(",") && fromLists.contains(token.depth))
        || (token.isSymbol("(") && tablePosition)
    }
    return false
  }

  /// A string literal, or a quoted identifier whose text holds `/ \ ~ * :` or a `.` followed by a
  /// letter (a file extension), so `"Orders"` stays a table
  private static func namesFile(_ token: SQLToken) -> Bool {
    switch token.kind {
    case .string, .backslashString: return true
    case .quotedIdentifier:
      return token.text.contains { "/\\~*:".contains($0) }
        || token.text.range(of: #"\.[A-Za-z]"#, options: .regularExpression) != nil
    default: return false
    }
  }

  private static func callsDuckDBFileFunction(_ tokens: [SQLToken], at index: Int) -> Bool {
    let token = tokens[index]
    guard index + 1 < tokens.count, tokens[index + 1].isSymbol("("),
      token.kind == .word || token.kind == .quotedIdentifier,
      !namesColumnList(tokens, at: index)
    else { return false }
    let name = SQLTokenizer.asciiUppercased(token.text)
    return duckDBFileFunctions.contains(name) || name.hasSuffix("_SCAN")
      || duckDBFileFunctionPrefixes.contains { name.hasPrefix($0) }
  }

  /// PostgreSQL functions the guard refuses to call (uppercase): with side effects a READ ONLY
  /// transaction does not stop (killing or signalling backends, session-level advisory locks
  /// that outlive the ROLLBACK, server files and large objects, configuration reloads, WAL and
  /// replication control, NOTIFY, settings, sequences, a transaction id, sleeps) or that run SQL
  /// text the classifier never sees (`dblink*`, `query_to_xml*`, `cursor_to_xml*`, `ts_stat`,
  /// `ts_rewrite`;
  /// `database_to_xml*` / `schema_to_xml*` dump whole schemas). Best-effort: functions inside
  /// views or user functions (dynamic SQL) are covered only by the read-only transaction.
  static let postgresSideEffectFunctions: Set<String> = [
    "PG_TERMINATE_BACKEND", "PG_CANCEL_BACKEND", "PG_READ_FILE", "PG_READ_BINARY_FILE",
    "PG_STAT_FILE", "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE", "PG_PROMOTE", "PG_SWITCH_WAL",
    "PG_NOTIFY", "SET_CONFIG", "NEXTVAL", "SETVAL", "TXID_CURRENT", "PG_CURRENT_XACT_ID",
    "PG_LOGICAL_EMIT_MESSAGE", "PG_REPLICATION_SLOT_ADVANCE", "TS_STAT", "TS_REWRITE",
    "PG_STAT_STATEMENTS_RESET", "PG_START_BACKUP", "PG_STOP_BACKUP", "PG_LOGFILE_ROTATE",
    "PG_LOG_BACKEND_MEMORY_CONTEXTS", "PG_IMPORT_SYSTEM_COLLATIONS",
  ]

  /// Name prefixes (uppercase) of `postgresSideEffectFunctions` families
  static let postgresSideEffectFunctionPrefixes: [String] = [
    "DBLINK", "PG_ADVISORY_", "PG_TRY_ADVISORY_", "LO_", "PG_LS_", "PG_SLEEP", "PG_CREATE_",
    "PG_DROP_", "PG_FILE_", "PG_REPLICATION_ORIGIN_", "PG_WAL_REPLAY_", "PG_BACKUP_",
    "PG_STAT_RESET", "QUERY_TO_XML", "CURSOR_TO_XML", "DATABASE_TO_XML", "SCHEMA_TO_XML",
    "PG_COPY_", "PG_LOGICAL_SLOT_",
  ]

  /// A word or quoted identifier directly followed by `(` (comments and whitespace between are
  /// not tokens) whose name, ASCII-uppercased, is a `postgresSideEffectFunctions` function,
  /// schema-qualified or not. A `U&"..."` name called as a function fails closed (its escapes
  /// may spell any name). Mentions inside strings or comments are not calls, nor are names
  /// with a column list (`namesColumnList`).
  static func callsPostgresSideEffectFunction(_ sql: String) -> Bool {
    let tokens = SQLTokenizer.tokens(sql, dialect: .postgresql)
    return tokens.indices.dropLast().contains { index in
      let token = tokens[index]
      guard tokens[index + 1].isSymbol("("),
        token.kind == .word || token.kind == .quotedIdentifier
      else { return false }
      if token.kind == .quotedIdentifier, index > 0, tokens[index - 1].isSymbol("&") {
        return true
      }
      guard !namesColumnList(tokens, at: index), let text = token.asciiText else { return false }
      let name = SQLTokenizer.asciiUppercased(text)
      return postgresSideEffectFunctions.contains(name)
        || postgresSideEffectFunctionPrefixes.contains { name.hasPrefix($0) }
    }
  }

  /// The name at `index` (followed by `(`) is an alias with its column list (`AS t(a, b)`).
  /// A CTE named like a listed function stays refused: matching CTE heads by token shape let a
  /// record function's column definitions (`, dblink(c, q) AS (values text)`) pass as one.
  private static func namesColumnList(_ tokens: [SQLToken], at index: Int) -> Bool {
    index > 0 && tokens[index - 1].isWord("AS")
  }
}
