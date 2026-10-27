// DatabaseConnectionManager+Restore.swift
// Restore of a Dblore SQL dump (`SQLDumpWriter`) through the gate. `SQLRestorePlan` reads the
// script once: the 64 MiB cap, the header engine, one split, then every statement is classified
// and must be a statement shape the dump writer emits for that engine (leading tokens; a data
// INSERT is read to its end and may hold only the literals the writer emits). PostgreSQL catalog
// text prints plain `'...'` strings with a backslash (`'^\d+$'`): such a schema statement is
// read as `standard_conforming_strings = on` reads it, and runs only once the session says on.
// `executeGatedRestore` checks the plan against the merged policy before anything is sent.
// PostgreSQL and SQLite run it as one staged batch (atomic; inside the app transaction under
// Protected mode). DuckDB runs it as one staged batch too, but has no SAVEPOINT, so it is
// refused under Protected mode and with a transaction open. MySQL commits each schema change at
// once, so it runs one statement at a time (refused with a transaction open or under Protected
// mode) and afterwards always resets the session settings the dump changed, or closes the
// session when that fails.

import Foundation

/// What a restored statement is, for the confirmation and history
nonisolated enum SQLRestoreStatementKind: String, Sendable, CaseIterable {
  /// CREATE of schemas, types, domains, sequences, tables, indexes and views, and the dump's
  /// `ALTER ... ADD CONSTRAINT` / `ALTER SEQUENCE ... OWNED BY`
  case schema
  /// SQLite `CREATE TRIGGER ... BEGIN ...; END` (one statement, see `sqliteSplitStatements`)
  case trigger
  /// INSERT, and SQLite's `DELETE FROM sqlite_sequence WHERE name = '...'`
  case data
  /// PostgreSQL `SELECT pg_catalog.setval(...)`: a Protected-mode Rollback does not undo it
  case sequenceValue
  /// The MySQL `SET` lines and the SQLite `PRAGMA defer_foreign_keys = ON` a dump writes
  case sessionSetting
}

/// Statement counts of a restore, before it runs (`SQLRestorePlan.summary`) and after
nonisolated struct SQLRestoreSummary: Sendable, Equatable {
  let engine: DatabaseType
  /// Statements in the script (comment-only text left out)
  let statementCount: Int
  let counts: [SQLRestoreStatementKind: Int]
  /// MySQL server-version options (`/*!…*/`, raw text) inside CREATE TABLE statements
  let serverVersionOptions: [String]
  /// Statements sent (all of them once the restore succeeded)
  var statementsRun = 0
  /// Joined the Protected mode transaction: waits for Commit / Rollback
  var pending = false
  /// Ran inside the transaction the user opened (behind a savepoint): kept only if committed
  var insideUserTransaction = false

  func count(_ kind: SQLRestoreStatementKind) -> Int { counts[kind, default: 0] }

  /// Schema statements or triggers (history records the restore as a schema change)
  var changesSchema: Bool { count(.schema) + count(.trigger) > 0 }
}

/// How far a restore is
nonisolated struct SQLRestoreProgress: Sendable, Equatable {
  var statementsDone: Int
  var statementCount: Int
}

/// Why a restore was refused or did not finish cleanly. Every case but `sessionNotReset` and
/// `restoreFailedSessionClosed` means nothing was executed (the `standardStrings` cases follow
/// only the `SHOW standard_conforming_strings` read); those two closed the connection.
nonisolated enum SQLRestoreError: LocalizedError, Equatable, Sendable {
  case tooLarge(bytes: Int)
  case headerMissing
  case engineMismatch(dump: String, connection: String)
  case unsupportedEngine(String)
  case containsNUL
  /// `index` is 0-based among the script's statements
  case statementRefused(index: Int, reason: String)
  case sessionSettingsUnreadable(String)
  /// MySQL: every statement ran, but resetting foreign key checks, sql_mode or time_zone failed
  /// (the connection was closed)
  case sessionNotReset(statementsRun: Int, reason: String)
  /// MySQL: the restore failed or was cancelled (`restoreFailure`), and resetting foreign key
  /// checks, sql_mode or time_zone failed too (`reason`; the connection was closed)
  case restoreFailedSessionClosed(restoreFailure: String, reason: String)
  /// PostgreSQL: statement `index` holds a plain string with a backslash, read as
  /// `standard_conforming_strings = on` reads it, and the session reports `value`
  case standardStringsOff(index: Int, value: String)
  /// PostgreSQL: `SHOW standard_conforming_strings` failed or gave an unexpected answer
  case standardStringsUnreadable(String)
  /// The connection was reset (reconnect, or a Cancel that reconnected) after the dump was read
  case connectionChanged

  var errorDescription: String? {
    switch self {
    case .tooLarge(let bytes):
      "This file is \(bytes / 1_048_576) MiB; a SQL dump restore reads files up to 64 MiB. "
        + "Nothing was executed."
    case .headerMissing:
      "This file is not a Dblore SQL dump: its first line is not \""
        + SQLRestorePlan.headerPrefix + "<engine> ...\". Nothing was executed."
    case .engineMismatch(let dump, let connection):
      "This dump was made from a \(dump) database and cannot be restored into \(connection). "
        + "Nothing was executed."
    case .unsupportedEngine(let engine):
      "\(engine) connections cannot restore SQL dumps. Nothing was executed."
    case .containsNUL:
      "This file contains a NUL character, where the database would cut the statement. "
        + "Nothing was executed."
    case .statementRefused(let index, let reason):
      "Statement \(index + 1) is not part of a SQL dump: \(reason). Nothing was executed."
    case .sessionSettingsUnreadable(let reason):
      "Could not read this session's sql_mode and time_zone to reset them after the restore "
        + "(\(reason)). Nothing was executed."
    case .sessionNotReset(let count, let reason):
      "The restore ran all \(count) statements, but this session's foreign key checks, "
        + "sql_mode or time_zone could not be reset (\(reason)), so the connection was closed "
        + "to drop those settings. Reconnect to continue with a fresh session."
    case .restoreFailedSessionClosed(let failure, let reason):
      "The restore stopped: \(failure) Resetting this session's foreign key checks, sql_mode "
        + "and time_zone also failed (\(reason)), so the connection was closed to drop those "
        + "settings. Reconnect to continue with a fresh session."
    case .standardStringsOff(let index, let value):
      "Statement \(index + 1) holds a quoted string with a backslash, written for "
        + "standard_conforming_strings on (the backslash is a character), but this session has "
        + "it \(value), where the server would read the backslash as an escape. "
        + "Nothing was executed."
    case .standardStringsUnreadable(let reason):
      "Could not read this session's standard_conforming_strings, which decides how the dump's "
        + "quoted strings with a backslash are read (\(reason)). Nothing was executed."
    case .connectionChanged:
      "The connection was reset after this dump was read. Open the dump again to restore it. "
        + "Nothing was executed."
    }
  }
}

