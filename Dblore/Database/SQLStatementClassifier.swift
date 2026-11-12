// SQLStatementClassifier.swift
// Pure, isolation-free classification of SQL statements by kind and safety flags

import Foundation

/// What a statement does, as far as can be told from its text.
nonisolated indirect enum StatementKind: Sendable, Equatable {
  /// SELECT (without INTO), VALUES, TABLE, SHOW, WITH ... SELECT without data-modifying CTE
  case read
  /// INSERT, UPDATE, DELETE, MERGE, SELECT ... INTO (INTO at any depth), data-modifying WITH
  case dml
  /// CREATE, DROP, ALTER, TRUNCATE, COMMENT ON
  case ddl
  /// Transaction control: BEGIN, COMMIT, ROLLBACK, SAVEPOINT, PREPARE TRANSACTION, ...
  case tcl
  /// SET / RESET; `touchesBrake` when it changes a timeout or read-only guard
  case sessionSet(touchesBrake: Bool)
  /// COPY, DO, CALL, VACUUM, GRANT, ... (effects not visible from the text)
  case utility
  /// EXPLAIN of `inner`; with `analyze` the inner statement is executed
  case explain(inner: StatementKind, analyze: Bool)
  /// Unrecognized first keyword (includes EXECUTE / PREPARE name AS ...), or a SELECT / VALUES /
  /// TABLE statement with a DML keyword nested in parentheses
  case unknown
}

/// One statement of a SQL script with its classification.
nonisolated struct ClassifiedStatement: Sendable, Equatable {
  let text: String
  let kind: StatementKind
  /// RETURNING appears anywhere (including inside a data-modifying CTE)
  let hasReturning: Bool
  /// RETURNING at the statement's own level (not inside parentheses / a CTE body)
  let hasTopLevelReturning: Bool
  /// An UPDATE/DELETE (top-level or data-modifying CTE) has no WHERE at its own level
  let affectsAllRows: Bool
  /// Cannot run inside a transaction block (CONCURRENTLY, VACUUM, CREATE DATABASE, ...)
  let nonTransactional: Bool
  /// Can change the app's session brakes: SET/RESET of a brake GUC, RESET ALL,
  /// SET TRANSACTION ..., DISCARD ALL, or BEGIN / START TRANSACTION ... READ WRITE
  let resetsSessionBrakes: Bool
  /// Switches the privilege context: SET [SESSION | LOCAL] ROLE, SET SESSION AUTHORIZATION,
  /// RESET ROLE, RESET SESSION AUTHORIZATION, SET role / session_authorization, DISCARD ALL
  let changesPrivileges: Bool
  /// SELECT ... INTO / WITH ... SELECT ... INTO (creates a table like CREATE TABLE AS)
  let createsTable: Bool
  /// Removes data or an index for good (MongoDB `drop`, `dropIndex`; ClickHouse statements
  /// `clickhouseAdjusted` lists); false for other SQL
  var isDestructive: Bool = false

  /// True only for statements that cannot modify anything: reads and plain EXPLAIN of a
  /// recognized statement.
  var isReadOnlySafe: Bool {
    switch kind {
    case .read: true
    case .explain(let inner, analyze: false): inner != .unknown
    default: false
    }
  }
}

/// Aggregate view of a classified script, used by the execution gate.
nonisolated struct ClassificationSummary: Sendable, Equatable {
  let hasModification: Bool
  let hasSchemaChange: Bool
  let hasUnknown: Bool
  let affectsAllRows: Bool
  /// Some statement has `resetsSessionBrakes`
  let touchesBrake: Bool
  /// Some statement has `changesPrivileges`
  let changesPrivileges: Bool
}