/// A dump script read once (pure, off the actor): the statements to send, as classified for the
/// gate, and their counts for the confirmation. `executeGatedRestore` runs it as is.
nonisolated struct SQLRestorePlan: Sendable {
  /// The splitter holds the script as Unicode scalars (about 4 bytes each): 64 MiB of SQL costs
  /// about 256 MiB at peak
  static let maxScriptBytes = 64 * 1024 * 1024
  /// First line of every dump (`SQLDumpAssembler.header`), followed by the engine's raw value
  static let headerPrefix = "-- Dblore SQL dump 1 engine="
  /// Why a DuckDB restore is refused under Protected mode
  static let duckdbProtectedModeMessage =
    "Turn Protected mode off for this connection to restore a DuckDB dump: DuckDB has no "
    + "savepoint, so the restore cannot wait for Commit inside the pending transaction."
  /// Why a restore into a DuckDB file opened read-only is refused, and how to reopen it
  static let duckdbReadOnlyFileMessage =
    "This DuckDB file is open read-only, so a SQL dump cannot be restored into it. To restore, "
    + "edit the connection, turn off Read-only and connect again."

  /// A DuckDB file (not in-memory) opened read-only (`readOnlyFile`) on a connection that is not
  /// Read-only protected itself
  static func isReadOnlyDuckDBFile(_ config: ConnectionConfig) -> Bool {
    config.databaseType == .duckdb && config.readOnlyFile
      && config.database != DuckDBSession.inMemoryPath && config.protectionLevel != .readOnly
  }

  let engine: DatabaseType
  /// Statements to send, in order. A SQLite trigger the splitter kept whole and a MySQL
  /// CREATE TABLE with server-version options classify as DDL here (the classifier fails
  /// closed on them as unknown; DDL is blocked wherever unknown is).
  let statements: [ClassifiedStatement]
  let kinds: [SQLRestoreStatementKind]
  /// Counts before anything runs
  let summary: SQLRestoreSummary
  /// PostgreSQL: the first statement read as `standard_conforming_strings = on` reads it (a
  /// schema statement with a plain string holding a backslash), or nil. `executeGatedRestore`
  /// runs the plan only after the session reports on.
  let standardStringsStatement: Int?

  /// - Throws: `SQLRestoreError` (too large, header missing or another engine, a NUL in a
  ///   SQLite or DuckDB script, or the first statement a dump never writes);
  ///   `CancellationError` when the task planning it is cancelled
  init(script: String, engine: DatabaseType) throws {
    let bytes = script.utf8.count
    guard bytes <= Self.maxScriptBytes else { throw SQLRestoreError.tooLarge(bytes: bytes) }
    switch engine {
    case .postgresql, .mysql, .sqlite, .duckdb: break
    case .mongodb: throw SQLRestoreError.unsupportedEngine(engine.rawValue)
    }
    try Self.checkHeader(script, engine: engine)
    // Both read statements as C strings: a NUL would cut the statement the whitelist approved
    if engine == .sqlite || engine == .duckdb, script.unicodeScalars.contains("\0") {
      throw SQLRestoreError.containsNUL
    }
    let dialect = engine.dialect
    var statements: [ClassifiedStatement] = []
    var kinds: [SQLRestoreStatementKind] = []
    var options: [String] = []
    var standardStrings: Int?
    // DuckDB: the sequences the file created so far (`checkDuckDBSequences`)
    var sequences = Set<[String]>()
    for piece in SQLTokenizer(dialect: dialect).splitStatements(script) {
      // A file read cancelled while it is planned stops here
      try Task.checkCancellation()
      guard let classified = SQLStatementClassifier.classifyStatement(piece, dialect: dialect)
      else { continue }
      let accepted = try Self.accept(classified, engine: engine, index: statements.count)
      if engine == .duckdb, accepted.kind == .schema {
        try Self.checkDuckDBSequences(
          classified.text, created: &sequences, index: statements.count)
      }
      if accepted.standardStrings, standardStrings == nil { standardStrings = statements.count }
      statements.append(accepted.statement)
      kinds.append(accepted.kind)
      options += accepted.options
    }
    self.engine = engine
    self.statements = statements
    self.kinds = kinds
    standardStringsStatement = standardStrings
    summary = SQLRestoreSummary(
      engine: engine, statementCount: statements.count,
      counts: kinds.reduce(into: [:]) { $0[$1, default: 0] += 1 }, serverVersionOptions: options)
  }

  // MARK: - Header

  /// The first line must be `headerPrefix` + `engine.rawValue`, then a space or the line end.
  /// Compared scalar by scalar (no canonical equivalence).
  private static func checkHeader(_ script: String, engine: DatabaseType) throws {
    let line = script.unicodeScalars.prefix { $0 != "\n" && $0 != "\r" }
    guard line.starts(with: headerPrefix.unicodeScalars) else {
      throw SQLRestoreError.headerMissing
    }
    let name = line.dropFirst(headerPrefix.unicodeScalars.count).prefix { $0 != " " }
    guard !name.isEmpty else { throw SQLRestoreError.headerMissing }
    guard name.elementsEqual(engine.rawValue.unicodeScalars) else {
      throw SQLRestoreError.engineMismatch(
        dump: String(String.UnicodeScalarView(name)), connection: engine.rawValue)
    }
  }

  // MARK: - Accepted statements

  private struct Accepted {
    let statement: ClassifiedStatement
    let kind: SQLRestoreStatementKind
    var options: [String] = []
    /// Read with `standard_conforming_strings = on` (`standardConformingSchema`)
    var standardStrings = false
  }

  /// Only the statement shapes `SQLDumpWriter` writes for `engine`, matched on their leading
  /// tokens (`isDumpSchema`) or, for data, whole (`dataRefusal`), plus these exact forms: the dump's MySQL session
  /// settings and foreign key switches, SQLite `PRAGMA defer_foreign_keys = ON`, PostgreSQL
  /// `SELECT pg_catalog.setval('<name>', <n>, true | false)`, a SQLite `CREATE TRIGGER` the
  /// splitter kept whole, a MySQL CREATE TABLE whose only unknown parts are server-version
  /// options, and a PostgreSQL schema statement unknown only for a plain string with a backslash
  /// (`standardConformingSchema`). Anything else (roles, users, grants, extensions, functions, DROP, UPDATE, other
  /// DELETEs, reads, SET, transaction control, utilities, other PRAGMAs) is refused.
  private static func accept(
    _ statement: ClassifiedStatement, engine: DatabaseType, index: Int
  ) throws -> Accepted {
    let dialect = engine.dialect
    let tokens = tokens(statement.text, dialect)
    if statement.changesPrivileges || statement.affectsAllRows {
      throw refusal(index, notWritten(tokens))
    }
    switch statement.kind {
    case .dml:
      if let reason = dataRefusal(tokens, engine: engine) { throw refusal(index, reason) }
      return Accepted(statement: statement, kind: .data)
    case .ddl where engine == .sqlite && startsWithPragma(statement.text):
      guard tokens == sqlitePragmaTokens else {
        throw refusal(index, "only the PRAGMA defer_foreign_keys = ON of a dump is restored")
      }
      return Accepted(statement: statement, kind: .sessionSetting)
    case .ddl:
      guard isDumpSchema(tokens, engine: engine) else {
        throw refusal(index, notWritten(tokens))
      }
      return Accepted(statement: statement, kind: .schema)
    case .read where engine == .postgresql && isSetval(tokens):
      return Accepted(statement: statement, kind: .sequenceValue)
    case .sessionSet, .utility:
      guard engine == .mysql, mysqlSettingTokens.contains(tokens) else {
        throw refusal(index, describe(statement.kind) + " other than the settings a dump writes")
      }
      return Accepted(statement: statement, kind: .sessionSetting)
    case .unknown where engine == .sqlite && isWholeTrigger(tokens):
      return Accepted(statement: with(statement, kind: .ddl), kind: .trigger)
    case .unknown where engine == .mysql:
      guard let options = serverVersionOptions(statement.text) else {
        throw refusal(
          index,
          "unrecognized statement (MySQL version comments /*!...*/ are restored only inside "
            + "CREATE TABLE)")
      }
      return Accepted(statement: with(statement, kind: .ddl), kind: .schema, options: options)
    case .unknown where engine == .postgresql:
      guard let read = standardConformingSchema(statement.text) else {
        throw refusal(index, describe(statement.kind))
      }
      return Accepted(statement: read, kind: .schema, standardStrings: true)
    default:
      throw refusal(index, describe(statement.kind))
    }
  }

  /// DuckDB: records the sequence a `CREATE SEQUENCE` creates, and refuses a `CREATE TABLE`
  /// whose `nextval` default (`duckdbSequenceDefaults`) names a sequence the file did not create
  /// before it: a sequence already in the database would advance on every later insert. A
  /// one-part name is the table's schema's sequence (DuckDB looks there first, then in `main`,
  /// which this check does not follow), a one-part table or sequence is in `main`. Names
  /// compare ASCII case-insensitively, as DuckDB compares identifiers.
  private static func checkDuckDBSequences(
    _ text: String, created: inout Set<[String]>, index: Int
  ) throws {
    let tokens = tokens(text, .duckdb)
    var shape = ShapeReader(tokens)
    guard shape.words("CREATE") else { return }
    let isSequence = shape.words("SEQUENCE")
    guard isSequence || shape.words("TABLE"), let target = shape.nameParts() else { return }
    let name = target.map { SQLTokenizer.asciiUppercased($0.text) }
    let qualified = name.count == 1 ? ["MAIN"] + name : name
    if isSequence {
      created.insert(qualified)
      return
    }
    guard let body = duckdbTableBody(&shape) else { return }
    for sequence in duckdbSequenceDefaults(body.tokens, columnDepth: body.columnDepth) ?? [] {
      let key = sequence.count == 1 ? [qualified[0]] + sequence : sequence
      guard created.contains(key) else {
        throw refusal(
          index,
          "a Dblore dump's nextval default names only a sequence the dump creates before the table")
      }
    }
  }

  /// The refusal reason for a DDL / DML statement outside the dump's shapes
  private static func notWritten(_ tokens: [SQLToken]) -> String {
    let lead = tokens.prefix(2).map { $0.keyword ?? $0.text }.joined(separator: " ")
    return "a Dblore dump never writes this \(lead) statement"
  }

  private static func refusal(_ index: Int, _ reason: String) -> SQLRestoreError {
    .statementRefused(index: index, reason: reason)
  }

  private static func describe(_ kind: StatementKind) -> String {
    DatabaseConnectionManager.describe(kind)
  }

  private static func tokens(_ text: String, _ dialect: SQLDialect) -> [SQLToken] {
    SQLTokenizer(dialect: dialect).tokens(text)
  }

  /// `text` without its final `;`, as a statement of the split
  private static func statementTokens(_ text: String, _ dialect: SQLDialect) -> [SQLToken] {
    tokens(text.hasSuffix(";") ? String(text.dropLast()) : text, dialect)
  }

  private static let sqlitePragmaTokens = statementTokens(
    "PRAGMA defer_foreign_keys = ON;", .sqlite)

  /// The dump's MySQL session settings (`SQLDumpAssembler.mysqlSessionSettings`) and the
  /// foreign key switches around its tables and data
  private static let mysqlSettingTokens =
    (SQLDumpAssembler.mysqlSessionSettings + [
      "SET FOREIGN_KEY_CHECKS=0;", "SET FOREIGN_KEY_CHECKS=1;",
    ]).map { statementTokens($0, .mysql) }

  private static func startsWithPragma(_ text: String) -> Bool {
    tokens(text, .sqlite).first?.isWord("PRAGMA") == true
  }

  /// `SELECT pg_catalog.setval('<name>', [-]<n>, true | false)`, as the dump writes it
  private static func isSetval(_ tokens: [SQLToken]) -> Bool {
    var t = tokens
    if t.count == 12, t[7].isSymbol("-") { t.remove(at: 7) }
    guard t.count == 11 else { return false }
    let isInteger =
      t[7].kind == .word && !t[7].text.isEmpty
      && t[7].text.unicodeScalars.allSatisfy {
        ("0"..."9").contains($0)
      }
    return t[0].isWord("SELECT") && t[1].isWord("PG_CATALOG") && t[2].isSymbol(".")
      && t[3].isWord("SETVAL") && t[4].isSymbol("(") && t[5].kind == .string
      && t[6].isSymbol(",") && isInteger && t[8].isSymbol(",")
      && (t[9].isWord("TRUE") || t[9].isWord("FALSE")) && t[10].isSymbol(")")
  }

  /// `CREATE TRIGGER <name> ... ON <table> ... ; END`: a trigger the SQLite split ended at its
  /// `; END` (an unterminated one at the end of the file ends otherwise). A dump never writes a
  /// TEMP trigger (it would fire on the app's connection, outside the schema): `CREATE TEMP`,
  /// a `temp.` name or table, or any other qualified name, is refused (`isSQLiteTrigger`).
  private static func isWholeTrigger(_ tokens: [SQLToken]) -> Bool {
    guard tokens.count > 4, isSQLiteTrigger(tokens) else { return false }
    return tokens[tokens.count - 1].isWord("END") && tokens[tokens.count - 2].isSymbol(";")
  }

  /// A PostgreSQL statement that classifies as unknown only because a plain `'...'` string holds
  /// a backslash: the catalog text a dump copies (`pg_get_constraintdef`, `pg_get_expr`,
  /// `pg_get_viewdef`, `pg_get_indexdef`) prints `'^\d+$'` that way when
  /// standard_conforming_strings is on. Read as on (the backslash is a character; the split is
  /// the same), it must classify as DDL and have a dump's shape (`isDumpSchema`). Data, setval
  /// and anything else stay refused. Nil when it does not qualify.
  private static func standardConformingSchema(_ text: String) -> ClassifiedStatement? {
    let conforming = SQLTokenizer(dialect: .postgresql, standardConformingStrings: true)
    guard
      SQLTokenizer(dialect: .postgresql).tokens(text).contains(where: {
        $0.kind == .backslashString
      }),
      let read = SQLStatementClassifier.classifyStatement(
        text, dialect: .postgresql, standardConformingStrings: true),
      read.kind == .ddl, !read.changesPrivileges, !read.affectsAllRows,
      isDumpSchema(conforming.tokens(text), engine: .postgresql)
    else { return nil }
    return read
  }

  /// The table a SQLite `CREATE TRIGGER` fires on, as written (the name after the first
  /// top-level `ON` past the trigger's name, as `isSQLiteTrigger` reads it), or nil
  static func triggerTable(_ text: String) -> String? {
    let tokenizer = SQLTokenizer(dialect: .sqlite)
    let tokens = tokenizer.tokens(text)
    var shape = ShapeReader(tokens)
    guard shape.words("CREATE", "TRIGGER"), shape.sqliteName(),
      let on = tokens[shape.index...].firstIndex(where: { $0.depth == 0 && $0.isWord("ON") }),
      on + 1 < tokens.count
    else { return nil }
    // `tokens` has one token per lexeme other than whitespace and comments
    let scalars = Array(text.unicodeScalars)
    var count = 0
    var i = 0
    while i < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: i)
      switch lexeme.kind {
      case .whitespace, .comment: break
      default:
        if count == on + 1 { return SQLTokenizer.text(scalars, lexeme.range) }
        count += 1
      }
      i = lexeme.range.upperBound
    }
    return nil
  }

  /// The raw server-version options of a MySQL `CREATE TABLE` that classifies as DDL and has a
  /// dump's shape (`isDumpSchema`) once each `/*!NNNNN …*/` is replaced by its content (the
  /// statement a server that runs them sees), else nil
  private static func serverVersionOptions(_ text: String) -> [String]? {
    let tokenizer = SQLTokenizer(dialect: .mysql)
    let tokens = tokenizer.tokens(text)
    let options = tokens.filter { $0.kind == .executableComment }.map(\.text)
    guard tokens.count > 2, tokens[0].isWord("CREATE"), tokens[1].isWord("TABLE"),
      !options.isEmpty
    else { return nil }
    let opened = withVersionCommentsOpened(text, tokenizer)
    guard SQLStatementClassifier.classifyStatement(opened, dialect: .mysql)?.kind == .ddl,
      isDumpSchema(tokenizer.tokens(opened), engine: .mysql)
    else { return nil }
    return options
  }

  /// `text` with every executable comment replaced by its content between spaces
  private static func withVersionCommentsOpened(
    _ text: String, _ tokenizer: SQLTokenizer
  ) -> String {
    let scalars = Array(text.unicodeScalars)
    var result = String.UnicodeScalarView()
    var i = 0
    while i < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: i)
      var piece = scalars[lexeme.range]
      if case .executableComment = lexeme.kind {
        // `/*!` or `/*M!`, the optional version digits, then the content up to `*/`
        piece = piece.dropFirst(piece.dropFirst(2).first == "M" ? 4 : 3)
        piece = piece.drop { ("0"..."9").contains($0) }
        if piece.suffix(2).elementsEqual(["*", "/"]) { piece = piece.dropLast(2) }
        result.append(" ")
        result.append(contentsOf: piece)
        result.append(" ")
      } else {
        result.append(contentsOf: piece)
      }
      i = lexeme.range.upperBound
    }
    return String(result)
  }

  private static func with(
    _ statement: ClassifiedStatement, kind: StatementKind
  ) -> ClassifiedStatement {
    ClassifiedStatement(
      text: statement.text, kind: kind, hasReturning: statement.hasReturning,
      hasTopLevelReturning: statement.hasTopLevelReturning,
      affectsAllRows: statement.affectsAllRows, nonTransactional: statement.nonTransactional,
      resetsSessionBrakes: statement.resetsSessionBrakes,
      changesPrivileges: statement.changesPrivileges, createsTable: statement.createsTable)
  }
}

// MARK: - Dump statement shapes

nonisolated extension SQLRestorePlan {
  /// The schema statements `SQLDumpDDL` writes for `engine`:
  /// - PostgreSQL: `CREATE SCHEMA IF NOT EXISTS <name>`, `CREATE TYPE <name> AS ENUM (`,
  ///   `CREATE DOMAIN <name> AS`, `CREATE SEQUENCE <name> AS`, `CREATE TABLE <name> (...)` or
  ///   `CREATE TABLE <name> PARTITION OF <parent> FOR VALUES ... | DEFAULT`, each with an optional
  ///   `PARTITION BY <method> (...)` and nothing after it (`isPostgresTableRest`),
  ///   `CREATE [UNIQUE] INDEX <name> ON <table>`, `CREATE VIEW <name> AS`,
  ///   `ALTER TABLE <name> ADD CONSTRAINT | PRIMARY | UNIQUE | CHECK | FOREIGN | EXCLUDE` (one
  ///   action: no top-level comma), `ALTER DOMAIN <name> ADD CONSTRAINT`,
  ///   `ALTER SEQUENCE <name> OWNED BY`. No created or altered object, and no index's table,
  ///   is in a system schema (`isSystemSchema`, as for INSERT targets).
  /// - MySQL: `SHOW CREATE TABLE` text, `CREATE TABLE <name> (...) <options>`
  ///   (`isMySQLTableRest`), and `SHOW CREATE VIEW` without DEFINER:
  ///   `CREATE [ALGORITHM = <word>] [SQL SECURITY DEFINER | INVOKER] VIEW <name> AS`. Names are
  ///   never qualified (a restore targets the connected database), so no system database
  ///   (`mysql`, `sys`, `performance_schema`, `information_schema`) is reached.
  /// - SQLite: `sqlite_master` text (which drops `IF NOT EXISTS`, TEMP and any schema name):
  ///   `CREATE TABLE <name> (...) [WITHOUT ROWID | STRICT, ...]`,
  ///   `CREATE VIRTUAL TABLE <name> USING <module> [(...)]`, `CREATE [UNIQUE] INDEX <name>`,
  ///   `CREATE VIEW <name>`, `CREATE TRIGGER <name> ... ON <table>`, with one-part names only
  ///   (no `temp.` object, hidden from the schema and alive on the app's connection).
  /// - DuckDB: `CREATE SCHEMA IF NOT EXISTS <name>`, `CREATE TYPE <name> AS ENUM (<string>,
  ///   ...)`, `CREATE SEQUENCE <name> START WITH <n> INCREMENT BY <n> MINVALUE <n> MAXVALUE <n>
  ///   [NO] CYCLE` (the forms `SQLDumpDDL.duckdb` builds, nothing else after them), and the
  ///   catalog's text: `CREATE TABLE <name>(...)`, `CREATE [UNIQUE] INDEX <name> ON
  ///   <table>(...)`, each with nothing after the list, and `CREATE VIEW <name> [(<column>, ...)]
  ///   AS <query>`. No OR REPLACE, TEMP or IF NOT EXISTS (but on the schema); names have at most
  ///   two parts, never in `temp`, `system`, `information_schema` or `pg_catalog`. No function
  ///   the classifier stops in a read (`duckdbSideEffectFunctions`, extension prefixes) or the
  ///   restore refuses (`duckdbRestoreRefusedFunctions`: SQL run from a string, file, setting,
  ///   pragma and secret reads, logging) is called, but `nextval` as a table's column default
  ///   (`duckdbSequenceDefaults`; the plan checks the file created that sequence first), and no
  ///   remote URL is named (`SQLStatementClassifier.namesRemoteURL`). A deny-list, not an
  ///   allow-list: a view may call any of DuckDB's scalar and aggregate functions. Files named
  ///   another way (`FROM '<path>'`) are left to the session, which grants only the files the
  ///   user picked.
  static func isDumpSchema(_ tokens: [SQLToken], engine: DatabaseType) -> Bool {
    var shape = ShapeReader(tokens)
    switch engine {
    case .postgresql:
      if shape.words("CREATE") {
        if shape.words("SCHEMA", "IF", "NOT", "EXISTS") {
          return shape.postgresTarget(parts: 1) && shape.atEnd
        }
        if shape.words("TYPE") { return shape.postgresTarget() && shape.words("AS", "ENUM") }
        if shape.words("DOMAIN") || shape.words("SEQUENCE") {
          return shape.postgresTarget() && shape.words("AS")
        }
        if shape.words("TABLE") {
          return shape.postgresTarget() && isPostgresTableRest(&shape)
        }
        if shape.words("VIEW") { return shape.postgresTarget() && shape.words("AS") }
        _ = shape.words("UNIQUE")
        guard shape.words("INDEX"), shape.name(parts: 1), shape.words("ON") else { return false }
        _ = shape.words("ONLY")
        return shape.postgresTarget()
      }
      guard shape.words("ALTER") else { return false }
      if shape.words("TABLE") {
        let actions = ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "EXCLUDE"]
        return shape.postgresTarget() && shape.words("ADD") && actions.contains { shape.peek($0) }
          && !tokens.contains { $0.depth == 0 && $0.isSymbol(",") }
      }
      if shape.words("DOMAIN") {
        return shape.postgresTarget() && shape.words("ADD", "CONSTRAINT")
      }
      return shape.words("SEQUENCE") && shape.postgresTarget() && shape.words("OWNED", "BY")
    case .mysql:
      guard shape.words("CREATE") else { return false }
      if shape.words("TABLE") {
        return shape.name(parts: 1) && isMySQLTableRest(tokens, body: shape.index)
      }
      if shape.words("ALGORITHM") {
        guard shape.symbol("="), shape.anyWord() else { return false }
      }
      if shape.words("SQL", "SECURITY") {
        guard shape.words("DEFINER") || shape.words("INVOKER") else { return false }
      }
      return shape.words("VIEW") && shape.name(parts: 1) && shape.words("AS")
    case .sqlite:
      guard shape.words("CREATE") else { return false }
      if shape.words("VIRTUAL", "TABLE") {
        guard shape.sqliteName(), shape.words("USING"), shape.anyWord() else { return false }
        return shape.atEnd || (shape.group() && shape.atEnd)
      }
      if shape.words("TABLE") {
        guard shape.sqliteName(), shape.group() else { return false }
        return isSQLiteTableOptions(&shape)
      }
      if shape.peek("TRIGGER") { return isSQLiteTrigger(tokens) }
      if shape.words("VIEW") { return shape.sqliteName() }
      _ = shape.words("UNIQUE")
      return shape.words("INDEX") && shape.sqliteName()
    case .duckdb:
      return isDuckDBSchema(&shape)
    case .mongodb:
      return false
    }
  }

  /// The DuckDB shapes of `isDumpSchema`
  private static func isDuckDBSchema(_ shape: inout ShapeReader) -> Bool {
    guard shape.words("CREATE") else { return false }
    if shape.words("SCHEMA", "IF", "NOT", "EXISTS") {
      return shape.duckdbSchemaName() && shape.atEnd
    }
    if shape.words("TYPE") {
      guard shape.duckdbTarget(), shape.words("AS", "ENUM"), shape.symbol("(") else {
        return false
      }
      if !shape.symbol(")") {
        repeat {
          guard shape.kind(.string) else { return false }
        } while shape.symbol(",")
        guard shape.symbol(")") else { return false }
      }
      return shape.atEnd
    }
    if shape.words("SEQUENCE") {
      return shape.duckdbTarget() && shape.words("START", "WITH") && shape.integer()
        && shape.words("INCREMENT", "BY") && shape.integer() && shape.words("MINVALUE")
        && shape.integer() && shape.words("MAXVALUE") && shape.integer()
        && (shape.words("CYCLE") || shape.words("NO", "CYCLE")) && shape.atEnd
    }
    // Only the body is scanned for calls (`callsDuckDBSideEffect`): the object's own name, a
    // view's column list and the table a foreign key references come before `(` too
    if shape.words("TABLE") {
      guard shape.duckdbTarget(), let body = duckdbTableBody(&shape), shape.atEnd else {
        return false
      }
      return duckdbSequenceDefaults(body.tokens, columnDepth: body.columnDepth) != nil
        && !callsDuckDBSideEffect(body.tokens, allowing: ["NEXTVAL"])
    }
    if shape.words("VIEW") {
      guard shape.duckdbTarget() else { return false }
      if shape.peekSymbol("("), !shape.columnList() { return false }
      return shape.words("AS") && !shape.atEnd
        && !callsDuckDBSideEffect(Array(shape.tokens[shape.index...]), allowing: [])
    }
    _ = shape.words("UNIQUE")
    guard shape.words("INDEX"), shape.name(parts: 1), shape.words("ON"), shape.duckdbTarget()
    else { return false }
    let open = shape.index
    return shape.group() && shape.atEnd
      && !callsDuckDBSideEffect(Array(shape.tokens[(open + 1)..<(shape.index - 1)]), allowing: [])
  }

  /// A DuckDB table's column list from its `(`: the tokens between the parentheses without the
  /// name parts after each `REFERENCES` (a table, not a call), and the depth of its column
  /// definitions. Nil when the list is not there or not closed.
  fileprivate static func duckdbTableBody(
    _ shape: inout ShapeReader
  ) -> (tokens: [SQLToken], columnDepth: Int)? {
    let open = shape.index
    guard shape.group() else { return nil }
    let tokens = shape.tokens
    let end = shape.index - 1
    var body: [SQLToken] = []
    var index = open + 1
    while index < end {
      let token = tokens[index]
      body.append(token)
      index += 1
      guard token.isWord("REFERENCES") else { continue }
      var parts = 0
      while index < end, parts < 3,
        tokens[index].kind == .word || tokens[index].kind == .quotedIdentifier
      {
        parts += 1
        index += 1
        guard index < end, parts < 3, tokens[index].isSymbol(".") else { break }
        body.append(tokens[index])
        index += 1
      }
    }
    return (body, tokens[open].depth + 1)
  }

  /// A call to a function a DuckDB read may not call or a restore refuses (but `allowed`), or a
  /// remote URL
  private static func callsDuckDBSideEffect(
    _ tokens: [SQLToken], allowing allowed: Set<String>
  )
    -> Bool
  {
    let body = tokens[...]
    let classifier = SQLStatementClassifier.self
    return classifier.calls(
      body,
      anyOf: classifier.duckdbSideEffectFunctions.union(classifier.duckdbRestoreRefusedFunctions)
        .subtracting(allowed),
      orPrefixes: classifier.duckdbSideEffectFunctionPrefixes
        + classifier.duckdbRestoreRefusedFunctionPrefixes,
      orContaining: classifier.duckdbRestoreRefusedFunctionInfixes)
      || classifier.namesRemoteURL(body)
  }

  /// The sequence names (parts, ASCII uppercased; one or two) of the `nextval` calls in a
  /// DuckDB table's column list (`duckdbTableBody`) when each one is a column default as the catalog writes it,
  /// `DEFAULT(nextval('<name>'))` or `DEFAULT nextval('<name>')`, else nil: `nextval` in a
  /// CHECK, a generated column, a cast or any other expression, or with a name built at run
  /// time, is refused.
  private static func duckdbSequenceDefaults(
    _ tokens: [SQLToken], columnDepth: Int
  ) -> [[String]]? {
    func isDefault(_ index: Int) -> Bool {
      index >= 0 && tokens[index].isWord("DEFAULT") && tokens[index].depth == columnDepth
    }
    var names: [[String]] = []
    for index in tokens.indices where isNextval(tokens[index]) {
      guard index + 1 < tokens.count, tokens[index + 1].isSymbol("(") else { continue }
      guard index + 3 < tokens.count, tokens[index + 2].kind == .string,
        tokens[index + 3].isSymbol(")"),
        isDefault(index - 1)
          || (index >= 1 && tokens[index - 1].isSymbol("(") && isDefault(index - 2)
            && index + 4 < tokens.count && tokens[index + 4].isSymbol(")")),
        let name = duckdbSequenceName(tokens[index + 2].text)
      else { return nil }
      names.append(name)
    }
    return names
  }

  /// `nextval` as a word or quoted identifier
  private static func isNextval(_ token: SQLToken) -> Bool {
    token.isWord("NEXTVAL")
      || (token.kind == .quotedIdentifier && SQLTokenizer.asciiUppercased(token.text) == "NEXTVAL")
  }

  /// The parts (ASCII uppercased) of the name in a `nextval('<name>')` literal, as DuckDB reads
  /// it: `name` or `schema.name`, words or quoted identifiers and nothing else, else nil
  private static func duckdbSequenceName(_ literal: String) -> [String]? {
    var shape = ShapeReader(SQLTokenizer(dialect: .duckdb).tokens(literal))
    guard let parts = shape.nameParts(), parts.count <= 2, shape.atEnd else { return nil }
    return parts.map { SQLTokenizer.asciiUppercased($0.text) }
  }

  /// After `CREATE TABLE <name>`: `(...)` or `PARTITION OF <parent>` with its bound
  /// (`FOR VALUES FROM (...) TO (...)`, `IN (...)`, `WITH (...)`, or `DEFAULT`), then an
  /// optional `PARTITION BY <method> (...)`, then nothing: no `AS SELECT`, `AS EXECUTE`,
  /// `WITH (...)` storage options, `INHERITS` or anything else the dump never writes
  private static func isPostgresTableRest(_ shape: inout ShapeReader) -> Bool {
    if shape.words("PARTITION", "OF") {
      guard shape.postgresTarget() else { return false }
      if !shape.words("DEFAULT") {
        guard shape.words("FOR", "VALUES") else { return false }
        if shape.words("FROM") {
          guard shape.group(), shape.words("TO"), shape.group() else { return false }
        } else {
          guard shape.words("IN") || shape.words("WITH"), shape.group() else { return false }
        }
      }
    } else if !shape.group() {
      return false
    }
    if shape.words("PARTITION", "BY") {
      guard shape.anyWord(), shape.group() else { return false }
    }
    return shape.atEnd
  }

  /// MySQL engines that reach another server or files outside the database: a dump of a table
  /// on one of them is refused (its CONNECTION or file options would run on restore)
  private static let mysqlRefusedEngines: Set<String> = [
    "federated", "federatedx", "connect", "spider",
  ]

  /// From `body` on (the token after `CREATE TABLE <name>`): the column list `(...)`, closed,
  /// not `(LIKE ...)`, then table options. Refused anywhere: a query (`SELECT`, `TABLE`,
  /// `VALUES ROW(...)` / `VALUES (...)`; partitions keep `VALUES LESS THAN` / `VALUES IN`),
  /// `CONNECTION`, `DATA DIRECTORY`, `INDEX DIRECTORY` and an engine in `mysqlRefusedEngines`.
  /// Refused after the column list: `AS`, `LIKE`, `IGNORE`, `REPLACE`. `SHOW CREATE TABLE`
  /// quotes every identifier, so none of these words is a name there.
  private static func isMySQLTableRest(_ tokens: [SQLToken], body: Int) -> Bool {
    var shape = ShapeReader(tokens, at: body)
    guard shape.peekSymbol("("), !shape.peekWord("LIKE", offset: 1), shape.group() else {
      return false
    }
    let afterColumns: Set<String> = ["AS", "LIKE", "IGNORE", "REPLACE"]
    if tokens[shape.index...].contains(where: {
      $0.depth == 0 && afterColumns.contains($0.keyword ?? "")
    }) {
      return false
    }
    for (index, token) in tokens.enumerated() where index >= body {
      let next = index + 1 < tokens.count ? tokens[index + 1] : nil
      if token.isWord("SELECT") || token.isWord("TABLE") || token.isWord("CONNECTION") {
        return false
      }
      if token.isWord("VALUES"), !(next?.isWord("LESS") == true || next?.isWord("IN") == true) {
        return false
      }
      if token.isWord("DATA") || token.isWord("INDEX"), next?.isWord("DIRECTORY") == true {
        return false
      }
      if token.isWord("ENGINE") {
        let nameIndex = next?.isSymbol("=") == true ? index + 2 : index + 1
        guard nameIndex < tokens.count else { return false }
        let name = SQLTokenizer.asciiLowercased(tokens[nameIndex].text)
        if mysqlRefusedEngines.contains(name) { return false }
      }
    }
    return true
  }

  /// After a SQLite table's `(...)`: `WITHOUT ROWID` and `STRICT`, comma separated, or nothing
  private static func isSQLiteTableOptions(_ shape: inout ShapeReader) -> Bool {
    if shape.atEnd { return true }
    repeat {
      guard shape.words("WITHOUT", "ROWID") || shape.words("STRICT") else { return false }
    } while shape.symbol(",")
    return shape.atEnd
  }

  /// `CREATE TRIGGER [IF NOT EXISTS] <name> ... ON <table>` with one-part names (no TEMP
  /// trigger: `CREATE TEMP TRIGGER`, `temp.<name>` or a trigger on `temp.<table>`)
  private static func isSQLiteTrigger(_ tokens: [SQLToken]) -> Bool {
    var shape = ShapeReader(tokens)
    guard shape.words("CREATE", "TRIGGER"), shape.sqliteName() else { return false }
    guard let on = tokens[shape.index...].firstIndex(where: { $0.depth == 0 && $0.isWord("ON") })
    else { return false }
    var table = ShapeReader(tokens, at: on + 1)
    return table.name(parts: 1)
  }

  /// Nil for a data statement a dump writes, else why it is refused:
  /// `INSERT INTO <table> [(<column>, ...)] [OVERRIDING SYSTEM VALUE] VALUES (<literal>, ...)
  /// [, (<literal>, ...)]...` with nothing after the last row, or `INSERT INTO <table> DEFAULT
  /// VALUES` (OVERRIDING and a schema-qualified table on PostgreSQL only, never into a `pg_`
  /// system table; DuckDB always `<schema>.<table>`, never in `temp`, `system` or a system
  /// schema), and the SQLite `DELETE FROM sqlite_sequence WHERE name = '<table>'`.
  /// The literals are those `SQLDumpDataRenderer` writes: quoted text everywhere (PostgreSQL
  /// `'...'` or `E'...'`, bytea as its `\x...` text, DuckDB BLOB as its `\x...` text), NULL,
  /// `X'<hex>'` on MySQL and SQLite, and SQLite `quote()` numbers (`-`, digits, `.digits`,
  /// `e+NN` / `e-NN`). No function call, cast, operator, identifier, DEFAULT or subquery can run
  /// inside a row.
  static func dataRefusal(_ tokens: [SQLToken], engine: DatabaseType) -> String? {
    var shape = ShapeReader(tokens)
    if engine == .sqlite, shape.words("DELETE", "FROM", "SQLITE_SEQUENCE", "WHERE", "NAME") {
      return shape.symbol("=") && shape.kind(.string) && shape.atEnd ? nil : notWritten(tokens)
    }
    guard shape.words("INSERT", "INTO"), let target = shape.nameParts() else {
      return notWritten(tokens)
    }
    let postgres = engine == .postgresql
    switch engine {
    case .postgresql:
      guard target.count <= 2 else { return notWritten(tokens) }
      // The schema, or an unqualified table name
      if isSystemSchema(target[0]) { return notWritten(tokens) }
    case .duckdb:
      // The writer always qualifies the table: an unqualified name could reach a temp table
      guard target.count == 2, !isDuckDBSystemName(target[0]) else { return notWritten(tokens) }
    case .mysql, .sqlite, .mongodb:
      guard target.count == 1 else { return notWritten(tokens) }
    }
    if shape.words("DEFAULT", "VALUES") { return shape.atEnd ? nil : notWritten(tokens) }
    if shape.peekSymbol("("), !shape.columnList() {
      return "a dump's INSERT lists only column names, not \(shape.describeNext)"
    }
    if postgres, shape.words("OVERRIDING") {
      guard shape.words("SYSTEM", "VALUE") else { return notWritten(tokens) }
    }
    guard shape.words("VALUES") else { return notWritten(tokens) }
    let blobs = engine == .mysql || engine == .sqlite
    let numbers = engine == .sqlite
    repeat {
      guard shape.symbol("(") else { return notLiteral(shape, engine) }
      repeat {
        guard shape.literal(blobs: blobs, numbers: numbers) else {
          return notLiteral(shape, engine)
        }
      } while shape.symbol(",")
      guard shape.symbol(")") else { return notLiteral(shape, engine) }
    } while shape.symbol(",")
    return shape.atEnd
      ? nil : "a dump's INSERT ends after its last VALUES row, not at \(shape.describeNext)"
  }

  private static func notLiteral(_ shape: ShapeReader, _ engine: DatabaseType) -> String {
    let forms =
      switch engine {
      case .postgresql, .duckdb: "quoted text and NULL"
      case .sqlite: "quoted text, numbers, X'...' blobs and NULL"
      default: "quoted text, X'...' blobs and NULL"
      }
    return "a dump's INSERT holds only literal values (\(forms)), not \(shape.describeNext)"
  }

  /// `pg_catalog`, `information_schema` or any `pg_…` name (`pg_temp`, `pg_temp_N`,
  /// `pg_toast`): a schema the dump never writes into, or an unqualified name PostgreSQL
  /// resolves in `pg_catalog` first
  fileprivate static func isSystemSchema(_ token: SQLToken) -> Bool {
    let name = SQLTokenizer.asciiLowercased(token.text)
    return name.hasPrefix("pg_") || name == "information_schema"
  }

  /// A system schema (`isSystemSchema`: `pg_catalog`, `information_schema`), or DuckDB's
  /// `temp` (objects on the app's connection only) or `system` catalog as the first name part
  fileprivate static func isDuckDBSystemName(_ token: SQLToken) -> Bool {
    let name = SQLTokenizer.asciiLowercased(token.text)
    return isSystemSchema(token) || name == "temp" || name == "system"
  }
}