/// Classifies SQL statements using `SQLTokenizer`. Safe to call from any isolation domain.
/// Blind spots: side effects hidden in functions (`SELECT volatile_fn()`, `set_config`),
/// DO/CALL bodies and triggers are not detected. On DuckDB a read that calls a listed
/// side-effecting function or names a remote URL fails closed (`duckdbAdjusted`).
nonisolated enum SQLStatementClassifier {

  /// Split `sql` into statements and classify each. Empty / comment-only statements are dropped.
  /// `dialect` defaults to PostgreSQL, which keeps every existing caller on today's rules.
  /// MongoDB text goes to `MongoCommandClassifier` and Redis text to `classifyRedis`; neither is
  /// ever lexed as SQL.
  static func classify(
    _ sql: String, dialect: SQLDialect = .postgresql
  ) -> [ClassifiedStatement] {
    switch dialect.language {
    case .sql: break
    case .mongosh: return MongoCommandClassifier.classify(sql)
    case .redis: return classifyRedis(sql)
    }
    let tokenizer = SQLTokenizer(dialect: dialect)
    return tokenizer.splitStatements(sql).compactMap { classifyStatement($0, dialect: dialect) }
  }

  /// Classify one already-split statement; nil if it is empty / comment-only.
  /// Fails closed (`.unknown`) when the text may be lexed differently by the server:
  /// a `;` token (the splitter and the tokenizer disagree on a statement boundary), a
  /// plain string containing a backslash (escape under `standard_conforming_strings = off`),
  /// a MySQL executable comment (`/*! ... */`, `/*M! ... */`: the server runs its content),
  /// or SQL Server text `sqlserverFailsClosed` refuses (a number that runs straight into a word,
  /// a non-ASCII space, control or format scalar outside quotes and comments, a `--` comment
  /// ended by a lone CR, a `GO` batch-separator line), or ClickHouse text
  /// `clickhouseFailsClosed` refuses (a bare non-ASCII scalar, a number's `-` sign before `-`).
  /// An unrecognized MySQL or SQL Server statement cannot run in the app's transaction
  /// (`nonTransactional`): it may commit or roll back.
  /// MongoDB text goes to `MongoCommandClassifier`, before any SQL lexing. Redis text goes to
  /// `classifyRedis`: several commands are `.unknown` (fail closed), as on MongoDB.
  /// `standardConformingStrings` (PostgreSQL, SQL dump restore only): read a plain string with a
  /// backslash as `standard_conforming_strings = on` does, once the session reported it on.
  static func classifyStatement(
    _ text: String, dialect: SQLDialect = .postgresql, standardConformingStrings: Bool = false
  ) -> ClassifiedStatement? {
    switch dialect.language {
    case .sql: break
    case .mongosh: return MongoCommandClassifier.classifyStatement(text)
    case .redis:
      let statements = classifyRedis(text)
      guard let first = statements.first else { return nil }
      return statements.count == 1
        ? first : redisUnknown(statements.map(\.text).joined(separator: "\n"))
    }
    let tokens = SQLTokenizer(
      dialect: dialect, standardConformingStrings: standardConformingStrings
    ).tokens(text)
    guard !tokens.isEmpty else { return nil }
    let analysis = analyze(tokens[...], dialect: dialect)
    let ambiguous =
      tokens.contains {
        $0.isSymbol(";") || $0.kind == .backslashString || $0.kind == .executableComment
      }
      || (dialect == .sqlserver && SQLTokenizer(dialect: dialect).sqlserverFailsClosed(text))
      || (dialect == .clickhouse && SQLTokenizer(dialect: dialect).clickhouseFailsClosed(text))
    let kind = ambiguous ? .unknown : analysis.kind
    // MySQL: an unrecognized statement may commit implicitly (see `mysqlAdjusted`); SQL Server:
    // a block, a procedure call or a batch may commit or roll back
    let unknownEndsTransaction = (dialect == .mysql || dialect == .sqlserver) && kind == .unknown
    return ClassifiedStatement(
      text: text, kind: kind, hasReturning: analysis.hasReturning,
      hasTopLevelReturning: analysis.hasTopLevelReturning,
      affectsAllRows: analysis.affectsAllRows,
      nonTransactional: analysis.nonTransactional || unknownEndsTransaction,
      resetsSessionBrakes: analysis.resetsSessionBrakes
        || (dialect == .mysql && hintsMySQLBrake(text)),
      changesPrivileges: analysis.changesPrivileges, createsTable: analysis.createsTable,
      isDestructive: analysis.isDestructive)
  }

  /// Redis text, one command per line (`RedisTokenizer`), each classified by
  /// `RedisCommandClassifier`, whose `text` is the command's redacted render. Text the tokenizer
  /// refuses is one `.unknown` statement (fail closed) whose text is the tokenizer's error, not
  /// the input: a secret in text that does not tokenize cannot be redacted.
  private static func classifyRedis(_ text: String) -> [ClassifiedStatement] {
    do {
      return try RedisTokenizer.tokenize(text).map { RedisCommandClassifier.classify($0).statement }
    } catch {
      return [redisUnknown(error.localizedDescription)]
    }
  }

  private static func redisUnknown(_ text: String) -> ClassifiedStatement {
    ClassifiedStatement(
      text: text, kind: .unknown, hasReturning: false, hasTopLevelReturning: false,
      affectsAllRows: false, nonTransactional: false, resetsSessionBrakes: false,
      changesPrivileges: false, createsTable: false)
  }

  /// A MySQL optimizer hint (`/*+ ... */`, anywhere) naming a `mysqlBrakeSettings` variable:
  /// `MAX_EXECUTION_TIME(n)` or `SET_VAR(innodb_lock_wait_timeout = n)` lifts a brake for one
  /// statement. ASCII case-insensitive substring match; over-matches, which only asks for more
  /// confirmation. Index and join hints (`INDEX(t i)`, `JOIN_ORDER(a, b)`) do not match.
  private static func hintsMySQLBrake(_ text: String) -> Bool {
    SQLTokenizer(dialect: .mysql).optimizerHints(text).contains { hint in
      let lowered = SQLTokenizer.asciiLowercased(hint)
      return mysqlBrakeSettings.contains { lowered.contains($0) }
    }
  }

  /// True when `sql` is a CREATE/ALTER ROLE or CREATE/ALTER USER (not `USER MAPPING`) whose
  /// text contains the word PASSWORD, including `WITH ENCRYPTED PASSWORD`. ASCII
  /// case-insensitive, and PASSWORD does not have to be the first clause.
  /// Also true, in every dialect, for MySQL `SET PASSWORD ...` and for any statement with the
  /// words `IDENTIFIED BY` or `IDENTIFIED WITH <plugin> BY` (outside strings and comments).
  /// On MySQL (tokenized with `dialect`, so backslash escapes in strings hide nothing) also true
  /// for any executable comment (`/*! ... */`: its content is not checked), a
  /// `SOURCE_PASSWORD =` / `MASTER_PASSWORD =` option, a `PASSWORD '...'` option
  /// (`CREATE SERVER ... OPTIONS (PASSWORD 'x')`), `PASSWORD('...')`, `PASSWORD =` in a
  /// `START` statement, a `CONNECTION '...'` or password-bearing `OPTION_LIST '...'` table
  /// option, and `IDENTIFIED VIA` / `USING` / `AS` / `WITH <plugin> AS`.
  /// Otherwise a SELECT is never a match, even when a column or a comment contains PASSWORD.
  /// Always false on MongoDB (mongosh text is not SQL). On Redis, true when a command carries a
  /// secret (`RedisCommandClassifier.containsSecret`) or the text does not tokenize: a secret
  /// there cannot be found, so callers skip it as if it held one.
  nonisolated static func containsPasswordLiteral(
    _ sql: String, dialect: SQLDialect = .postgresql
  ) -> Bool {
    switch dialect.language {
    case .sql: break
    case .mongosh: return false
    case .redis:
      guard let commands = try? RedisTokenizer.tokenize(sql) else { return true }
      return commands.contains(where: RedisCommandClassifier.containsSecret)
    }
    let tokens = SQLTokenizer.tokens(sql, dialect: dialect)
    let words = tokens.compactMap(\.keyword)
    if words.starts(with: ["SET", "PASSWORD"]) || identifiesByPassword(words) { return true }
    if dialect == .mysql, hasMySQLPasswordOption(tokens, words: words) { return true }
    guard isRoleOrUserAdmin(words) else { return false }
    return sql.range(of: #"\bPASSWORD\b"#, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// An executable comment, `SOURCE_PASSWORD =` / `MASTER_PASSWORD =`, `PASSWORD '...'`,
  /// `PASSWORD('...')`, `PASSWORD =` in a `START` statement (`START REPLICA ... PASSWORD='p'`),
  /// a `connectionOption`, or `IDENTIFIED VIA` / `USING` / `AS` / `WITH <plugin> AS`.
  private static func hasMySQLPasswordOption(_ tokens: [SQLToken], words: [String]) -> Bool {
    if tokens.contains(where: { $0.kind == .executableComment }) { return true }
    let starts = words.first == "START"
    let option = tokens.indices.contains { index in
      let word = tokens[index]
      let next = tokens.dropFirst(index + 1).first
      let afterNext = tokens.dropFirst(index + 2).first
      return
        ((word.isWord("SOURCE_PASSWORD") || word.isWord("MASTER_PASSWORD"))
        && next?.isSymbol("=") == true)
        || (word.isWord("PASSWORD")
          && (next?.kind == .string || (starts && next?.isSymbol("=") == true)
            || (next?.isSymbol("(") == true && afterNext?.kind == .string)))
        || connectionOption(tokens, at: index)
    }
    return option || identifiesByHash(words)
  }

  /// FEDERATED / CONNECT `CONNECTION [=] '...'` (a URL that may hold a password), or CONNECT
  /// `OPTION_LIST [=] '...'` whose text contains `password` (case-insensitive).
  private static func connectionOption(_ tokens: [SQLToken], at index: Int) -> Bool {
    let word = tokens[index]
    guard word.isWord("CONNECTION") || word.isWord("OPTION_LIST") else { return false }
    var value = tokens.dropFirst(index + 1).first
    if value?.isSymbol("=") == true { value = tokens.dropFirst(index + 2).first }
    guard let value, value.kind == .string else { return false }
    return word.isWord("CONNECTION")
      || value.text.range(of: "password", options: .caseInsensitive) != nil
  }

  /// MySQL / MariaDB `IDENTIFIED VIA`, `IDENTIFIED USING`, `IDENTIFIED AS`, or
  /// `IDENTIFIED WITH plugin AS` (the plugin a word or a string).
  private static func identifiesByHash(_ words: [String]) -> Bool {
    words.indices.contains { index in
      guard words[index] == "IDENTIFIED" else { return false }
      let next = words.dropFirst(index + 1).prefix(3)
      return ["VIA", "USING", "AS"].contains(next.first ?? "")
        || (next.first == "WITH" && next.dropFirst().contains("AS"))
    }
  }

  /// `IDENTIFIED BY`, or `IDENTIFIED WITH plugin BY` (the plugin a word or a string).
  private static func identifiesByPassword(_ words: [String]) -> Bool {
    words.indices.contains { index in
      guard words[index] == "IDENTIFIED" else { return false }
      let next = words.dropFirst(index + 1).prefix(3)
      return next.first == "BY" || (next.first == "WITH" && next.dropFirst().contains("BY"))
    }
  }

  /// Aggregate flags. `EXPLAIN ANALYZE` counts as its inner statement; plain EXPLAIN as a read.
  static func summary(_ statements: [ClassifiedStatement]) -> ClassificationSummary {
    let kinds = statements.map { effectiveKind($0.kind) }
    return ClassificationSummary(
      hasModification: kinds.contains { $0 == .dml || $0 == .ddl },
      hasSchemaChange: kinds.contains(.ddl),
      hasUnknown: kinds.contains(.unknown),
      affectsAllRows: statements.contains(where: \.affectsAllRows),
      touchesBrake: statements.contains(where: \.resetsSessionBrakes),
      changesPrivileges: statements.contains(where: \.changesPrivileges))
  }

  /// What a statement runs: `EXPLAIN ANALYZE` counts as its inner statement; plain EXPLAIN as a
  /// read, or `.unknown` when the inner statement is unrecognized.
  static func effectiveKind(_ kind: StatementKind) -> StatementKind {
    switch kind {
    case .explain(let inner, analyze: true): effectiveKind(inner)
    case .explain(let inner, analyze: false): inner == .unknown ? .unknown : .read
    default: kind
    }
  }

  // MARK: - Analysis

  private struct Analysis {
    var kind: StatementKind
    var hasReturning = false
    var hasTopLevelReturning = false
    var affectsAllRows = false
    var nonTransactional = false
    var resetsSessionBrakes = false
    var changesPrivileges = false
    var createsTable = false
    var isDestructive = false
  }

  private static func analyze(
    _ tokens: ArraySlice<SQLToken>, dialect: SQLDialect
  ) -> Analysis {
    let body = tokens.drop { $0.isSymbol("(") }
    guard let first = body.first, first.kind == .word else {
      return dialectAdjusted(Analysis(kind: .unknown), body: body, dialect: dialect)
    }
    let base = first.depth
    let topWords = body.filter { $0.kind == .word && $0.depth == base }.map { $0.keyword ?? "" }

    if first.isWord("EXPLAIN") {
      // T-SQL has no EXPLAIN: a leading name runs a procedure
      let explained =
        dialect == .sqlserver ? Analysis(kind: .unknown) : explain(body, dialect: dialect)
      return dialectAdjusted(explained, body: body, dialect: dialect)
    }
    let kind = kind(
      of: body, keyword: first.keyword ?? "", topWords: topWords, dialect: dialect)
    let discardsAll = topWords.starts(with: ["DISCARD", "ALL"])
    return dialectAdjusted(
      Analysis(
        kind: kind,
        hasReturning: body.contains { $0.isWord("RETURNING") },
        hasTopLevelReturning: topWords.contains("RETURNING"),
        affectsAllRows: affectsAllRows(body),
        nonTransactional: nonTransactional(topWords),
        resetsSessionBrakes: kind == .sessionSet(touchesBrake: true) || discardsAll
          || beginsReadWrite(topWords),
        changesPrivileges: discardsAll || changesPrivileges(body),
        createsTable: createsTable(body, kind: kind)),
      body: body, dialect: dialect)
  }

  private static func kind(
    of body: ArraySlice<SQLToken>, keyword: String, topWords: [String], dialect: SQLDialect
  ) -> StatementKind {
    if dialect == .sqlite, let sqlite = sqliteKind(of: body, keyword: keyword) {
      return sqlite
    }
    if dialect == .duckdb, let duckdb = duckdbKind(of: body, keyword: keyword) {
      return duckdb
    }
    if dialect == .mysql, let mysql = mysqlKind(of: body, keyword: keyword, topWords: topWords) {
      return mysql
    }
    if dialect == .sqlserver, let sqlserver = sqlserverKind(of: body, keyword: keyword) {
      return sqlserver
    }
    if dialect == .clickhouse,
      let clickhouse = clickhouseKind(of: body, keyword: keyword, topWords: topWords)
    {
      return clickhouse
    }
    return switch keyword {
    case "SELECT", "VALUES", "TABLE": selectKind(body)
    case "WITH": hasDataModifyingPart(body) || body.contains { $0.isWord("INTO") } ? .dml : .read
    case "SET", "RESET": .sessionSet(touchesBrake: touchesBrake(body))
    case "PREPARE": topWords.dropFirst().first == "TRANSACTION" ? .tcl : .unknown
    case _ where readKeywords.contains(keyword): .read
    case _ where dmlKeywords.contains(keyword): .dml
    case _ where ddlKeywords.contains(keyword): .ddl
    case _ where tclKeywords.contains(keyword): .tcl
    case _ where utilityKeywords.contains(keyword): .utility
    default: .unknown
    }
  }

  /// SQLite commands that PostgreSQL classifies differently. Nil leaves the shared rules.
  private static func sqliteKind(
    of body: ArraySlice<SQLToken>, keyword: String
  ) -> StatementKind? {
    switch keyword {
    case "PRAGMA": pragmaKind(body)
    case _ where sqliteDmlKeywords.contains(keyword): .dml
    case _ where sqliteUtilityKeywords.contains(keyword): .utility
    default: nil
    }
  }

  /// SQL Server statements that PostgreSQL classifies differently. Nil leaves the shared rules.
  /// `SAVE TRAN[SACTION] name` sets a savepoint (TCL); `EXEC` / `EXECUTE` runs a procedure or
  /// SQL text, a utility like `CALL`. A `BEGIN` that starts no transaction
  /// (not `BEGIN TRAN[SACTION]` / `BEGIN DISTRIBUTED`) opens a block and a lone `END` closes
  /// one: neither is transaction control, so both fail closed, as do the shared rules' leading
  /// words T-SQL has no statement for (`sqlserverNonStatementKeywords`: a procedure call).
  private static func sqlserverKind(
    of body: ArraySlice<SQLToken>, keyword: String
  ) -> StatementKind? {
    switch keyword {
    case "BEGIN":
      ["TRAN", "TRANSACTION", "DISTRIBUTED"].contains(body.dropFirst().first?.keyword ?? "")
        ? nil : .unknown
    case "END": .unknown
    case "EXEC", "EXECUTE": .utility
    case _ where sqlserverNonStatementKeywords.contains(keyword): .unknown
    case _ where sqlserverTclKeywords.contains(keyword): .tcl
    default: nil
    }
  }

  /// ClickHouse statements that PostgreSQL classifies differently. Nil leaves the shared rules
  /// (`ALTER ... UPDATE / DELETE` mutations stay DDL, `INSERT` / `DELETE` / `UPDATE` DML).
  /// `DESCRIBE` / `DESC` / `EXISTS` only read the catalog. `RENAME`, `EXCHANGE`, `ATTACH`,
  /// `DETACH`, `UNDROP` and `REPLACE TABLE` change the schema; `OPTIMIZE`, `SYSTEM`, `KILL`,
  /// `CHECK`, `BACKUP`, `RESTORE`, `MOVE` and `USE` are utilities. A `SET` touches a brake when it
  /// names one (`clickhouseBrakeSettings`); `SET ROLE` and `SET DEFAULT ROLE` change privileges
  /// (and a role may carry settings), utilities (see `setsClickHouseRole`).
  private static func clickhouseKind(
    of body: ArraySlice<SQLToken>, keyword: String, topWords: [String]
  ) -> StatementKind? {
    switch keyword {
    case "SET" where setsClickHouseRole(topWords): .utility
    case "SET": .sessionSet(touchesBrake: namesClickHouseBrake(body))
    case "DESCRIBE", "DESC", "EXISTS": .read
    case _ where clickhouseDdlKeywords.contains(keyword): .ddl
    case _ where clickhouseUtilityKeywords.contains(keyword): .utility
    default: nil
    }
  }

  /// A word or quoted identifier from `clickhouseBrakeSettings`, at any depth, ASCII
  /// case-insensitive, or a quoted identifier with a backslash (its escapes are not decoded, so
  /// it may spell one). Over-matches (a column named `readonly`), which only asks for more.
  private static func namesClickHouseBrake(_ body: ArraySlice<SQLToken>) -> Bool {
    body.contains { token in
      if token.kind == .quotedIdentifier, token.text.unicodeScalars.contains("\\") { return true }
      guard isIdentifier(token), let text = token.asciiText else { return false }
      return clickhouseBrakeSettings.contains(SQLTokenizer.asciiLowercased(text))
    }
  }

  /// `SET ROLE …` or `SET DEFAULT ROLE …`
  private static func setsClickHouseRole(_ topWords: [String]) -> Bool {
    topWords.starts(with: ["SET", "ROLE"]) || setsDefaultRole(topWords)
  }

  /// ClickHouse statements that remove data for good are `isDestructive`: DROP, TRUNCATE,
  /// `REPLACE TABLE`, `OPTIMIZE ... DEDUPLICATE`, and an ALTER with a DELETE, DROP, CLEAR or
  /// REPLACE word at any depth (`ALTER TABLE t DELETE WHERE ...`, `DROP PARTITION`,
  /// `CLEAR COLUMN`, `REPLACE PARTITION`, and parenthesized commands such as
  /// `ALTER TABLE t (DELETE WHERE ...)`). Fails closed: a column named `drop` or a `replace(`
  /// call in an `UPDATE` expression counts, which only asks for more confirmation. DETACH is not
  /// destructive (ATTACH brings the data back). A statement with a query-level `SETTINGS`
  /// clause that names a brake (`SELECT ... SETTINGS max_execution_time = 0`) lifts it, and
  /// `SET [DEFAULT] ROLE` changes privileges and may lift brakes (a role may carry settings).
  /// `PARALLEL WITH` (at any depth) chains statements the server runs together,
  /// whatever the first verb (a failing read still lets a chained CREATE run): fails closed as
  /// `.unknown` and destructive (`runsInParallel`).
  private static func clickhouseAdjusted(
    _ analysis: Analysis, body: ArraySlice<SQLToken>
  ) -> Analysis {
    var analysis = analysis
    let depth = body.first?.depth ?? 0
    let topWords = body.filter { $0.depth == depth }.compactMap(\.keyword)
    switch topWords.first {
    case "DROP", "TRUNCATE", "REPLACE": analysis.isDestructive = true
    case "OPTIMIZE": analysis.isDestructive = topWords.contains("DEDUPLICATE")
    case "ALTER":
      analysis.isDestructive = body.dropFirst().contains {
        ["DELETE", "DROP", "CLEAR", "REPLACE"].contains($0.keyword ?? "")
      }
    case "SET" where setsClickHouseRole(topWords):
      analysis.changesPrivileges = true
      analysis.resetsSessionBrakes = true
    default: break
    }
    if body.contains(where: { $0.isWord("SETTINGS") }), namesClickHouseBrake(body) {
      analysis.resetsSessionBrakes = true
    }
    if runsInParallel(body) {
      analysis.kind = .unknown
      analysis.isDestructive = true
    }
    return analysis
  }

  /// ClickHouse `PARALLEL WITH`: the two words next to each other, at any depth. A parenthesized
  /// first statement (`(SELECT 1) PARALLEL WITH …`) puts the chain outside the body's depth, and
  /// no statement nests a chain, so any pair fails closed (over-matching only asks for more).
  private static func runsInParallel(_ body: ArraySlice<SQLToken>) -> Bool {
    zip(body, body.dropFirst()).contains { $0.isWord("PARALLEL") && $1.isWord("WITH") }
  }

  /// DuckDB commands that PostgreSQL classifies differently. Nil leaves the shared rules.
  /// Extension, file, catalog and setting commands are utilities, so read-only, schema
  /// protection and Safe Mode confirmation all stop them. Every PRAGMA (except the catalog reads
  /// on `duckdbReadPragmas`) and SET / RESET counts, because some write
  /// (`PRAGMA enable_profiling`, `SET GLOBAL ...`), and so does `UPDATE EXTENSIONS` (it replaces
  /// extension binaries; a table named `extensions` fails closed). Table functions that read a local file inside a SELECT (`read_csv`,
  /// `read_parquet`, `read_json`) stay reads: the sandbox limits which files they can open, and
  /// the phase-15 session hardening turns off extension autoload and locks the configuration.
  /// A remote URL or a side-effecting function in a read fails closed (`duckdbAdjusted`).
  /// FROM-first (`FROM t [SELECT ...]`), `PIVOT` and `UNPIVOT` are queries, checked like a
  /// SELECT.
  private static func duckdbKind(
    of body: ArraySlice<SQLToken>, keyword: String
  ) -> StatementKind? {
    switch keyword {
    case "UPDATE" where body.dropFirst().first?.isWord("EXTENSIONS") == true: .utility
    case "DESCRIBE", "SUMMARIZE": describedKind(body)
    case "FROM", "PIVOT", "UNPIVOT": selectKind(withoutUnpivotInto(body))
    case "PRAGMA" where isDuckDBReadPragma(body): .read
    case _ where duckdbUtilityKeywords.contains(keyword): .utility
    default: nil
    }
  }

  /// `PRAGMA name` or `PRAGMA name(...)` with `name` on `duckdbReadPragmas`. An assignment, a
  /// schema-qualified name or anything after the call is not. Arguments are checked later
  /// like any read (`duckdbAdjusted`: side-effect functions, remote URLs).
  private static func isDuckDBReadPragma(_ body: ArraySlice<SQLToken>) -> Bool {
    let depth = body.first?.depth ?? 0
    let top = Array(body.dropFirst().filter { $0.depth == depth })
    guard let name = top.first, name.kind == .word, duckdbReadPragmas.contains(name.text)
    else { return false }
    return top.count == 1 || (top.count == 3 && top[1].isSymbol("(") && top[2].isSymbol(")"))
  }

  /// MySQL commands that PostgreSQL classifies differently. Nil leaves the shared rules.
  /// `SET` of `sql_mode` or of the connection charset in any form is a utility: the session pins
  /// both so the lexer matches the server (no `NO_BACKSLASH_ESCAPES` / `ANSI_QUOTES`, and no
  /// GBK / BIG5 / SJIS whose multibyte characters can swallow a backslash). `START` other than `START TRANSACTION`
  /// (`START REPLICA`, ...) is not transaction control. A query that writes a file
  /// (`INTO OUTFILE` / `INTO DUMPFILE`) is a utility. MariaDB `SET STATEMENT ... FOR <stmt>`
  /// runs the trailing statement, so it fails closed; `SET DEFAULT ROLE` changes an account
  /// (like `ALTER USER ... DEFAULT ROLE`), so it is a utility. `REPLACE` as the main statement of
  /// a WITH is a write; `REPLACE` stays off `dmlKeywords`, so the `REPLACE()` function is a read.
  private static func mysqlKind(
    of body: ArraySlice<SQLToken>, keyword: String, topWords: [String]
  ) -> StatementKind? {
    switch keyword {
    case "DESCRIBE", "DESC": mysqlDescribedKind(body)
    case "SET" where topWords.dropFirst().first == "STATEMENT": .unknown
    case "SET" where setsDefaultRole(topWords): .utility
    case "SET" where setsLexerSensitiveVariable(body) || setsServerVariable(topWords): .utility
    case "SET" where setsMySQLBrake(body): .sessionSet(touchesBrake: true)
    case "START" where topWords.dropFirst().first != "TRANSACTION": .utility
    case "XA": .tcl
    case "USE": .sessionSet(touchesBrake: false)
    case "RENAME": .ddl
    case "REPLACE": .dml
    case _ where ["SELECT", "VALUES", "TABLE", "WITH"].contains(keyword) && writesFile(body):
      .utility
    case "WITH" where mainStatementKeyword(afterWith: body) == "REPLACE": .dml
    case _ where mysqlUtilityKeywords.contains(keyword): .utility
    default: nil
    }
  }

  /// MySQL `DESCRIBE` / `DESC` of a table is a read. `DESC SELECT ...` and the other
  /// EXPLAIN forms, or no target, are unrecognized, so they fail closed.
  private static func mysqlDescribedKind(_ body: ArraySlice<SQLToken>) -> StatementKind {
    guard let target = body.dropFirst().first, isIdentifier(target),
      !mysqlExplainableKeywords.contains(target.keyword ?? "")
    else { return .unknown }
    return .read
  }

  /// A word or quoted identifier from `mysqlLexerSensitiveVariables` (`sql_mode`, `NAMES`,
  /// `CHARSET`, `character_set_client`, ...) or the words `CHARACTER SET`, anywhere in the
  /// statement (ASCII case-insensitive). Over-matches (`SET @sql_mode = 1`), which only blocks
  /// more.
  private static func setsLexerSensitiveVariable(_ body: ArraySlice<SQLToken>) -> Bool {
    let namesVariable = body.contains { token in
      guard isIdentifier(token), let text = token.asciiText else { return false }
      return mysqlLexerSensitiveVariables.contains(SQLTokenizer.asciiLowercased(text))
    }
    return namesVariable
      || zip(body, body.dropFirst()).contains { $0.isWord("CHARACTER") && $1.isWord("SET") }
  }

  /// A top-level word or quoted identifier from `mysqlBrakeSettings` (`max_execution_time`,
  /// `wait_timeout`, ...), ASCII case-insensitive. Over-matches (`SET @x = wait_timeout`), which
  /// only asks for more confirmation.
  private static func setsMySQLBrake(_ body: ArraySlice<SQLToken>) -> Bool {
    let depth = body.first?.depth ?? 0
    return body.contains { token in
      guard token.depth == depth, isIdentifier(token), let text = token.asciiText else {
        return false
      }
      return mysqlBrakeSettings.contains(SQLTokenizer.asciiLowercased(text))
    }
  }

  /// `SET DEFAULT ROLE ...` (MySQL `TO user`, MariaDB `FOR user`).
  private static func setsDefaultRole(_ topWords: [String]) -> Bool {
    topWords.starts(with: ["SET", "DEFAULT", "ROLE"])
  }

  /// `GLOBAL`, `PERSIST` or `PERSIST_ONLY` anywhere at the top level of a `SET`: the scope word
  /// or the `@@global.` / `@@persist.` / `@@persist_only.` prefix. These change the server, not
  /// the session. Over-matches (`SET @x = global`), which only blocks more.
  private static func setsServerVariable(_ topWords: [String]) -> Bool {
    topWords.contains { ["GLOBAL", "PERSIST", "PERSIST_ONLY"].contains($0) }
  }

  /// The first keyword of the main statement after a WITH list: the first token at the
  /// statement's depth after a `)` that is neither `,` (the next CTE) nor `AS` (after a column
  /// list). Nil when there is none or it is not a word.
  private static func mainStatementKeyword(afterWith body: ArraySlice<SQLToken>) -> String? {
    mainStatementIndex(afterWith: body).flatMap { body[$0].keyword }
  }

  /// The index in `body` of the token `mainStatementKeyword(afterWith:)` reads.
  private static func mainStatementIndex(afterWith body: ArraySlice<SQLToken>) -> Int? {
    let depth = body.first?.depth ?? 0
    let top = body.indices.filter { body[$0].depth == depth }
    let main = zip(top, top.dropFirst()).first { close, next in
      body[close].isSymbol(")") && !body[next].isSymbol(",") && !body[next].isWord("AS")
    }
    return main?.1
  }

  /// `INTO OUTFILE` or `INTO DUMPFILE` anywhere in the statement.
  private static func writesFile(_ body: ArraySlice<SQLToken>) -> Bool {
    zip(body, body.dropFirst()).contains { into, target in
      into.isWord("INTO") && (target.isWord("OUTFILE") || target.isWord("DUMPFILE"))
    }
  }

  /// `body` without each `INTO` that starts the `UNPIVOT ... INTO NAME n VALUE v` clause, so
  /// only a real `INTO` target makes the query a write.
  private static func withoutUnpivotInto(_ body: ArraySlice<SQLToken>) -> ArraySlice<SQLToken> {
    let tokens = Array(body)
    let kept = tokens.indices.filter { index in
      !(tokens[index].isWord("INTO") && index + 1 < tokens.count
        && tokens[index + 1].isWord("NAME"))
    }
    return ArraySlice(kept.map { tokens[$0] })
  }

  /// DuckDB `DESCRIBE` / `SUMMARIZE` of nothing, a table name or a read query is a read.
  /// Anything else (`DESCRIBE INSERT ...`) is unrecognized, so it fails closed.
  private static func describedKind(_ body: ArraySlice<SQLToken>) -> StatementKind {
    let rest = body.dropFirst()
    if rest.isEmpty || isBarePragmaQuery(Array(body)) { return .read }
    return analyze(rest, dialect: .duckdb).kind == .read ? .read : .unknown
  }

  /// `PRAGMA name` and `PRAGMA schema.name` query the setting. Assignment (`=` or the
  /// parenthesized form) is schema-changing: `journal_mode`, `writable_schema`,
  /// `foreign_keys`, and every other assignment. A bare `PRAGMA` with no name is unrecognized.
  private static func pragmaKind(_ body: ArraySlice<SQLToken>) -> StatementKind {
    let depth = body.first?.depth ?? 0
    let top = body.filter { $0.depth == depth }
    if isBarePragmaQuery(top) { return .read }
    return top.count > 1 ? .ddl : .unknown
  }

  /// `PRAGMA name` or `PRAGMA schema.name`, with nothing assigned (also a DuckDB `DESCRIBE`
  /// target).
  private static func isBarePragmaQuery(_ top: [SQLToken]) -> Bool {
    let rest = top.dropFirst()
    switch rest.count {
    case 1:
      return isIdentifier(rest.first)
    case 3:
      let parts = Array(rest)
      return isIdentifier(parts[0]) && parts[1].isSymbol(".") && isIdentifier(parts[2])
    default:
      return false
    }
  }

  private static func isIdentifier(_ token: SQLToken?) -> Bool {
    token?.kind == .word || token?.kind == .quotedIdentifier
  }

  private static func dialectAdjusted(
    _ analysis: Analysis, body: ArraySlice<SQLToken>, dialect: SQLDialect
  ) -> Analysis {
    switch dialect {
    case .sqlite: sqliteAdjusted(analysis, body: body)
    case .duckdb: duckdbAdjusted(analysis, body: body)
    case .mysql: mysqlAdjusted(analysis, body: body)
    case .sqlserver: sqlserverAdjusted(analysis, body: body)
    case .clickhouse: clickhouseAdjusted(analysis, body: body)
    // Unreachable: `classifyStatement` hands MongoDB and Redis text to their own classifiers.
    case .mongodb, .redis: analysis
    default: analysis
    }
  }

  /// Commands whose effect cannot be checked from the text: another database file, a backup
  /// file, or a native `load_extension(` call. A read, including plain EXPLAIN of one, becomes
  /// a utility so read-only and schema protection both block it.
  private static func sqliteAdjusted(
    _ analysis: Analysis, body: ArraySlice<SQLToken>
  ) -> Analysis {
    var analysis = analysis
    if calls(body, anyOf: [sqliteLoadExtensionFunction]) || containsAttachOrDetach(body)
      || isVacuumInto(body)
    {
      analysis.kind = .utility
    }
    if isVacuumInto(body) { analysis.nonTransactional = true }
    return analysis
  }

  /// MySQL statements that commit the open transaction implicitly cannot run inside the
  /// Protected mode transaction: all DDL (`CREATE TABLE ... AS` and `CREATE TEMPORARY TABLE`
  /// too, which over-blocks), LOCK / UNLOCK TABLES, GRANT / REVOKE, SET PASSWORD,
  /// SET autocommit, ANALYZE / OPTIMIZE / REPAIR / CHECK TABLE, LOAD INDEX, CACHE INDEX, FLUSH,
  /// replication control (START / STOP REPLICA, CHANGE ..., RESET ...) and plugin
  /// installs, and SET DEFAULT ROLE (which also changes privileges). A plain EXPLAIN of one
  /// does not run it. Statements whose body the text does not
  /// show (CALL, EXECUTE, PREPARE, ...) and every unrecognized statement fail closed as an
  /// implicit commit, and so does an executable comment (`/*! ... */`) anywhere, which may run
  /// any of these.
  /// Any statement but a plain EXPLAIN (data changes too) that calls a `mysqlSideEffectFunctions`
  /// function (or one named with a `mysqlSideEffectFunctionPrefixes` prefix) or uses
  /// `NEXT VALUE FOR` becomes a utility, and so does a read, a session `SET`, or any query
  /// starting with SELECT / WITH / VALUES / TABLE (`SELECT ... INTO @var` is a `.dml`) that
  /// locks rows (`FOR UPDATE`, `FOR SHARE`, `LOCK IN SHARE MODE`), so read-only and schema
  /// protection both block it. Best-effort: functions inside views or stored routines are not
  /// seen, and table or index names are not calls (see `mysqlCalls`).
  private static func mysqlAdjusted(
    _ analysis: Analysis, body: ArraySlice<SQLToken>
  ) -> Analysis {
    var analysis = analysis
    if body.contains(where: { $0.kind == .executableComment }) || analysis.kind == .unknown {
      analysis.nonTransactional = true
      return analysis
    }
    let isQuery = ["SELECT", "WITH", "VALUES", "TABLE"].contains(body.first?.keyword ?? "")
    // A plain EXPLAIN is a utility already when its inner statement calls one (see `explain`).
    var isPlainExplain = false
    if case .explain(_, analyze: false) = analysis.kind { isPlainExplain = true }
    let callsSideEffect =
      !isPlainExplain
      && (mysqlCalls(body) || hasMySQLPhrase(body, in: [["NEXT", "VALUE", "FOR"]]))
    let locksRows =
      (analysis.kind == .read || isSessionSet(analysis.kind) || isQuery)
      && hasMySQLPhrase(body, in: mysqlLockingPhrases)
    if let first = body.first?.keyword, first != "EXPLAIN" {
      let depth = body.first?.depth ?? 0
      let topWords = body.filter { $0.kind == .word && $0.depth == depth }.compactMap(\.keyword)
      let second = topWords.dropFirst().first ?? ""
      if setsDefaultRole(topWords) { analysis.changesPrivileges = true }
      let commits =
        switch first {
        case _ where analysis.kind == .ddl: true
        case "SET": second == "PASSWORD" || namesAutocommit(body) || setsDefaultRole(topWords)
        case "START": analysis.kind == .utility
        case "LOAD": second == "INDEX"
        case "RESET": second != "PERSIST"
        default: mysqlImplicitCommitKeywords.contains(first)
        }
      if commits { analysis.nonTransactional = true }
    }
    // Last, so the checks above still see the statement's own kind.
    if callsSideEffect || locksRows { analysis.kind = .utility }
    return analysis
  }

  /// SQL Server runs a batch with no `;` between its statements, so one split statement may
  /// hold several (`SELECT 1 DELETE FROM t`, `SET NOCOUNT ON DROP TABLE t`). A read, transaction
  /// control, session SET or data change with a `sqlserverStatementVerbs` word after its own
  /// verb, at any depth, fails closed as `.unknown` (`strayStatementVerb`), and so does
  /// transaction control or a session SET with a SELECT at its own depth or an INTO at any depth
  /// after its verb (`SET NOCOUNT ON SELECT * INTO t2 FROM t`; a subquery such as
  /// `SET @x = (SELECT ...)` keeps its kind). DDL and utilities keep their kind: a procedure or
  /// trigger body holds statements, and both are refused or confirmed already.
  /// `SET IMPLICIT_TRANSACTIONS` / `SET ANSI_DEFAULTS` is a utility that cannot run in a
  /// transaction: once on, every statement opens a transaction the app does not track, and the
  /// app's own `BEGIN TRAN` nests, so its COMMIT would not commit. `SET XACT_ABORT` too: a
  /// run-time error then rolls the whole transaction back. `EXEC` / `EXECUTE` cannot run in the
  /// app's transaction either (a procedure may commit or roll back), and `EXECUTE AS` switches
  /// the privilege context. A read, data change or session SET that names a
  /// `sqlserverRemoteRowsets` function becomes a utility. Any statement (a block, a batch, a
  /// GRANT followed by more) affects all rows when an UPDATE / DELETE in it has no WHERE
  /// (`sqlserverAffectsAllRows`).
  private static func sqlserverAdjusted(
    _ analysis: Analysis, body: ArraySlice<SQLToken>
  ) -> Analysis {
    var analysis = analysis
    let depth = body.first?.depth ?? 0
    let topWords = body.filter { $0.depth == depth }.compactMap(\.keyword)
    if topWords.first == "SET", topWords.contains(where: sqlserverTransactionOptions.contains) {
      analysis.kind = .utility
      analysis.nonTransactional = true
    }
    if topWords.first == "EXEC" || topWords.first == "EXECUTE" {
      analysis.nonTransactional = true
      if topWords.dropFirst().first == "AS" { analysis.changesPrivileges = true }
    }
    switch analysis.kind {
    case .read, .dml:
      if strayStatementVerb(body) { analysis.kind = .unknown }
    case .tcl, .sessionSet:
      let query = body.dropFirst().contains {
        ($0.isWord("SELECT") && $0.depth == depth) || $0.isWord("INTO")
      }
      if query || strayStatementVerb(body) { analysis.kind = .unknown }
    default: break
    }
    switch analysis.kind {
    case .read, .dml, .sessionSet:
      if body.contains(where: { sqlserverRemoteRowsets.contains($0.keyword ?? "") }) {
        analysis.kind = .utility
      }
    default: break
    }
    analysis.affectsAllRows = analysis.affectsAllRows || sqlserverAffectsAllRows(body)
    return analysis
  }

  /// Some UPDATE / DELETE, at any position and depth, with no WHERE in its own scope: the
  /// tokens after it at its depth or deeper, up to the next statement verb, `SELECT`, `END` or
  /// `;` at its depth (an UPDATE's first `SET` belongs to it). Skipped only where the position
  /// says the word is no statement (`isNoSQLServerStatement`); when unsure it counts.
  private static func sqlserverAffectsAllRows(_ body: ArraySlice<SQLToken>) -> Bool {
    body.indices.contains { index in
      let verb = body[index]
      guard verb.isWord("UPDATE") || verb.isWord("DELETE") else { return false }
      if isNoSQLServerStatement(body, at: index) { return false }
      var ownSet = verb.isWord("UPDATE")
      for token in body[(index + 1)...] {
        if token.depth < verb.depth { break }
        guard token.depth == verb.depth else { continue }
        if token.isWord("WHERE") { return false }
        if ownSet, token.isWord("SET") {
          ownSet = false
          continue
        }
        let word = token.keyword ?? ""
        if token.isSymbol(";") || word == "SELECT" || word == "END"
          || sqlserverStatementVerbs.contains(word)
        {
          break
        }
      }
      return true
    }
  }

  /// The UPDATE / DELETE at `index` names no statement: a foreign key action (`ON DELETE` /
  /// `ON UPDATE` followed by CASCADE, NO ACTION, SET NULL or SET DEFAULT), a MERGE arm (`THEN`
  /// after a MERGE at its depth), the `UPDATE(column)` test after IF / AND / OR / NOT, an event
  /// of a `CREATE` / `ALTER TRIGGER` before its AS (after FOR, AFTER, OF or a comma), or a
  /// permission of a GRANT / DENY / REVOKE before its TO / FROM. Every word these checks rely on
  /// is reserved in T-SQL, unlike AFTER alone (a valid alias).
  private static func isNoSQLServerStatement(_ body: ArraySlice<SQLToken>, at index: Int) -> Bool {
    let verb = body[index]
    let previous = index > body.startIndex ? body[index - 1] : nil
    let next = body[(index + 1)...].prefix(2).map { $0.keyword ?? "" }
    if previous?.isWord("ON") == true,
      next.first == "CASCADE" || next == ["NO", "ACTION"] || next == ["SET", "NULL"]
        || next == ["SET", "DEFAULT"]
    {
      return true
    }
    let before = body[..<index].reversed().filter { $0.depth == verb.depth }
    if previous?.isWord("THEN") == true, before.contains(where: { $0.isWord("MERGE") }) {
      return true
    }
    if verb.isWord("UPDATE"), index + 1 < body.endIndex, body[index + 1].isSymbol("("),
      ["IF", "AND", "OR", "NOT"].contains(previous?.keyword ?? "")
    {
      return true
    }
    // The nearest header word back at this depth decides
    for (offset, token) in before.enumerated() {
      switch token.keyword ?? "" {
      case "AS", "TO", "FROM", "SELECT", "BEGIN", "END":
        return false
      case "GRANT", "DENY", "REVOKE":
        return inPermissionList(before, header: offset)
      case "TRIGGER":
        let creates = before.dropFirst(offset + 1).first.map {
          $0.isWord("CREATE") || $0.isWord("ALTER")
        }
        let event =
          ["FOR", "AFTER", "OF"].contains(previous?.keyword ?? "")
          || previous?.isSymbol(",") == true
        return creates == true && event
      default:
        continue
      }
    }
    return false
  }

  /// Whether the candidate `isNoSQLServerStatement` scans back from sits in the permission list
  /// of the GRANT / DENY / REVOKE at `before[header]` (`before` runs backward from it): only
  /// permission words, commas and parentheses (a column list) between them, after a leading
  /// `GRANT OPTION FOR` of a REVOKE. A GRANT after WITH (`WITH GRANT OPTION`) is no header.
  private static func inPermissionList(_ before: [SQLToken], header: Int) -> Bool {
    let earlier = before.dropFirst(header + 1).first
    if earlier?.isWord("WITH") == true { return false }
    var between = before[..<header].reversed().map { $0 }
    if before[header].isWord("GRANT"), earlier?.isWord("REVOKE") == true {
      guard between.count >= 2, between[0].isWord("OPTION"), between[1].isWord("FOR") else {
        return false
      }
      between.removeFirst(2)
    }
    return between.allSatisfy { token in
      token.isSymbol(",") || token.isSymbol("(") || token.isSymbol(")")
        || sqlserverPermissionWords.contains(token.keyword ?? "")
    }
  }

  /// Words of a T-SQL permission list (`GRANT UPDATE, DELETE ...`, `VIEW DEFINITION`, ...)
  private static let sqlserverPermissionWords: Set<String> = [
    "SELECT", "INSERT", "UPDATE", "DELETE", "EXECUTE", "EXEC", "REFERENCES", "ALTER", "CONTROL",
    "ALL", "PRIVILEGES", "VIEW", "DEFINITION", "TAKE", "OWNERSHIP", "IMPERSONATE", "RECEIVE",
    "SEND", "CONNECT", "CHANGE", "TRACKING",
  ]

  /// A `sqlserverStatementVerbs` word, at any depth, after the statement's own verb (the data
  /// change after a WITH list, else the first word) that is not part of that statement:
  /// the first `SET` of an UPDATE, the `THEN UPDATE` / `INSERT` / `DELETE` arms of a MERGE and
  /// the `SET` of its `UPDATE`, `MERGE JOIN` / `MERGE UNION`, `USE HINT` / `USE PLAN` query
  /// hints inside parentheses (`OPTION (...)`), and `FETCH` after `OFFSET n ROW[S]`. Fails closed: an unquoted column named like a
  /// verb counts (T-SQL reserves most of them; `[name]` is a quoted identifier, not a word).
  /// A `sqlserverConversationVerbs` word counts only before CONVERSATION (`END CONVERSATION`;
  /// a CASE alias named `conversation` fails closed too).
  private static func strayStatementVerb(_ body: ArraySlice<SQLToken>) -> Bool {
    guard let start = body.indices.first else { return false }
    // A WITH list leads to a SELECT or a data change; anything else after it counts
    let main = body[start].isWord("WITH") ? mainStatementIndex(afterWith: body) : nil
    let own = main.flatMap { dmlKeywords.contains(body[$0].keyword ?? "") ? $0 : nil } ?? start
    let verb = body[own].keyword ?? ""
    let updateSet =
      verb == "UPDATE"
      ? body[(own + 1)...].firstIndex { $0.isWord("SET") && $0.depth == body[own].depth } : nil
    return body.indices.contains { index in
      guard index != start, index != own, index != updateSet, let word = body[index].keyword
      else { return false }
      let next = index + 1 < body.endIndex ? body[index + 1].keyword ?? "" : ""
      if sqlserverConversationVerbs.contains(word) { return next == "CONVERSATION" }
      guard sqlserverStatementVerbs.contains(word) else { return false }
      let previous = body[index - 1].keyword ?? ""
      switch word {
      case "MERGE": return next != "JOIN" && next != "UNION"
      // A query hint only inside `OPTION (...)`; at the statement's depth `USE` runs
      case "USE":
        return !(["HINT", "PLAN"].contains(next) && body[index].depth > body[start].depth)
      case "FETCH": return !followsOffsetRows(body, fetch: index)
      case "UPDATE", "INSERT", "DELETE": return !(verb == "MERGE" && previous == "THEN")
      case "SET": return !(verb == "MERGE" && previous == "UPDATE")
      default: return true
      }
    }
  }

  /// `OFFSET <value> ROW[S]` right before the `FETCH` at `fetch`, at its depth: the value is one
  /// word or number, a variable (`@` and a word), or a parenthesized expression.
  private static func followsOffsetRows(_ body: ArraySlice<SQLToken>, fetch: Int) -> Bool {
    let depth = body[fetch].depth
    let rows = fetch - 1
    guard rows > body.startIndex, body[rows].depth == depth,
      body[rows].isWord("ROW") || body[rows].isWord("ROWS")
    else { return false }
    var offset = rows - 1
    if body[offset].isSymbol(")") {
      guard
        let open = body[..<offset].lastIndex(where: { $0.isSymbol("(") && $0.depth == depth })
      else { return false }
      offset = open - 1
    } else {
      guard body[offset].kind == .word else { return false }
      offset -= 1
      if offset >= body.startIndex, body[offset].isSymbol("@") { offset -= 1 }
    }
    return offset >= body.startIndex && body[offset].depth == depth
      && body[offset].isWord("OFFSET")
  }

  private static func isSessionSet(_ kind: StatementKind) -> Bool {
    if case .sessionSet = kind { return true }
    return false
  }

  /// A word or quoted identifier `autocommit` (ASCII case-insensitive) anywhere in the statement.
  private static func namesAutocommit(_ body: ArraySlice<SQLToken>) -> Bool {
    body.contains { token in
      guard isIdentifier(token), let text = token.asciiText else { return false }
      return SQLTokenizer.asciiLowercased(text) == "autocommit"
    }
  }

  /// Row-locking clauses: `FOR UPDATE`, `FOR SHARE`, `LOCK IN SHARE MODE`.
  private static let mysqlLockingPhrases: [[String]] = [
    ["FOR", "UPDATE"], ["FOR", "SHARE"], ["LOCK", "IN", "SHARE", "MODE"],
  ]

  /// One of `phrases` (uppercase keyword sequences) at any depth.
  private static func hasMySQLPhrase(_ body: ArraySlice<SQLToken>, in phrases: [[String]]) -> Bool {
    let words = body.map { $0.keyword ?? "" }
    return words.indices.contains { index in
      phrases.contains { words[index...].starts(with: $0) }
    }
  }

  /// A DuckDB read that calls a `duckdbSideEffectFunctions` function (or one named with a
  /// `duckdbSideEffectFunctionPrefixes` prefix) or names a remote URL (`namesRemoteURL`)
  /// becomes a utility, so read-only and schema protection both block it (plain EXPLAIN of one
  /// too). `UPDATE EXTENSIONS` has no rows to warn about.
  /// Best-effort only: it sees function names and single literals in the text, not what runs.
  /// See `namesRemoteURL` for what it misses; the phase-15 DuckDB session hardening
  /// (`enable_external_access=false` with `allowed_directories` / `allowed_paths`, extension
  /// autoinstall / autoload off, `lock_configuration=true`) is what enforces external access.
  private static func duckdbAdjusted(
    _ analysis: Analysis, body: ArraySlice<SQLToken>
  ) -> Analysis {
    var analysis = analysis
    if analysis.kind == .read,
      calls(
        body, anyOf: duckdbSideEffectFunctions, orPrefixes: duckdbSideEffectFunctionPrefixes)
        || namesRemoteURL(body)
    {
      analysis.kind = .utility
    }
    if analysis.kind == .utility, body.first?.isWord("UPDATE") == true {
      analysis.affectsAllRows = false
    }
    return analysis
  }

  /// A call `name(` at any depth to one of `names` (uppercase), to a name starting with one
  /// of `prefixes` or containing one of `infixes` (uppercase), including a quoted, bracketed, or
  /// backticked name. A mention inside a string or comment is not a call: those are not word
  /// tokens.
  static func calls(
    _ body: ArraySlice<SQLToken>, anyOf names: Set<String>, orPrefixes prefixes: [String] = [],
    orContaining infixes: [String] = []
  ) -> Bool {
    body.indices.contains { index in
      let next = body.index(after: index)
      guard next < body.endIndex, body[next].isSymbol("("),
        let name = functionName(body[index])
      else { return false }
      return names.contains(name) || prefixes.contains { name.hasPrefix($0) }
        || infixes.contains { name.contains($0) }
    }
  }

  /// `calls` with the MySQL side-effect lists, skipping a name that cannot be a built-in or
  /// UDF call: a schema-qualified name (`db.name(`: built-ins and UDFs live in the global
  /// namespace) and a table or index name followed by a column list (after `INTO`, `TABLE`,
  /// `UPDATE`, `REFERENCES`, `INDEX`, `KEY`, after the leading
  /// `INSERT` / `REPLACE` words, and after `ON` in `CREATE ... INDEX`).
  private static func mysqlCalls(_ body: ArraySlice<SQLToken>) -> Bool {
    let leading = mysqlInsertLeadingWords(body)
    let createsIndex = isMySQLCreateIndex(body)
    return body.indices.contains { index in
      let next = body.index(after: index)
      guard next < body.endIndex, body[next].isSymbol("("),
        let name = functionName(body[index])
      else { return false }
      if index > body.startIndex {
        let previousIndex = body.index(before: index)
        let previous = body[previousIndex]
        if previous.isSymbol(".") || previousIndex < leading { return false }
        let word = previous.keyword ?? ""
        if mysqlTableNameContextWords.contains(word) || (createsIndex && word == "ON") {
          return false
        }
      }
      return mysqlSideEffectFunctions.contains(name)
        || mysqlSideEffectFunctionPrefixes.contains { name.hasPrefix($0) }
    }
  }

  /// Words after which a name followed by `(` is a table or index name, not a call.
  private static let mysqlTableNameContextWords: Set<String> = [
    "INTO", "TABLE", "UPDATE", "REFERENCES", "INDEX", "KEY",
  ]

  /// The end of the leading `INSERT` / `REPLACE` words and modifiers (`INSERT IGNORE`,
  /// `REPLACE LOW_PRIORITY`, ...) before the table name, which may follow without `INTO`.
  /// The start index when the statement is no INSERT / REPLACE.
  private static func mysqlInsertLeadingWords(_ body: ArraySlice<SQLToken>) -> Int {
    guard ["INSERT", "REPLACE"].contains(body.first?.keyword ?? "") else {
      return body.startIndex
    }
    let modifiers: Set<String> = ["LOW_PRIORITY", "DELAYED", "HIGH_PRIORITY", "IGNORE"]
    var end = body.index(after: body.startIndex)
    while end < body.endIndex, modifiers.contains(body[end].keyword ?? "") {
      end = body.index(after: end)
    }
    return end
  }

  /// `CREATE [OR REPLACE] [UNIQUE | FULLTEXT | SPATIAL] [ONLINE | OFFLINE] INDEX ...`, which
  /// has no joins, so the name after its `ON` is the indexed table.
  private static func isMySQLCreateIndex(_ body: ArraySlice<SQLToken>) -> Bool {
    guard body.first?.isWord("CREATE") == true else { return false }
    let modifiers: Set<String> = [
      "OR", "REPLACE", "UNIQUE", "FULLTEXT", "SPATIAL", "ONLINE", "OFFLINE",
    ]
    let words = body.dropFirst().prefix { $0.kind == .word }.compactMap(\.keyword)
    return words.first { !modifiers.contains($0) } == "INDEX"
  }

  /// The uppercased name of a word or quoted-identifier token, else nil.
  private static func functionName(_ token: SQLToken) -> String? {
    if let word = token.keyword { return word }
    guard token.kind == .quotedIdentifier, let text = token.asciiText else { return nil }
    return SQLTokenizer.asciiUppercased(text)
  }

  /// A string (dollar-quoted after its opening tag) or quoted identifier whose text starts
  /// with a remote URL scheme, ASCII case-insensitive. A string with a backslash is also
  /// checked after `E'...'` decoding (`decodingDuckDBEscapes`): tokens do not say whether the
  /// string had the `E` prefix, so a plain string that decodes to a URL fails closed too.
  /// Best-effort only. It misses URLs built at run time (`||`, `concat`, `format`, `replace`),
  /// bound parameters (`$1`, `?`), URLs inside macros, views or prepared statements, and
  /// adjacent literals joined across a newline (`'https:'` newline `'//h/x'`, DuckDB's
  /// `quotecontinue`). The phase-15 session (`enable_external_access=false` with
  /// `allowed_directories` / `allowed_paths`, `lock_configuration=true`) blocks those.
  static func namesRemoteURL(_ body: ArraySlice<SQLToken>) -> Bool {
    body.contains { token in
      guard token.kind == .string || token.kind == .quotedIdentifier else { return false }
      let text = withoutDollarTag(token.text)
      var candidates = [text]
      if token.kind == .string, text.unicodeScalars.contains("\\") {
        candidates.append(decodingDuckDBEscapes(text))
      }
      // By scalar: DuckDB matches the scheme by bytes, so a mark fused onto `/` stays remote.
      return candidates.contains { candidate in
        let lowered = SQLTokenizer.asciiLowercased(candidate).unicodeScalars
        return duckdbRemoteSchemes.contains { lowered.starts(with: $0.unicodeScalars) }
      }
    }
  }

  /// `text` with DuckDB `E'...'` backslash escapes decoded as DuckDB's scanner does
  /// (`third_party/libpg_query/scan.l`, DuckDB 1.4 / 1.5): `\xH` / `\xHH` hex and `\O` to
  /// `\OOO` octal (one byte: DuckDB stores `strtoul` in an `unsigned char`, so `\400`-`\777`
  /// keep their low 8 bits; kept as the scalar of that byte), `\uHHHH` / `\UHHHHHHHH`,
  /// `\b \f \n \r \t`, and `\c` as `c` for any other `c`. DuckDB's docs list only the five
  /// control escapes; the scanner decodes all of these. An invalid code point stops decoding
  /// (DuckDB rejects the literal).
  private static func decodingDuckDBEscapes(_ text: String) -> String {
    let s = Array(text.unicodeScalars)
    var result = String.UnicodeScalarView()
    var i = 0
    while i < s.count {
      guard s[i] == "\\", i + 1 < s.count else {
        result.append(s[i])
        i += 1
        continue
      }
      let next = s[i + 1]
      let decoded: (value: UInt32, length: Int)?
      switch next {
      case "x": decoded = number(in: s, from: i + 2, radix: 16, maxDigits: 2)
      case "0"..."7":
        decoded = number(in: s, from: i + 1, radix: 8, maxDigits: 3).map {
          ($0.value & 0xFF, $0.length)
        }
      case "u": decoded = number(in: s, from: i + 2, radix: 16, exactDigits: 4)
      case "U": decoded = number(in: s, from: i + 2, radix: 16, exactDigits: 8)
      default: decoded = nil
      }
      if let decoded {
        guard let scalar = Unicode.Scalar(decoded.value) else { break }
        result.append(scalar)
        i += (next == "x" || next == "u" || next == "U" ? 2 : 1) + decoded.length
        continue
      }
      result.append(controlEscapes[next] ?? next)
      i += 2
    }
    return String(result)
  }

  private static let controlEscapes: [Unicode.Scalar: Unicode.Scalar] = [
    "b": "\u{08}", "f": "\u{0C}", "n": "\n", "r": "\r", "t": "\t",
  ]

  /// Digits of `radix` at `start`: up to `maxDigits` (at least one), or exactly `exactDigits`.
  private static func number(
    in s: [Unicode.Scalar], from start: Int, radix: Int, maxDigits: Int? = nil,
    exactDigits: Int? = nil
  ) -> (value: UInt32, length: Int)? {
    let limit = exactDigits ?? maxDigits ?? 0
    var digits = ""
    var j = start
    while j < s.count, digits.count < limit, s[j].isASCII,
      Int(String(s[j]), radix: radix) != nil
    {
      digits.unicodeScalars.append(s[j])
      j += 1
    }
    if digits.isEmpty || (exactDigits.map { digits.count != $0 } ?? false) { return nil }
    return UInt32(digits, radix: radix).map { ($0, digits.count) }
  }

  /// `text` after an opening `$$` / `$tag$`, else `text` unchanged.
  /// By scalar: a `$` followed by a combining mark is one `Character`, but still a tag.
  private static func withoutDollarTag(_ text: String) -> String {
    let scalars = text.unicodeScalars
    guard scalars.first == "$", let close = scalars.dropFirst().firstIndex(of: "$") else {
      return text
    }
    return String(scalars[scalars.index(after: close)...])
  }

  /// `ATTACH` / `DETACH` as the statement, or the same words inside a `WITH` (a column named
  /// `attach` there counts, the same way a column named `update` does).
  private static func containsAttachOrDetach(_ body: ArraySlice<SQLToken>) -> Bool {
    if let keyword = body.first?.keyword, sqliteUtilityKeywords.contains(keyword) {
      return true
    }
    guard body.first?.isWord("WITH") == true else { return false }
    return !statementStarts(in: body, keywords: sqliteUtilityKeywords).isEmpty
  }

  /// `VACUUM INTO`, as its own statement or after `WITH` / `EXPLAIN`. A `SELECT` that merely
  /// mentions both words is left alone.
  private static func isVacuumInto(_ body: ArraySlice<SQLToken>) -> Bool {
    let starts: [Int]
    if body.first?.isWord("VACUUM") == true {
      starts = [body.startIndex]
    } else if body.first?.isWord("WITH") == true || body.first?.isWord("EXPLAIN") == true {
      starts = statementStarts(in: body, keywords: ["VACUUM"])
    } else {
      return false
    }
    return starts.contains { index in
      let depth = body[index].depth
      let rest = body[body.index(after: index)...].prefix { $0.depth >= depth }
      return rest.contains { $0.depth == depth && $0.isWord("INTO") }
    }
  }

  /// SELECT / VALUES / TABLE. PostgreSQL rejects a data-modifying WITH below the top level, so a
  /// DML keyword nested in parentheses (other than a row lock) means the text is not what it
  /// seems: `.unknown`. An unquoted INTO (a reserved word) at any depth can only be
  /// SELECT ... INTO (turned into CREATE TABLE AS) or a syntax error: `.dml`. DML keywords at
  /// the outermost depth are not scanned (unreserved column names such as `update`).
  private static func selectKind(_ body: ArraySlice<SQLToken>) -> StatementKind {
    let outermost = body.map(\.depth).min() ?? 0
    let nested = statementStarts(in: body, keywords: dmlKeywords).filter {
      body[$0].depth > outermost
    }
    if !nested.isEmpty { return .unknown }
    return body.contains { $0.isWord("INTO") } ? .dml : .read
  }

  private static func hasDataModifyingPart(_ body: ArraySlice<SQLToken>) -> Bool {
    !statementStarts(in: body, keywords: dmlKeywords).isEmpty
  }

  /// In a WITH statement, a DML keyword at any depth starts a data-modifying part: it may
  /// follow `(`, `)` or a SEARCH / CYCLE clause, and a CTE body may itself be a nested WITH.
  /// Only `FOR [NO KEY] UPDATE` row locks and `ON CONFLICT DO UPDATE` are excluded.
  /// Fails closed (a column named `update` counts).
  private static func statementStarts(
    in body: ArraySlice<SQLToken>, keywords: Set<String>
  ) -> [Int] {
    body.indices.filter { index in
      guard index > body.startIndex, let word = body[index].keyword, keywords.contains(word)
      else { return false }
      return !isRowLockOrUpsert(body, at: index)
    }
  }

  /// `UPDATE` preceded by `FOR`, `FOR NO KEY` or `DO`.
  private static func isRowLockOrUpsert(_ body: ArraySlice<SQLToken>, at index: Int) -> Bool {
    guard body[index].isWord("UPDATE") else { return false }
    let before = body[..<index].suffix(3).map { $0.keyword ?? "" }
    return before.last == "FOR" || before.last == "DO" || before == ["FOR", "NO", "KEY"]
  }

  /// True if any UPDATE/DELETE (the statement itself, or a WITH part) lacks a WHERE at its level.
  private static func affectsAllRows(_ body: ArraySlice<SQLToken>) -> Bool {
    guard let first = body.first else { return false }
    let writeKeywords: Set<String> = ["UPDATE", "DELETE"]
    var starts: [Int] = []
    if writeKeywords.contains(first.keyword ?? "") {
      starts.append(body.startIndex)
    } else if first.isWord("WITH") {
      starts = statementStarts(in: body, keywords: writeKeywords)
    }
    return starts.contains { start in
      let depth = body[start].depth
      let scope = body[body.index(after: start)...].prefix { $0.depth >= depth }
      return !scope.contains { $0.depth == depth && $0.isWord("WHERE") }
    }
  }

  /// A DML SELECT / VALUES / TABLE / WITH with an INTO that is not `INSERT INTO` / `MERGE INTO`
  /// starting a statement or CTE body (after `(` or `)`). Fails closed: an INTO after a column
  /// named `insert`, or an INSERT after a SEARCH / CYCLE clause, counts.
  private static func createsTable(_ body: ArraySlice<SQLToken>, kind: StatementKind) -> Bool {
    guard kind == .dml, ["SELECT", "VALUES", "TABLE", "WITH"].contains(body.first?.keyword ?? "")
    else { return false }
    return body.indices.contains { index in
      guard body[index].isWord("INTO") else { return false }
      let before = body[..<index].suffix(2)
      guard before.count == 2, let verb = before.last, let opener = before.first else {
        return true
      }
      let startsWrite = verb.isWord("INSERT") || verb.isWord("MERGE")
      return !(startsWrite && (opener.isSymbol("(") || opener.isSymbol(")")))
    }
  }

  private static func nonTransactional(_ topWords: [String]) -> Bool {
    guard let first = topWords.first else { return false }
    let second = topWords.dropFirst().first ?? ""
    switch first {
    case "VACUUM": return true
    case "CREATE" where second == "DATABASE" || second == "TABLESPACE": return true
    case "DROP" where second == "DATABASE" || second == "TABLESPACE": return true
    case "ALTER" where second == "SYSTEM": return true
    case "REINDEX" where second == "SYSTEM" || second == "DATABASE": return true
    default: return topWords.contains("CONCURRENTLY")
    }
  }

  /// SET/RESET of a brake GUC, SET [SESSION CHARACTERISTICS AS] TRANSACTION, or RESET ALL.
  private static func touchesBrake(_ body: ArraySlice<SQLToken>) -> Bool {
    var tokens = body.dropFirst()
    let isSet = body.first?.isWord("SET") ?? false
    if isSet, let scope = tokens.first, scope.isWord("SESSION") || scope.isWord("LOCAL") {
      tokens = tokens.dropFirst()
      if tokens.first?.isWord("CHARACTERISTICS") ?? false { return true }
    }
    // SET [LOCAL | SESSION] SESSION CHARACTERISTICS AS TRANSACTION ...
    if isSet, tokens.first?.isWord("SESSION") ?? false,
      tokens.dropFirst().first?.isWord("CHARACTERISTICS") ?? false
    {
      return true
    }
    guard let name = tokens.first,
      name.kind == .word || name.kind == .quotedIdentifier
    else { return false }
    if isSet && name.isWord("TRANSACTION") { return true }
    if !isSet && name.isWord("ALL") { return true }
    // GUC names compare ASCII case-insensitively even when quoted (guc_name_compare).
    return brakeSettings.contains(name.asciiText.map(SQLTokenizer.asciiLowercased) ?? "")
  }

  /// BEGIN / START TRANSACTION with a READ WRITE mode (overrides default_transaction_read_only).
  private static func beginsReadWrite(_ topWords: [String]) -> Bool {
    guard topWords.first == "BEGIN" || topWords.first == "START" else { return false }
    return zip(topWords, topWords.dropFirst()).contains { $0 == "READ" && $1 == "WRITE" }
  }

  /// SET [SESSION | LOCAL] ROLE / SESSION AUTHORIZATION / role / session_authorization, and
  /// RESET of the same. GUC names compare ASCII case-insensitively even when quoted.
  private static func changesPrivileges(_ body: ArraySlice<SQLToken>) -> Bool {
    guard let verb = body.first, verb.isWord("SET") || verb.isWord("RESET") else { return false }
    var rest = body.dropFirst()
    if verb.isWord("SET"), let scope = rest.first, scope.isWord("SESSION") || scope.isWord("LOCAL")
    {
      rest = rest.dropFirst()
    }
    guard let name = rest.first else { return false }
    let next = rest.dropFirst().first
    if name.isWord("AUTHORIZATION")
      || (name.isWord("SESSION") && next?.isWord("AUTHORIZATION") == true)
    {
      return true
    }
    guard name.kind == .word || name.kind == .quotedIdentifier else { return false }
    return privilegeSettings.contains(name.asciiText.map(SQLTokenizer.asciiLowercased) ?? "")
  }

  /// EXPLAIN [ANALYZE] [VERBOSE] stmt, or EXPLAIN (option [value], ...) stmt.
  /// Option names: words fold ASCII case; quoted identifiers are not folded (as in
  /// PostgreSQL) and match only in lowercase. An unrecognized option yields `.unknown`, and
  /// ANALYZE counts unless its value is plainly false (ASCII case-insensitive, like parse_bool).
  private static func explain(
    _ body: ArraySlice<SQLToken>, dialect: SQLDialect
  ) -> Analysis {
    if dialect == .sqlite { return sqliteExplain(body) }
    var rest = body.dropFirst()
    var isAnalyze = false
    if let open = rest.first, open.isSymbol("("),
      let option = rest.dropFirst().first, explainOptions.contains(optionName(option))
    {
      let options = rest.dropFirst().prefix { !($0.isSymbol(")") && $0.depth == open.depth) }
      let items = options.split { $0.isSymbol(",") && $0.depth == open.depth + 1 }
      for item in items {
        guard let name = item.first, explainOptions.contains(optionName(name)) else {
          return Analysis(kind: .unknown)
        }
        guard ["ANALYZE", "ANALYSE"].contains(optionName(name)) else { continue }
        let values = item.dropFirst()
        let isOff =
          values.count == 1
          && ["FALSE", "OFF", "0", "NO"].contains(
            values.first?.asciiText.map(SQLTokenizer.asciiUppercased) ?? "")
        isAnalyze = isAnalyze || !isOff
      }
      rest = rest.dropFirst(options.count + 2)
    } else {
      while let word = rest.first, isAnalyzeWord(word) || word.isWord("VERBOSE") {
        isAnalyze = isAnalyze || isAnalyzeWord(word)
        rest = rest.dropFirst()
      }
    }
    // MySQL `EXPLAIN [ANALYZE] FORMAT = name stmt`
    if dialect == .mysql, rest.first?.isWord("FORMAT") == true,
      rest.dropFirst().first?.isSymbol("=") == true, rest.count > 3
    {
      rest = rest.dropFirst(3)
    }
    let inner = analyze(rest, dialect: dialect)
    // DuckDB may bind or run an extension, file or setting command while planning it.
    // MySQL evaluates cheap uncorrelated subqueries (and their function calls) while planning.
    if [.duckdb, .mysql].contains(dialect), !isAnalyze, inner.kind == .utility {
      return Analysis(kind: .utility)
    }
    guard isAnalyze else { return Analysis(kind: .explain(inner: inner.kind, analyze: false)) }
    return Analysis(
      kind: .explain(inner: inner.kind, analyze: true), hasReturning: inner.hasReturning,
      hasTopLevelReturning: inner.hasTopLevelReturning,
      affectsAllRows: inner.affectsAllRows, nonTransactional: inner.nonTransactional,
      resetsSessionBrakes: inner.resetsSessionBrakes, changesPrivileges: inner.changesPrivileges,
      createsTable: inner.createsTable)
  }

  /// SQLite `EXPLAIN` and `EXPLAIN QUERY PLAN` return a grid. They do not run the statement,
  /// so Analyze stays off (`supportsExplainAnalyze` is false for this engine).
  private static func sqliteExplain(_ body: ArraySlice<SQLToken>) -> Analysis {
    var rest = body.dropFirst()
    if rest.first?.isWord("QUERY") == true, rest.dropFirst().first?.isWord("PLAN") == true {
      rest = rest.dropFirst(2)
    }
    let inner = analyze(rest, dialect: .sqlite)
    return Analysis(kind: .explain(inner: inner.kind, analyze: false))
  }

  /// Leading verb is CREATE/ALTER ROLE or CREATE/ALTER USER, and not USER MAPPING.
  private static func isRoleOrUserAdmin(_ words: [String]) -> Bool {
    guard words.count >= 2 else { return false }
    let createsOrAlters = words[0] == "CREATE" || words[0] == "ALTER"
    let roleOrUser = words[1] == "ROLE" || words[1] == "USER"
    guard createsOrAlters, roleOrUser else { return false }
    if words[1] == "USER", words.count >= 3, words[2] == "MAPPING" { return false }
    return true
  }

  private static func isAnalyzeWord(_ token: SQLToken) -> Bool {
    token.isWord("ANALYZE") || token.isWord("ANALYSE")
  }

  /// Uppercased EXPLAIN option name for a word or an all-lowercase quoted identifier, else "".
  private static func optionName(_ token: SQLToken) -> String {
    if let word = token.keyword { return word }
    guard token.kind == .quotedIdentifier, let text = token.asciiText,
      SQLTokenizer.asciiLowercased(text) == text
    else { return "" }
    return SQLTokenizer.asciiUppercased(text)
  }
}