/// Reads a statement's tokens from the start, one expected piece at a time
nonisolated private struct ShapeReader {
  let tokens: [SQLToken]
  private(set) var index = 0

  init(_ tokens: [SQLToken], at index: Int = 0) {
    self.tokens = tokens
    self.index = index
  }

  var atEnd: Bool { index == tokens.count }

  /// Consumes `words` if they come next, in order (keywords, ASCII uppercased)
  mutating func words(_ words: String...) -> Bool {
    guard index + words.count <= tokens.count,
      zip(tokens[index...], words).allSatisfy({ $0.isWord($1) })
    else { return false }
    index += words.count
    return true
  }

  func peek(_ word: String) -> Bool { index < tokens.count && tokens[index].isWord(word) }

  func peekSymbol(_ symbol: String) -> Bool {
    index < tokens.count && tokens[index].isSymbol(symbol)
  }

  /// The word `offset` tokens ahead is `word`
  func peekWord(_ word: String, offset: Int) -> Bool {
    index + offset < tokens.count && tokens[index + offset].isWord(word)
  }

  /// `(` up to its matching `)` (the tokenizer gives both the same depth); false when it is
  /// never closed
  mutating func group() -> Bool {
    guard peekSymbol("(") else { return false }
    let depth = tokens[index].depth
    guard
      let close = tokens[(index + 1)...].firstIndex(where: {
        $0.isSymbol(")") && $0.depth == depth
      })
    else { return false }
    index = close + 1
    return true
  }

  mutating func symbol(_ symbol: String) -> Bool {
    guard peekSymbol(symbol) else { return false }
    index += 1
    return true
  }

  mutating func kind(_ kind: SQLToken.Kind) -> Bool {
    guard index < tokens.count, tokens[index].kind == kind else { return false }
    index += 1
    return true
  }

  mutating func anyWord() -> Bool { kind(.word) }

  /// `name`, `a.name` or `a.b.name` (words or quoted identifiers), its parts
  mutating func nameParts() -> [SQLToken]? {
    var parts: [SQLToken] = []
    repeat {
      guard index < tokens.count,
        tokens[index].kind == .word || tokens[index].kind == .quotedIdentifier
      else { return nil }
      parts.append(tokens[index])
      index += 1
    } while parts.count < 3 && symbol(".")
    return parts
  }

  /// A name of at most `parts` parts
  mutating func name(parts: Int = 2) -> Bool {
    guard let read = nameParts() else { return false }
    return read.count <= parts
  }

  /// A PostgreSQL name of at most `parts` parts whose first part is not a system schema (the
  /// INSERT target check of `SQLRestorePlan.dataRefusal`)
  mutating func postgresTarget(parts: Int = 2) -> Bool {
    guard let read = nameParts(), read.count <= parts else { return false }
    return !SQLRestorePlan.isSystemSchema(read[0])
  }

  /// A DuckDB name of one or two parts; a schema (or catalog) part is not a system one
  mutating func duckdbTarget() -> Bool {
    guard let read = nameParts(), read.count <= 2 else { return false }
    return read.count == 1 || !SQLRestorePlan.isDuckDBSystemName(read[0])
  }

  /// A one-part DuckDB schema name that is not a system one
  mutating func duckdbSchemaName() -> Bool {
    guard let read = nameParts(), read.count == 1 else { return false }
    return !SQLRestorePlan.isDuckDBSystemName(read[0])
  }

  /// An optional `IF NOT EXISTS`, then a one-part SQLite name
  mutating func sqliteName() -> Bool {
    _ = words("IF", "NOT", "EXISTS")
    return name(parts: 1)
  }

  /// The next token, for a refusal reason
  var describeNext: String {
    guard index < tokens.count else { return "the end of the statement" }
    let token = tokens[index]
    switch token.kind {
    case .string, .backslashString: return "a quoted string here"
    case .quotedIdentifier: return "the identifier \"\(token.text)\""
    case .executableComment: return "a version comment"
    case .word, .symbol: return "\"\(token.text)\""
    }
  }

  /// `(<name>, ...)`: words or quoted identifiers and commas only
  mutating func columnList() -> Bool {
    guard symbol("(") else { return false }
    repeat {
      guard kind(.word) || kind(.quotedIdentifier) else { return false }
    } while symbol(",")
    return symbol(")")
  }

  /// One value as the dump writes it: a quoted string, NULL, an `X'<hex>'` blob (`blobs`) or a
  /// number (`numbers`)
  mutating func literal(blobs: Bool, numbers: Bool) -> Bool {
    if kind(.string) || words("NULL") { return true }
    if blobs, peek("X"), index + 1 < tokens.count, tokens[index + 1].kind == .string,
      Self.isEvenHex(tokens[index + 1].text)
    {
      index += 2
      return true
    }
    return numbers && number()
  }

  /// SQLite `quote()` number: `[-]<digits>[.<digits>][e(+|-)<digits>]` (`9.0e+999` lexes as
  /// `9` `.` `0` `E` `+` `999`)
  private mutating func number() -> Bool {
    let start = index
    _ = symbol("-")
    var valid = digits()
    if valid, symbol(".") { valid = digits() }
    if valid, words("E") { valid = (symbol("+") || symbol("-")) && digits() }
    if !valid { index = start }
    return valid
  }

  /// `[-]<digits>`: a DuckDB sequence value as `SQLDumpDDL.duckdb` writes it
  mutating func integer() -> Bool {
    let start = index
    _ = symbol("-")
    if digits() { return true }
    index = start
    return false
  }

  private mutating func digits() -> Bool {
    guard index < tokens.count, tokens[index].kind == .word, !tokens[index].text.isEmpty,
      tokens[index].text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) })
    else { return false }
    index += 1
    return true
  }

  /// ASCII hex digits, an even count (empty allowed)
  private static func isEvenHex(_ text: String) -> Bool {
    text.utf8.count.isMultiple(of: 2)
      && text.utf8.allSatisfy {
        (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
      }
  }
}

extension DatabaseConnectionManager {
  /// App-owned read, before a MySQL restore, of the settings its script changes
  static let restoreSessionQuery = "SELECT @@SESSION.sql_mode, @@SESSION.time_zone"
  /// App-owned read, before a PostgreSQL restore whose plan read plain backslash strings as
  /// standard-conforming (`SQLRestorePlan.standardStringsStatement`)
  static let standardStringsQuery = "SHOW standard_conforming_strings"

  /// Plan `script` (`SQLRestorePlan`, for the connected engine) and restore it. Large scripts
  /// should be planned off the actor and passed to `executeGatedRestore(_:policy:...)`.
  func executeGatedRestore(
    script: String, policy: ProtectionPolicy, connectionEpoch epoch: UInt64, caller: UUID? = nil,
    progress: @escaping @Sendable (SQLRestoreProgress) -> Void = { _ in }
  ) async throws -> SQLRestoreSummary {
    guard let engine = config?.databaseType else { throw DatabaseError.notConnected }
    let plan = try PerfSignpost.interval("restore.plan") {
      try SQLRestorePlan(script: script, engine: engine)
    }
    return try await executeGatedRestore(
      plan, policy: policy, connectionEpoch: epoch, caller: caller, progress: progress)
  }

  /// Run a restore plan. `caller` is the active notebook: under Protected mode the restore opens
  /// or joins the app transaction owned by it. `connectionEpoch` must still be `epoch`
  /// (`SQLRestoreError.connectionChanged`) and the plan must be for the connected engine. A PostgreSQL
  /// plan with `standardStringsStatement` then reads `SHOW standard_conforming_strings` and runs
  /// only when it is `on` (`SQLRestoreError.standardStringsOff` / `.standardStringsUnreadable`);
  /// a Cancel during that read stops the restore (`DatabaseError.batchCancelled`), another
  /// connection refuses it (`SQLRestoreError.connectionChanged`). Only that read may come before a
  /// refusal: in the same actor turn as the first change, a read-only policy refuses any
  /// restore and every statement must pass `evaluate` against `effectivePolicy(for:)`
  /// (`DatabaseError.blockedByProtection`; schema-only refuses DDL).
  /// - PostgreSQL / SQLite: one staged batch with no row-count checks (`runStagedBatch`), so a
  ///   failure rolls everything back; under Protected mode it joins the app transaction
  ///   (`pending`). A failed COMMIT is rolled back.
  /// - DuckDB: the same batch, never inside a transaction (BEGIN ... COMMIT): DuckDB has no
  ///   SAVEPOINT, so Protected mode and an open transaction are refused
  ///   (`DatabaseError.sequentialBatchRefused`). A DuckDB file opened read-only is refused with
  ///   how to reopen it writable (`SQLRestorePlan.duckdbReadOnlyFileMessage`).
  /// - MySQL: `executeGatedSequentialBatch` (refused with a transaction open or under Protected
  ///   mode, `DatabaseError.sequentialBatchRefused`). The session's sql_mode and time_zone are
  ///   read first (a Cancel meanwhile: `DatabaseError.batchCancelled`); afterwards, on success,
  ///   failure or cancel, `SET FOREIGN_KEY_CHECKS=1` and the read values are sent again. If that
  ///   fails the session is closed and reported lost (`SQLRestoreError.sessionNotReset` after a
  ///   complete restore, `.restoreFailedSessionClosed` after a failure or cancel).
  /// `progress` gets the statements done after each one. Returns the plan's summary with
  /// `statementsRun`, `pending` and `insideUserTransaction` set.
  func executeGatedRestore(
    _ plan: SQLRestorePlan, policy: ProtectionPolicy, connectionEpoch epoch: UInt64,
    caller: UUID? = nil, progress: @escaping @Sendable (SQLRestoreProgress) -> Void = { _ in }
  ) async throws -> SQLRestoreSummary {
    try refuseIfRelocked(config)
    guard epoch == connectionEpoch else {
      throw SQLRestoreError.connectionChanged
    }
    guard let engine = config?.databaseType else { throw DatabaseError.notConnected }
    guard engine == plan.engine else {
      throw SQLRestoreError.engineMismatch(
        dump: plan.engine.rawValue, connection: engine.rawValue)
    }
    // Counted before the first suspension, so a Cancel during the SHOW below finds the restore
    // running and a Commit / Rollback arriving meanwhile is refused
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    let generation = batchCancellationGeneration
    if let index = plan.standardStringsStatement {
      do {
        try await requireStandardConformingStrings(statement: index)
      } catch {
        try refuseIfRestoreInterrupted(since: generation, epoch: epoch)
        throw error
      }
      try refuseIfRestoreInterrupted(since: generation, epoch: epoch)
    }
    // From here no suspension until the batch: every check and the summary read the state the
    // batch runs in. Decisions are pure and finish before any await that could send SQL. A
    // restore always writes (`SELECT pg_catalog.setval(...)` classifies as a read), so read-only
    // refuses it.
    let effective = effectivePolicy(for: policy)
    if effective.protectionLevel == .readOnly {
      let readOnlyFile = config.map(SQLRestorePlan.isReadOnlyDuckDBFile) == true
      throw DatabaseError.blockedByProtection(
        statementIndex: 0, kind: plan.statements.first?.kind ?? .dml,
        reason: readOnlyFile
          ? SQLRestorePlan.duckdbReadOnlyFileMessage
          : "Restoring a SQL dump is not allowed on a read-only connection")
    }
    if case .blocked(let index, let kind, let reason) = Self.evaluate(
      plan.statements, policy: effective, dialect: engine.dialect)
    {
      throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
    }
    var summary = plan.summary
    if plan.statements.isEmpty { return summary }
    let total = plan.statements.count
    let report: @Sendable (Int) -> Void = {
      progress(SQLRestoreProgress(statementsDone: $0, statementCount: total))
    }
    // Anything sent may have changed columns: inline edits must read the tables again
    defer {
      editTableCache.removeAll()
      mysqlTableColumns.removeAll()
    }
    try await PerfSignpost.interval("restore.run") {
      switch engine {
      case .postgresql, .sqlite, .duckdb:
        try refuseIfEnding()
        try refuseIfOwnedByAnotherCaller(caller)
        try refuseIfAborted()
        if engine == .duckdb { try refuseDuckDBRestoreInTransaction(effective) }
        guard session != nil else { throw DatabaseError.notConnected }
        try refuseIfConnectionClosed()
        summary.insideUserTransaction = userTxOpen
        let bound = plan.statements.map {
          BoundStatement(sql: $0.text, values: [], expectedRows: nil, classified: $0)
        }
        summary.statementsRun = try await runStagedBatch(
          bound, caller: caller, protectedMode: effective.protectedMode,
          cancellationGeneration: generation, progress: report
        ).count
        summary.pending = effective.protectedMode
      case .mysql:
        summary.statementsRun = try await runMySQLRestore(
          plan, policy: policy, effective: effective, epoch: epoch, caller: caller,
          progress: report)
      case .mongodb:
        throw SQLRestoreError.unsupportedEngine(engine.rawValue)
      }
    }
    return summary
  }

  // MARK: - Private

  /// DuckDB has no SAVEPOINT, which the batch sends inside a transaction (Protected mode, or the
  /// user's own): both are refused before anything is sent
  private func refuseDuckDBRestoreInTransaction(_ effective: ProtectionPolicy) throws {
    if effective.protectedMode {
      throw DatabaseError.sequentialBatchRefused(SQLRestorePlan.duckdbProtectedModeMessage)
    }
    if !txState.isIdle || userTxOpen {
      throw DatabaseError.sequentialBatchRefused(
        "Commit or roll back the open transaction first, then restore the dump.")
    }
  }

  /// One by one in autocommit; the session settings are reset afterwards on every path
  private func runMySQLRestore(
    _ plan: SQLRestorePlan, policy: ProtectionPolicy, effective: ProtectionPolicy,
    epoch: UInt64, caller: UUID?, progress: @escaping @Sendable (Int) -> Void
  ) async throws -> Int {
    // `executeGatedSequentialBatch` refuses these too; checked here before the settings read
    try refuseIfOwnedByAnotherCaller(caller)
    if !txState.isIdle || userTxOpen {
      throw DatabaseError.sequentialBatchRefused(
        "Commit or roll back the open transaction first, then restore the dump.")
    }
    if effective.protectedMode {
      throw DatabaseError.sequentialBatchRefused(
        "Turn Protected mode off for this connection to restore a MySQL dump: MySQL commits "
          + "each schema change at once, so the restore cannot wait for Commit.")
    }
    guard session != nil else { throw DatabaseError.notConnected }
    try refuseIfConnectionClosed()
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    // Read in the same turn, so a Cancel during the settings read stops the restore. Nothing
    // was changed yet, so a refusal here owes no reset.
    let generation = batchCancellationGeneration
    let settings: (sqlMode: String, timeZone: String)
    do {
      settings = try await readRestoreSessionSettings()
    } catch {
      try refuseIfRestoreInterrupted(since: generation, epoch: epoch)
      throw error
    }
    // `sendSequentially` reads the generation again with no suspension before it
    try refuseIfRestoreInterrupted(since: generation, epoch: epoch)
    let counts: [Int]
    do {
      counts = try await executeGatedSequentialBatch(
        plan.statements.map(\.text), policy: policy, connectionEpoch: epoch, caller: caller,
        expectedRows: nil, progress: progress)
    } catch {
      if let failure = await resetRestoreSession(settings, epoch: epoch) {
        await closeUnresetSession()
        throw SQLRestoreError.restoreFailedSessionClosed(
          restoreFailure: error.localizedDescription, reason: failure)
      }
      throw error
    }
    if let failure = await resetRestoreSession(settings, epoch: epoch) {
      await closeUnresetSession()
      throw SQLRestoreError.sessionNotReset(statementsRun: counts.count, reason: failure)
    }
    return counts.count
  }

  /// After the restore's first read: a Cancel meanwhile (`DatabaseError.batchCancelled`) or
  /// another connection (`SQLRestoreError.connectionChanged`) stops it before anything is changed
  private func refuseIfRestoreInterrupted(since generation: UInt64, epoch: UInt64) throws {
    guard generation == batchCancellationGeneration else { throw DatabaseError.batchCancelled }
    guard epoch == connectionEpoch else {
      throw SQLRestoreError.connectionChanged
    }
  }

  /// PostgreSQL: the session must report `standard_conforming_strings` `on`, as the plan read
  /// statement `index` and the ones after it (never guessed: off or unreadable refuses)
  /// - Throws: `SQLRestoreError.standardStringsOff` / `.standardStringsUnreadable`;
  ///   `DatabaseError` from the session.
  private func requireStandardConformingStrings(statement index: Int) async throws {
    let rows: [[CellValue]]
    do {
      rows = try await withSession { session in
        var rows: [[CellValue]] = []
        for try await row in try await session.query(Self.standardStringsQuery, binds: []).rows {
          rows.append(row)
        }
        return rows
      }
    } catch let error as DatabaseError {
      throw error
    } catch {
      throw SQLRestoreError.standardStringsUnreadable(error.localizedDescription)
    }
    guard rows.count == 1, rows[0].count == 1, case .string(let value) = rows[0][0] else {
      throw SQLRestoreError.standardStringsUnreadable("unexpected answer")
    }
    guard value == "on" else {
      throw SQLRestoreError.standardStringsOff(index: index, value: value)
    }
  }

  /// The restore's session settings (foreign key checks off, the dump's sql_mode and
  /// time_zone) could not be reset: the session is forgotten and closed, and reported lost
  /// (`SessionLostEvent`), so nothing else runs on it and Reconnect opens a freshly pinned one
  private func closeUnresetSession() async {
    guard session != nil else { return }
    let event = SessionLostEvent(state: txState, userTxOpen: userTxOpen, epoch: connectionEpoch)
    let forgotten = forgetConnection()
    activeUnrememberedCertificate = nil
    activeUnrememberedSSHCredential = nil
    lastSessionLoss = event
    sessionEventsContinuation.yield(event)
    await AppLogger.shared.warning(
      "Closed the session: its settings were not reset after a restore", category: "Database")
    await Self.closeForgotten(forgotten, includingConnection: true)
  }

  /// The session's sql_mode (without the flags the app's lexer cannot read,
  /// `MySQLSession.pinnedSQLMode`) and time_zone, checked to be plain names before they are
  /// written into the reset statement.
  /// - Throws: `SQLRestoreError.sessionSettingsUnreadable`; `DatabaseError` from the session.
  private func readRestoreSessionSettings() async throws -> (sqlMode: String, timeZone: String) {
    let row: [CellValue]?
    do {
      row = try await withSession { session in
        var rows: [[CellValue]] = []
        for try await row in try await session.query(Self.restoreSessionQuery, binds: []).rows {
          rows.append(row)
        }
        return rows.first
      }
    } catch let error as DatabaseError {
      throw error
    } catch {
      throw SQLRestoreError.sessionSettingsUnreadable(error.localizedDescription)
    }
    guard let row, row.count == 2, case .string(let zone) = row[1] else {
      throw SQLRestoreError.sessionSettingsUnreadable("unexpected answer")
    }
    let mode: String
    switch row[0] {
    case .string(let text): mode = MySQLSession.pinnedSQLMode(text)
    case .null: mode = ""
    default: throw SQLRestoreError.sessionSettingsUnreadable("unexpected sql_mode")
    }
    let modeIsPlain = mode.unicodeScalars.allSatisfy {
      ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
        || $0 == "_" || $0 == ","
    }
    let zoneIsPlain =
      !zone.isEmpty
      && zone.unicodeScalars.allSatisfy {
        ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
          || "_+-:/".unicodeScalars.contains($0)
      }
    guard modeIsPlain, zoneIsPlain else {
      throw SQLRestoreError.sessionSettingsUnreadable("unexpected sql_mode or time_zone")
    }
    return (mode, zone)
  }

  /// Foreign key checks back on, then the sql_mode and time_zone read before the restore, on the
  /// same session (a reconnect re-pinned a new one). Each statement is tried. Returns the first
  /// failure, or nil.
  private func resetRestoreSession(
    _ settings: (sqlMode: String, timeZone: String), epoch: UInt64
  ) async -> String? {
    guard epoch == connectionEpoch, session != nil else { return nil }
    var failure: String?
    for sql in [
      "SET FOREIGN_KEY_CHECKS=1",
      "SET SESSION sql_mode = '\(settings.sqlMode)', time_zone = '\(settings.timeZone)'",
    ] {
      do {
        _ = try await sendTransactionControl(sql)
      } catch {
        failure = failure ?? error.localizedDescription
      }
    }
    if let failure {
      await AppLogger.shared.warning(
        "Could not reset the session after a restore: \(failure)", category: "Database")
    }
    return failure
  }
}
