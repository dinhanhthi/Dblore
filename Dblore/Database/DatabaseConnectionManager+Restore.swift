// DatabaseConnectionManager+Restore.swift
// Restore of a Dblore SQL dump (`SQLDumpWriter`) through the gate. `SQLRestorePlan` reads the
// script once: the 64 MiB cap, the header engine, one split, then every statement is classified
// and must be a statement shape the dump writer emits for that engine (leading tokens; a data
// INSERT is read to its end and may hold only the literals the writer emits). A version 2 dump
// may also drop, with `DROP <kind> IF EXISTS` and never CASCADE, the tables, views, sequences,
// domains and types it creates later in the same script. PostgreSQL catalog
// text prints plain `'...'` strings with a backslash (`'^\d+$'`): such a schema statement is
// read as `standard_conforming_strings = on` reads it, and runs only once the session says on.
// `executeGatedRestore` checks the plan against the merged policy before anything is sent. A
// restore that drops first reads the target's catalog, so a DROP removes only what the script
// recreates: PostgreSQL partitions and owned sequences (which DROP TABLE takes along) and types
// that are not enums (which DROP TYPE drops), DuckDB databases a schema name could reach and a session moved off
// `main`, SQLite names in temp or an attached database (an unqualified DROP looks there), and
// SQLite foreign keys (SQLite's DROP TABLE deletes the rows, which fires the ON DELETE actions
// of tables the dump does not drop).
// PostgreSQL and SQLite run it as one staged batch (atomic; inside the app transaction under
// Protected mode). DuckDB runs it as one staged batch too, but has no SAVEPOINT, so it is
// refused under Protected mode and with a transaction open. MySQL commits each schema change at
// once, so it runs one statement at a time (refused with a transaction open or under Protected
// mode) and afterwards always resets the session settings the dump changed, or closes the
// session when that fails.

import Foundation

/// What a restored statement is, for the confirmation and history
nonisolated enum SQLRestoreStatementKind: String, Sendable, CaseIterable {
  /// A version 2 dump's `DROP VIEW / TABLE / SEQUENCE / DOMAIN / TYPE IF EXISTS` of an object it
  /// creates later (MySQL commits each one at once)
  case drop
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

  /// Schema statements, drops or triggers (history records the restore as a schema change)
  var changesSchema: Bool { count(.schema) + count(.drop) + count(.trigger) > 0 }
}

/// How far a restore is
nonisolated struct SQLRestoreProgress: Sendable, Equatable {
  var statementsDone: Int
  var statementCount: Int
}

/// How far reading and planning a restore file is (`DatabaseBackupModel.readPlan`)
nonisolated enum SQLRestoreReadProgress: Sendable, Equatable {
  /// `bytesRead` of the file's `byteCount`
  case reading(bytesRead: Int, byteCount: Int)
  /// The first `statementsPlanned` of the script's `statementCount` pieces are checked; 0 of 0
  /// while the script is split
  case planning(statementsPlanned: Int, statementCount: Int)
}

/// Why a restore was refused or did not finish cleanly. Every case but `sessionNotReset` and
/// `restoreFailedSessionClosed` means nothing was executed (the `standardStrings` cases follow
/// only the `SHOW standard_conforming_strings` read, the drop target and foreign key cases only
/// the catalog reads of `executeGatedRestore`); those two closed the connection.
nonisolated enum SQLRestoreError: LocalizedError, Equatable, Sendable {
  case tooLarge(bytes: Int)
  case headerMissing
  /// The header is a Dblore dump's, of a version after 2
  case newerDumpVersion
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
  /// SQLite: the dump drops `dropped`, and `table`, which it does not drop, has a foreign key to
  /// it with ON DELETE `action`, which the DROP's implicit DELETE would fire
  case dropFiresForeignKeyAction(table: String, dropped: String, action: String)
  /// SQLite: the target's foreign keys could not be read before a restore that drops tables
  case foreignKeysUnreadable(String)
  /// The target's objects could not be read before a restore that drops
  case dropTargetsUnreadable(String)
  /// SQLite: the dump drops `name`, which the connection has in its `database` schema (temp, or
  /// an attached database while main has none), where an unqualified DROP would find it
  case dropReachesOtherDatabase(name: String, database: String)
  /// DuckDB: the dump drops in the schema `name`, which also names a database of the session
  case dropNamesDuckDBDatabase(name: String)
  /// DuckDB: the session's current schema is not `main` of its own database (USE, SET schema or
  /// SET search_path ran), where the dump's unqualified objects would not land in `main`
  case duckdbSessionNotAtMain(schema: String, searchPath: String)
  /// PostgreSQL: DROP TABLE `table` also removes `object` (its `objectKind`: a partition or
  /// child table, or a sequence it owns), which the dump does not drop and recreate
  case dropTakesAlong(table: String, object: String, objectKind: String)
  /// PostgreSQL: the dump drops the type `name` with DROP TYPE, and the target's `name` is a
  /// domain, which DROP TYPE removes too
  case dropTypeIsDomain(name: String)
  /// PostgreSQL: the dump drops the type `name` with DROP TYPE (it writes only enums), and the
  /// target's `name` is another kind of type (range, composite, base), which DROP TYPE removes
  /// with what goes along with it (a range's multirange and constructors)
  case dropTypeNotEnum(name: String)

  var errorDescription: String? {
    switch self {
    case .tooLarge(let bytes):
      "This file is \(bytes / 1_048_576) MiB; a SQL dump restore reads files up to 64 MiB. "
        + "Nothing was executed."
    case .headerMissing:
      "This file is not a Dblore SQL dump: its first line is not \""
        + SQLRestorePlan.headerPrefix + "<engine> ...\". Nothing was executed."
    case .newerDumpVersion:
      "This dump was made by a newer Dblore; update Dblore to restore it. Nothing was executed."
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
    case .dropFiresForeignKeyAction(let table, let dropped, let action):
      "This dump drops the table \"\(dropped)\", and \"\(table)\", which the dump does not "
        + "drop, has a foreign key to it with ON DELETE \(action). SQLite's DROP TABLE deletes "
        + "the rows first, which would run that action on \"\(table)\". Nothing was executed."
    case .foreignKeysUnreadable(let reason):
      "Could not read this database's foreign keys, which decide whether dropping the dump's "
        + "tables would change other tables (\(reason)). Nothing was executed."
    case .dropTargetsUnreadable(let reason):
      "Could not read this database's objects, which decide what the dump's DROP statements "
        + "would remove (\(reason)). Nothing was executed."
    case .dropReachesOtherDatabase(let name, let database):
      "This dump drops \"\(name)\", and this connection also has \"\(name)\" in its "
        + "\"\(database)\" database. SQLite's DROP looks in temp first, then main, then the "
        + "attached databases, so it could remove that one instead. Nothing was executed."
    case .dropNamesDuckDBDatabase(let name):
      "This dump drops objects of the schema \"\(name)\", which is also the name of a database "
        + "in this session, where DuckDB could find them instead. Nothing was executed."
    case .duckdbSessionNotAtMain(let schema, let searchPath):
      "This session's current schema is \"\(schema)\" with the search path \"\(searchPath)\" "
        + "(set by USE, SET schema or SET search_path), so the dump's objects would not land in "
        + "the main schema of this database. Reconnect, then restore. Nothing was executed."
    case .dropTakesAlong(let table, let object, let objectKind):
      "This dump drops the table \"\(table)\", and PostgreSQL's DROP TABLE also removes its "
        + "\(objectKind) \"\(object)\", which the dump does not recreate. Nothing was executed."
    case .dropTypeIsDomain(let name):
      "This dump drops the type \"\(name)\", which is a domain in this database: DROP TYPE "
        + "would remove that domain. Nothing was executed."
    case .dropTypeNotEnum(let name):
      "This dump drops the type \"\(name)\", which is not an enum in this database: DROP TYPE "
        + "would remove that type and what goes with it, which the dump does not recreate. "
        + "Nothing was executed."
    }
  }
}

/// A dump script read once (pure, off the actor): the statements to send, as classified for the
/// gate, and their counts for the confirmation. `executeGatedRestore` runs it as is.
nonisolated struct SQLRestorePlan: Sendable {
  /// The splitter holds the script as Unicode scalars (about 4 bytes each), alone: the script's
  /// text is freed once they are built, and they are freed once split. 64 MiB of SQL costs about
  /// 256 MiB of scalars plus the statements' text, up to about 400 MiB at peak
  static let maxScriptBytes = 64 * 1024 * 1024
  /// First line of every dump (`SQLDumpAssembler.header`), followed by the engine's raw value
  static let headerPrefix = "-- Dblore SQL dump 1 engine="
  /// First line of a dump that holds a DROP (version 2). Builds that read only version 1 refuse
  /// it at the header, so no DROP reaches them.
  static let dropHeaderPrefix = "-- Dblore SQL dump 2 engine="
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
  /// SQLite: the tables the script drops (`objectKey` parts), whose foreign keys
  /// `executeGatedRestore` checks before the batch
  let droppedSQLiteTables: Set<[UInt8]>
  /// SQLite: the tables and views the script drops (`objectKey` parts), which
  /// `executeGatedRestore` checks only main holds (`checkSQLiteDropTargets`)
  let droppedSQLiteNames: Set<[UInt8]>
  /// DuckDB: the schemas (first name parts, ASCII lowercased) the script drops in, which
  /// `executeGatedRestore` checks against the session's databases (`checkDuckDBDropTargets`)
  let droppedDuckDBSchemas: Set<String>
  /// PostgreSQL: the dropped tables and types `executeGatedRestore` checks in the target
  /// (`checkPostgresDropTargets`), nil when the script drops neither
  let postgresDrops: PostgresDrops?

  /// What a PostgreSQL script drops and creates, as `objectKey` parts (`[schema, name]`)
  struct PostgresDrops: Sendable, Equatable {
    var tables: Set<[[UInt8]]>
    var types: Set<[[UInt8]]>
    /// Every sequence the script creates
    var createdSequences: Set<[[UInt8]]>
  }

  /// - Throws: `SQLRestoreError` (too large, header missing or another engine, a NUL in a
  ///   SQLite or DuckDB script, the first statement a dump never writes, or a DROP of an object
  ///   the script does not create after it); `CancellationError` when the task planning it is
  ///   cancelled
  /// `script` is consumed: a caller that hands over its only copy (`consume`) has it freed
  /// before the split. `progress` gets the statements checked, every 4,096 and at the end.
  init(
    script: consuming String, engine: DatabaseType,
    progress: (SQLRestoreReadProgress) -> Void = { _ in }
  ) throws {
    let bytes = script.utf8.count
    guard bytes <= Self.maxScriptBytes else { throw SQLRestoreError.tooLarge(bytes: bytes) }
    switch engine {
    case .postgresql, .mysql, .sqlite, .duckdb: break
    case .mongodb: throw SQLRestoreError.unsupportedEngine(engine.rawValue)
    }
    let version = try Self.checkHeader(script, engine: engine)
    let dialect = engine.dialect
    progress(.planning(statementsPlanned: 0, statementCount: 0))
    let pieces: [String]
    do {
      // One buffer at a time: the text goes once its scalars are built, they go once split
      var scalars: [Unicode.Scalar] = []
      scalars.reserveCapacity(bytes)
      scalars.append(contentsOf: script.unicodeScalars)
      _ = consume script
      // Both read statements as C strings: a NUL would cut the statement the whitelist approved
      if engine == .sqlite || engine == .duckdb, scalars.contains("\0") {
        throw SQLRestoreError.containsNUL
      }
      pieces = SQLTokenizer(dialect: dialect).splitStatements(scalars: scalars)
    }
    var statements: [ClassifiedStatement] = []
    var kinds: [SQLRestoreStatementKind] = []
    var options: [String] = []
    var standardStrings: Int?
    // DuckDB: the sequences the file created so far (`checkDuckDBSequences`)
    var sequences = Set<[String]>()
    // Each DROP's targets, checked once the loop ends against the last CREATE of each object
    var drops: [(index: Int, target: DropTarget)] = []
    var lastCreated: [ObjectKey: Int] = [:]
    for (planned, piece) in pieces.enumerated() {
      // A file read cancelled while it is planned stops here
      try Task.checkCancellation()
      if planned.isMultiple(of: 4_096) {
        progress(.planning(statementsPlanned: planned, statementCount: pieces.count))
      }
      guard let classified = SQLStatementClassifier.classifyStatement(piece, dialect: dialect)
      else { continue }
      let accepted = try Self.accept(
        classified, engine: engine, version: version, index: statements.count)
      if engine == .duckdb, accepted.kind == .schema {
        try Self.checkDuckDBSequences(
          classified.text, created: &sequences, index: statements.count)
      }
      drops += accepted.drops.map { (statements.count, $0) }
      if let created = accepted.created { lastCreated[created] = statements.count }
      if accepted.standardStrings, standardStrings == nil { standardStrings = statements.count }
      statements.append(accepted.statement)
      kinds.append(accepted.kind)
      options += accepted.options
    }
    progress(.planning(statementsPlanned: pieces.count, statementCount: pieces.count))
    // A DROP only clears the way for an object of the same kind and name created after it
    for drop in drops where lastCreated[drop.target.key, default: -1] < drop.index {
      throw Self.refusal(
        drop.index,
        "a Dblore dump drops only what it creates after the DROP, and this script never creates "
          + "\(drop.target.key.kind) \(drop.target.name) after it")
    }
    self.engine = engine
    self.statements = statements
    self.kinds = kinds
    standardStringsStatement = standardStrings
    droppedSQLiteTables =
      engine == .sqlite
      ? Set(drops.filter { $0.target.key.kind == "TABLE" }.map { $0.target.key.parts[0] }) : []
    droppedSQLiteNames = engine == .sqlite ? Set(drops.map { $0.target.key.parts[0] }) : []
    droppedDuckDBSchemas =
      engine == .duckdb
      ? Set(drops.map { String(decoding: $0.target.key.parts[0], as: UTF8.self) }) : []
    let dropped = { (kind: String) in
      Set(drops.filter { $0.target.key.kind == kind }.map(\.target.key.parts))
    }
    let postgres = PostgresDrops(
      tables: dropped("TABLE"), types: dropped("TYPE"),
      createdSequences: Set(lastCreated.keys.filter { $0.kind == "SEQUENCE" }.map(\.parts)))
    postgresDrops =
      engine == .postgresql && !(postgres.tables.isEmpty && postgres.types.isEmpty)
      ? postgres : nil
    summary = SQLRestoreSummary(
      engine: engine, statementCount: statements.count,
      counts: kinds.reduce(into: [:]) { $0[$1, default: 0] += 1 }, serverVersionOptions: options)
  }

  // MARK: - Header

  /// The first line must be `headerPrefix` (version 1) or `dropHeaderPrefix` (version 2) +
  /// `engine.rawValue`, then a space or the line end. Compared scalar by scalar (no canonical
  /// equivalence). Returns the version. A later version's header (`isNewerHeader`) is refused
  /// as such.
  private static func checkHeader(_ script: String, engine: DatabaseType) throws -> Int {
    let line = script.unicodeScalars.prefix { $0 != "\n" && $0 != "\r" }
    let version: Int
    if line.starts(with: headerPrefix.unicodeScalars) {
      version = 1
    } else if line.starts(with: dropHeaderPrefix.unicodeScalars) {
      version = 2
    } else if isNewerHeader(line) {
      throw SQLRestoreError.newerDumpVersion
    } else {
      throw SQLRestoreError.headerMissing
    }
    let name = line.dropFirst(headerPrefix.unicodeScalars.count).prefix { $0 != " " }
    guard !name.isEmpty else { throw SQLRestoreError.headerMissing }
    guard name.elementsEqual(engine.rawValue.unicodeScalars) else {
      throw SQLRestoreError.engineMismatch(
        dump: String(String.UnicodeScalarView(name)), connection: engine.rawValue)
    }
    return version
  }

  /// `-- Dblore SQL dump <N> engine=` with N, ASCII digits, above 2
  private static func isNewerHeader(_ line: Substring.UnicodeScalarView) -> Bool {
    let lead = "-- Dblore SQL dump ".unicodeScalars
    guard line.starts(with: lead) else { return false }
    let rest = line.dropFirst(lead.count)
    let digits = rest.prefix { ("0"..."9").contains($0) }
    guard !digits.isEmpty, rest.dropFirst(digits.count).starts(with: " engine=".unicodeScalars)
    else { return false }
    let number = digits.drop { $0 == "0" }
    return number.count > 1 || (number.first.map { $0 > "2" } ?? false)
  }

  // MARK: - Accepted statements

  private struct Accepted {
    let statement: ClassifiedStatement
    let kind: SQLRestoreStatementKind
    var options: [String] = []
    /// Read with `standard_conforming_strings = on` (`standardConformingSchema`)
    var standardStrings = false
    /// The object a schema statement creates (`createdObject`)
    var created: ObjectKey?
    /// The objects a DROP names (`dropTargets`)
    var drops: [DropTarget] = []
  }

  /// Only the statement shapes `SQLDumpWriter` writes for `engine`, matched on their leading
  /// tokens (`isDumpSchema`) or, for data, whole (`dataRefusal`), plus these exact forms: the dump's MySQL session
  /// settings and foreign key switches, SQLite `PRAGMA defer_foreign_keys = ON`, PostgreSQL
  /// `SELECT pg_catalog.setval('<name>', <n>, true | false)`, a SQLite `CREATE TRIGGER` the
  /// splitter kept whole, a MySQL CREATE TABLE whose only unknown parts are server-version
  /// options, and a PostgreSQL schema statement unknown only for a plain string with a backslash
  /// (`standardConformingSchema`). A version 2 dump may also hold the DROPs of `dropTargets`
  /// (the plan then checks each target is created after it). Anything else (roles, users,
  /// grants, extensions, functions, other DROPs, UPDATE, other DELETEs, reads, SET, transaction
  /// control, utilities, other PRAGMAs) is refused.
  private static func accept(
    _ statement: ClassifiedStatement, engine: DatabaseType, version: Int, index: Int
  ) throws -> Accepted {
    let dialect = engine.dialect
    let tokens = tokens(statement.text, dialect)
    if statement.changesPrivileges || statement.affectsAllRows {
      throw refusal(index, notWritten(tokens))
    }
    if engine == .mysql, let reason = setNamesRefusal(statement.text, tokens) {
      throw refusal(index, reason)
    }
    switch statement.kind {
    case .dml:
      if let reason = dataRefusal(tokens, engine: engine) { throw refusal(index, reason) }
      return Accepted(statement: statement, kind: .data)
    case .ddl where tokens.first?.isWord("DROP") == true:
      guard version >= 2 else { throw refusal(index, notWritten(tokens)) }
      guard let targets = dropTargets(tokens, engine: engine) else {
        throw refusal(
          index,
          "a Dblore dump drops only with DROP "
            + droppedKinds(engine).joined(separator: " / ")
            + " IF EXISTS and the names it writes, never with CASCADE or RESTRICT")
      }
      return Accepted(statement: statement, kind: .drop, drops: targets)
    case .ddl where engine == .sqlite && startsWithPragma(statement.text):
      guard tokens == sqlitePragmaTokens else {
        throw refusal(index, "only the PRAGMA defer_foreign_keys = ON of a dump is restored")
      }
      return Accepted(statement: statement, kind: .sessionSetting)
    case .ddl:
      guard isDumpSchema(tokens, engine: engine) else {
        throw refusal(index, notWritten(tokens))
      }
      return Accepted(
        statement: statement, kind: .schema, created: createdObject(tokens, engine: engine))
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
      return Accepted(
        statement: with(statement, kind: .ddl), kind: .schema, options: options,
        created: createdObject(tokens, engine: engine))
    case .unknown where engine == .postgresql:
      guard let read = standardConformingSchema(statement.text) else {
        throw refusal(index, describe(statement.kind))
      }
      // The name comes before any string, so the tokens read either way agree there
      return Accepted(
        statement: read, kind: .schema, standardStrings: true,
        created: createdObject(tokens, engine: engine))
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

  /// The refusal reason for a MySQL `SET NAMES`, also inside a version comment, other than the
  /// dump's own `SET NAMES utf8mb4;` (any other spelling, charset or COLLATE): it names the
  /// statement's text without its comments (`strippingComments`, which keeps a version comment),
  /// whitespace runs shown as one space, cut at 100 characters. Nil for
  /// anything else. Nothing is rewritten: the session already pinned utf8mb4 on connect.
  private static func setNamesRefusal(_ text: String, _ tokens: [SQLToken]) -> String? {
    guard let first = tokens.first, first.isWord("SET") || first.kind == .executableComment,
      !mysqlSettingTokens.contains(tokens)
    else { return nil }
    let tokenizer = SQLTokenizer(dialect: .mysql)
    let opened = tokenizer.tokens(withVersionCommentsOpened(text, tokenizer))
    guard opened.count >= 2, opened[0].isWord("SET"), opened[1].isWord("NAMES") else {
      return nil
    }
    var shown = tokenizer.strippingComments(text).split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    if shown.count > 100 { shown = shown.prefix(100) + "…" }
    return "\"\(shown)\" sets the connection's character set, but Dblore restores only the "
      + "statements its own dumps write (SET NAMES utf8mb4;), and this session already uses "
      + "utf8mb4"
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

  // MARK: - Drops

  /// An object a DROP names or a CREATE makes, as the engine tells names apart (`objectKey`)
  fileprivate struct ObjectKey: Hashable, Sendable {
    /// TABLE, VIEW, SEQUENCE, DOMAIN or TYPE (a SQLite virtual table is a TABLE)
    let kind: String
    /// Name parts as UTF-8 bytes: compared byte for byte, never by canonical equivalence
    let parts: [[UInt8]]
  }

  /// A DROP's target and its name as written, for a refusal
  fileprivate struct DropTarget: Sendable {
    let key: ObjectKey
    let name: String
  }

  /// The kinds a dump of `engine` drops (`SQLDumpDDL`)
  fileprivate static func droppedKinds(_ engine: DatabaseType) -> [String] {
    switch engine {
    case .postgresql: ["VIEW", "TABLE", "SEQUENCE", "DOMAIN", "TYPE"]
    case .duckdb: ["VIEW", "TABLE", "SEQUENCE", "TYPE"]
    case .mysql, .sqlite: ["VIEW", "TABLE"]
    case .mongodb: []
    }
  }

  /// `DROP <kind> IF EXISTS <name>` with nothing after it (PostgreSQL TABLE: `<name>, ...`), as
  /// `SQLDumpDDL` writes it, for a kind of `droppedKinds` and names `objectKey` can compare: its
  /// targets. Nil for anything else: no CASCADE, RESTRICT, TEMPORARY or MATERIALIZED, no DROP
  /// without IF EXISTS, no list on another kind or engine.
  fileprivate static func dropTargets(
    _ tokens: [SQLToken], engine: DatabaseType
  ) -> [DropTarget]? {
    var shape = ShapeReader(tokens)
    guard shape.words("DROP"), let kind = shape.anyOf(droppedKinds(engine)),
      shape.words("IF", "EXISTS")
    else { return nil }
    var targets: [DropTarget] = []
    repeat {
      guard let parts = shape.nameParts(),
        let key = objectKey(kind, parts, engine: engine, creating: false)
      else { return nil }
      targets.append(DropTarget(key: key, name: parts.map(\.text).joined(separator: ".")))
    } while engine == .postgresql && kind == "TABLE" && shape.symbol(",")
    return shape.atEnd ? targets : nil
  }

  /// The object a dump's schema statement creates, for the kinds a dump drops: `CREATE TABLE`
  /// (SQLite also `VIRTUAL TABLE`), `VIEW` (MySQL after `ALGORITHM = ...` and `SQL SECURITY
  /// ...`), `SEQUENCE`, `DOMAIN` and `TYPE`, by `objectKey`. Nil for anything else (schemas,
  /// indexes, triggers, ALTER).
  fileprivate static func createdObject(_ tokens: [SQLToken], engine: DatabaseType) -> ObjectKey? {
    var shape = ShapeReader(tokens)
    guard shape.words("CREATE") else { return nil }
    if engine == .mysql {
      if shape.words("ALGORITHM"), !(shape.symbol("=") && shape.anyWord()) { return nil }
      if shape.words("SQL", "SECURITY"), !shape.anyWord() { return nil }
    }
    if engine == .sqlite, shape.words("VIRTUAL") {
      guard shape.peek("TABLE") else { return nil }
    }
    guard let kind = shape.anyOf(droppedKinds(engine)) else { return nil }
    if engine == .sqlite { _ = shape.words("IF", "NOT", "EXISTS") }
    guard let parts = shape.nameParts() else { return nil }
    return objectKey(kind, parts, engine: engine, creating: true)
  }

  /// `parts` as `engine` tells names apart, or nil when the name cannot be compared safely
  /// (a nil DROP target is refused; a nil CREATE never matches one):
  /// - PostgreSQL: `<schema>.<name>` (the writer qualifies every object), not in a system
  ///   schema (`isSystemSchema`); an unquoted part folds ASCII letters to lowercase, a quoted
  ///   one is exact. An unquoted part with a non-ASCII letter is left out: a single-byte server
  ///   encoding folds those too. So is a part over 63 UTF-8 bytes: the server truncates it, so
  ///   the catalog's name would never match the key. The limit is measured in UTF-8; on a
  ///   server whose encoding is not UTF8 and stores a character in more bytes, the cut can
  ///   fall elsewhere (rare).
  /// - MySQL: one backquoted part, exact. Unquoted names are left out: the tokenizer drops
  ///   their case, which `lower_case_table_names` may or may not ignore.
  /// - SQLite: one part, ASCII case-insensitive, quoted or not, as SQLite compares names.
  /// - DuckDB: `<schema>.<name>`, ASCII case-insensitive, never a system name
  ///   (`isDuckDBSystemName`); a CREATE's one-part name is in `main` (the catalog leaves `main`
  ///   out), a DROP's must be qualified.
  fileprivate static func objectKey(
    _ kind: String, _ parts: [SQLToken], engine: DatabaseType, creating: Bool
  ) -> ObjectKey? {
    func folded(_ token: SQLToken) -> [UInt8] {
      Array(SQLTokenizer.asciiLowercased(token.text).utf8)
    }
    let key: [[UInt8]]
    switch engine {
    case .postgresql:
      guard parts.count == 2, !isSystemSchema(parts[0]) else { return nil }
      var exact: [[UInt8]] = []
      for part in parts {
        if part.kind == .quotedIdentifier {
          exact.append(Array(part.text.utf8))
        } else {
          guard part.asciiText != nil else { return nil }
          exact.append(folded(part))
        }
        // The server truncates a longer name (NAMEDATALEN - 1), the catalog holds the cut one
        guard exact[exact.count - 1].count <= 63 else { return nil }
      }
      key = exact
    case .mysql:
      guard parts.count == 1, parts[0].kind == .quotedIdentifier else { return nil }
      key = [Array(parts[0].text.utf8)]
    case .sqlite:
      guard parts.count == 1 else { return nil }
      key = [folded(parts[0])]
    case .duckdb:
      if parts.count == 2, !isDuckDBSystemName(parts[0]) {
        key = parts.map(folded)
      } else if creating, parts.count == 1 {
        key = [Array("main".utf8), folded(parts[0])]
      } else {
        return nil
      }
    case .mongodb:
      return nil
    }
    return ObjectKey(kind: kind, parts: key)
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

// MARK: - Drop targets in the database

/// Before a restore that drops, the target's catalog decides whether each DROP removes only what
/// the script recreates. Pure: `executeGatedRestore` reads the rows and these decide.
nonisolated extension SQLRestorePlan {
  private static func unreadable() -> SQLRestoreError {
    .dropTargetsUnreadable("unexpected answer")
  }

  /// SQLite: an unqualified DROP looks in temp, then main, then the attached databases, and
  /// the script's CREATE goes into main. `objects` are the tables and views of every schema
  /// (`schema`, `name`). Refused when a dropped name is in temp (it shadows main), or in another
  /// database while main has none. Names compare ASCII case-insensitively, as SQLite does.
  /// - Throws: `SQLRestoreError.dropReachesOtherDatabase`
  static func checkSQLiteDropTargets(
    _ objects: [(schema: String, name: String)], dropped: Set<[UInt8]>
  ) throws {
    func folded(_ text: String) -> [UInt8] { Array(SQLTokenizer.asciiLowercased(text).utf8) }
    let inMain = Set(objects.filter { folded($0.schema) == folded("main") }.map { folded($0.name) })
    for object in objects where dropped.contains(folded(object.name)) {
      let schema = folded(object.schema)
      if schema == folded("temp")
        || (schema != folded("main") && !inMain.contains(folded(object.name)))
      {
        throw SQLRestoreError.dropReachesOtherDatabase(name: object.name, database: object.schema)
      }
    }
  }

  /// DuckDB: `rows` are `database_name, current_schema(), current_setting('search_path')`, one
  /// per database of the session. Refused unless the session is at its defaults (`main` with an
  /// empty search path: no USE or SET moved it, so a one-part CREATE lands in `main` of the
  /// connection's own database, as `objectKey` keys it), and when a schema the script drops in
  /// also names a database: DuckDB reads `a.b` as schema `a`, else as table `b` of database
  /// `a`, so the DROP could reach an attached database while the CREATE lands in a new schema.
  /// - Throws: `SQLRestoreError.duckdbSessionNotAtMain`, `.dropNamesDuckDBDatabase`,
  ///   `.dropTargetsUnreadable`
  static func checkDuckDBDropTargets(_ rows: [[CellValue]], droppedSchemas: Set<String>) throws {
    guard !rows.isEmpty else { throw unreadable() }
    var databases = Set<String>()
    for row in rows {
      guard row.count == 3, case .string(let database) = row[0], case .string(let schema) = row[1],
        case .string(let searchPath) = row[2]
      else { throw unreadable() }
      guard schema == "main", searchPath.isEmpty else {
        throw SQLRestoreError.duckdbSessionNotAtMain(schema: schema, searchPath: searchPath)
      }
      databases.insert(SQLTokenizer.asciiLowercased(database))
    }
    if let name = droppedSchemas.intersection(databases).sorted().first {
      throw SQLRestoreError.dropNamesDuckDBDatabase(name: name)
    }
  }

  /// PostgreSQL: `rows` are `kind, schema, name, other schema, other name`: `inherits` (a table
  /// and a partition or child of it), `owns` (a table and a sequence it owns, `OWNED BY`) and
  /// `type` (a type that is not an enum, its `typtype` as the other schema). DROP TABLE without
  /// CASCADE still removes a partitioned table's partitions and the sequences the table owns:
  /// refused when the script does not also drop (and so recreate) that partition or child, or
  /// never creates that sequence. The dump drops only enums with DROP TYPE, which also removes a
  /// domain, or a range type's multirange and constructors: refused when a dropped type is not
  /// an enum. Names compare byte for byte with `objectKey`'s parts.
  /// - Throws: `SQLRestoreError.dropTakesAlong`, `.dropTypeIsDomain`, `.dropTypeNotEnum`,
  ///   `.dropTargetsUnreadable`
  static func checkPostgresDropTargets(_ rows: [[CellValue]], _ drops: PostgresDrops) throws {
    for row in rows {
      guard row.count == 5, case .string(let kind) = row[0], case .string(let schema) = row[1],
        case .string(let name) = row[2], case .string(let otherSchema) = row[3],
        case .string(let otherName) = row[4]
      else { throw unreadable() }
      let key = [Array(schema.utf8), Array(name.utf8)]
      let other = [Array(otherSchema.utf8), Array(otherName.utf8)]
      switch kind {
      case "inherits":
        guard drops.tables.contains(key), !drops.tables.contains(other) else { continue }
        throw SQLRestoreError.dropTakesAlong(
          table: "\(schema).\(name)", object: "\(otherSchema).\(otherName)",
          objectKind: "partition or child table")
      case "owns":
        guard drops.tables.contains(key), !drops.createdSequences.contains(other) else { continue }
        throw SQLRestoreError.dropTakesAlong(
          table: "\(schema).\(name)", object: "\(otherSchema).\(otherName)",
          objectKind: "owned sequence")
      case "type":
        guard drops.types.contains(key) else { continue }
        guard otherSchema != "d" else {
          throw SQLRestoreError.dropTypeIsDomain(name: "\(schema).\(name)")
        }
        throw SQLRestoreError.dropTypeNotEnum(name: "\(schema).\(name)")
      default:
        throw unreadable()
      }
    }
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

  /// Consumes the first of `words` that comes next, and returns it
  mutating func anyOf(_ words: [String]) -> String? {
    guard let word = words.first(where: { peek($0) }) else { return nil }
    index += 1
    return word
  }

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
  /// App-owned read, before a SQLite restore that drops tables
  /// (`SQLRestorePlan.droppedSQLiteTables`), of every table's foreign keys
  static let sqliteForeignKeysQuery =
    "SELECT m.name, f.\"table\", f.on_delete FROM sqlite_master AS m "
    + "JOIN pragma_foreign_key_list(m.name) AS f WHERE m.type = 'table'"
  /// App-owned read, before a SQLite restore that drops, of the connection's schemas (then each
  /// one's tables and views, `SQLRestorePlan.checkSQLiteDropTargets`)
  static let sqliteDatabasesQuery = "SELECT name FROM pragma_database_list"
  /// App-owned read, before a DuckDB restore that drops (`SQLRestorePlan.checkDuckDBDropTargets`)
  static let duckdbDropTargetsQuery =
    "SELECT database_name, current_schema(), current_setting('search_path') "
    + "FROM duckdb_databases()"
  /// App-owned read, before a PostgreSQL restore that drops tables or types
  /// (`SQLRestorePlan.checkPostgresDropTargets`), of only what `drops` needs (never empty: a
  /// plan has `postgresDrops` only when it drops one or the other). Dropped tables: partitions
  /// and children, and owned sequences; only `deptype = 'a'` (OWNED BY) on purpose: an identity
  /// sequence (`'i'`) goes with its column, and the dump's CREATE TABLE recreates it. Dropped
  /// types: the types that are not enums, without a table's row type or an array type (the
  /// server refuses DROP TYPE on those without CASCADE, so the batch rolls back anyway). System
  /// schemas are left out: `objectKey` never keys them. No column is ever NULL
  /// (`checkPostgresDropTargets` reads five text cells): the type branch fills the last with
  /// `'-'`.
  static func postgresDropTargetsQuery(_ drops: SQLRestorePlan.PostgresDrops) -> String {
    // Runs with the user's search_path: every catalog name, function, operator and cast type
    // names pg_catalog (the IN list is an `= ANY` over a typed array)
    var branches: [String] = []
    if !drops.tables.isEmpty {
      branches.append(
        """
        SELECT 'inherits'::pg_catalog.text, pn.nspname::pg_catalog.text,
          pc.relname::pg_catalog.text, cn.nspname::pg_catalog.text, cc.relname::pg_catalog.text
        FROM pg_catalog.pg_inherits i
        JOIN pg_catalog.pg_class pc ON pc.oid OPERATOR(pg_catalog.=) i.inhparent
        JOIN pg_catalog.pg_namespace pn ON pn.oid OPERATOR(pg_catalog.=) pc.relnamespace
        JOIN pg_catalog.pg_class cc ON cc.oid OPERATOR(pg_catalog.=) i.inhrelid
        JOIN pg_catalog.pg_namespace cn ON cn.oid OPERATOR(pg_catalog.=) cc.relnamespace
        WHERE pc.relkind OPERATOR(pg_catalog.=) ANY (ARRAY['r', 'p']::pg_catalog."char"[])
        """)
      branches.append(
        """
        SELECT 'owns'::pg_catalog.text, tn.nspname::pg_catalog.text,
          tc.relname::pg_catalog.text, sn.nspname::pg_catalog.text, sc.relname::pg_catalog.text
        FROM pg_catalog.pg_depend d
        JOIN pg_catalog.pg_class sc ON sc.oid OPERATOR(pg_catalog.=) d.objid
          AND sc.relkind OPERATOR(pg_catalog.=) 'S'
        JOIN pg_catalog.pg_namespace sn ON sn.oid OPERATOR(pg_catalog.=) sc.relnamespace
        JOIN pg_catalog.pg_class tc ON tc.oid OPERATOR(pg_catalog.=) d.refobjid
        JOIN pg_catalog.pg_namespace tn ON tn.oid OPERATOR(pg_catalog.=) tc.relnamespace
        WHERE d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
          AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
          AND d.deptype OPERATOR(pg_catalog.=) 'a'
        """)
    }
    if !drops.types.isEmpty {
      branches.append(
        """
        SELECT 'type'::pg_catalog.text, n.nspname::pg_catalog.text, t.typname::pg_catalog.text,
          t.typtype::pg_catalog.text, '-'::pg_catalog.text
        FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) t.typnamespace
        WHERE t.typtype OPERATOR(pg_catalog.<>) 'e'
          AND pg_catalog.left(n.nspname::pg_catalog.text, 3) OPERATOR(pg_catalog.<>) 'pg_'
          AND n.nspname OPERATOR(pg_catalog.<>) 'information_schema'
          AND (t.typrelid OPERATOR(pg_catalog.=) 0
            OR EXISTS (SELECT 1 FROM pg_catalog.pg_class c
              WHERE c.oid OPERATOR(pg_catalog.=) t.typrelid
                AND c.relkind OPERATOR(pg_catalog.=) 'c'))
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type e
            WHERE e.typarray OPERATOR(pg_catalog.=) t.oid)
        """)
    }
    return branches.joined(separator: "\nUNION ALL\n")
  }

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
  /// connection refuses it (`SQLRestoreError.connectionChanged`). A plan that drops reads the
  /// target's catalog the same way first: PostgreSQL its partitions, owned sequences and types
  /// (`SQLRestorePlan.checkPostgresDropTargets`), DuckDB its databases and current schema
  /// (`checkDuckDBDropTargets`), SQLite the tables and views of every schema
  /// (`checkSQLiteDropTargets`), then, when it drops tables, its foreign keys: refused when a
  /// table it does not drop has an ON DELETE action on one it drops
  /// (`SQLRestoreError.dropFiresForeignKeyAction` / `.foreignKeysUnreadable`). Only those reads
  /// may come before a refusal: in the same actor turn as the first change, a read-only policy
  /// refuses any restore and every statement must pass `evaluate` against `effectivePolicy(for:)`
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
      try await runRestoreCheck(since: generation, epoch: epoch) {
        try await self.requireStandardConformingStrings(statement: index)
      }
    }
    if let drops = plan.postgresDrops {
      try await runRestoreCheck(since: generation, epoch: epoch) {
        let rows = try await self.restoreCheckRows(Self.postgresDropTargetsQuery(drops))
        try SQLRestorePlan.checkPostgresDropTargets(rows, drops)
      }
    }
    if !plan.droppedDuckDBSchemas.isEmpty {
      try await runRestoreCheck(since: generation, epoch: epoch) {
        let rows = try await self.restoreCheckRows(Self.duckdbDropTargetsQuery)
        try SQLRestorePlan.checkDuckDBDropTargets(rows, droppedSchemas: plan.droppedDuckDBSchemas)
      }
    }
    if !plan.droppedSQLiteNames.isEmpty {
      try await runRestoreCheck(since: generation, epoch: epoch) {
        try SQLRestorePlan.checkSQLiteDropTargets(
          try await self.sqliteObjects(), dropped: plan.droppedSQLiteNames)
      }
    }
    if !plan.droppedSQLiteTables.isEmpty {
      try await runRestoreCheck(since: generation, epoch: epoch) {
        try await self.refuseSQLiteDropActions(dropping: plan.droppedSQLiteTables)
      }
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
      columnTypeCache.removeAll()
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

  /// One read-only check before the batch: whether it passes or throws, a Cancel or another
  /// connection meanwhile stops the restore (`refuseIfRestoreInterrupted`)
  private func runRestoreCheck(
    since generation: UInt64, epoch: UInt64, _ check: () async throws -> Void
  ) async throws {
    do {
      try await check()
    } catch {
      try refuseIfRestoreInterrupted(since: generation, epoch: epoch)
      throw error
    }
    try refuseIfRestoreInterrupted(since: generation, epoch: epoch)
  }

  /// The rows of an app-owned read before the batch
  /// - Throws: `DatabaseError` from the session; any other failure as `unreadable`'s error
  ///   (by default `SQLRestoreError.dropTargetsUnreadable`)
  private func restoreCheckRows(
    _ sql: String,
    unreadable: (String) -> SQLRestoreError = { .dropTargetsUnreadable($0) }
  ) async throws -> [[CellValue]] {
    do {
      return try await withSession { session in
        var rows: [[CellValue]] = []
        for try await row in try await session.query(sql, binds: []).rows {
          rows.append(row)
        }
        return rows
      }
    } catch let error as DatabaseError {
      throw error
    } catch {
      throw unreadable(error.localizedDescription)
    }
  }

  /// SQLite: the tables and views of every schema of the connection (main, temp and each
  /// attached database), read from each schema's own `sqlite_master`
  private func sqliteObjects() async throws -> [(schema: String, name: String)] {
    var schemas: [String] = []
    for row in try await restoreCheckRows(Self.sqliteDatabasesQuery) {
      guard row.count == 1, case .string(let name) = row[0] else {
        throw SQLRestoreError.dropTargetsUnreadable("unexpected answer")
      }
      schemas.append(name)
    }
    // temp is listed only once something opened it; its sqlite_master is there either way
    if !schemas.contains(where: { SQLTokenizer.asciiLowercased($0) == "temp" }) {
      schemas.append("temp")
    }
    var objects: [(schema: String, name: String)] = []
    for schema in schemas {
      let quoted = try SQLDialect.sqlite.quoteIdentifier(schema)
      let sql = "SELECT name FROM \(quoted).sqlite_master WHERE type IN ('table', 'view')"
      for row in try await restoreCheckRows(sql) {
        guard row.count == 1, case .string(let name) = row[0] else {
          throw SQLRestoreError.dropTargetsUnreadable("unexpected answer")
        }
        objects.append((schema, name))
      }
    }
    return objects
  }

  /// PostgreSQL: the session must report `standard_conforming_strings` `on`, as the plan read
  /// statement `index` and the ones after it (never guessed: off or unreadable refuses)
  /// - Throws: `SQLRestoreError.standardStringsOff` / `.standardStringsUnreadable`;
  ///   `DatabaseError` from the session.
  private func requireStandardConformingStrings(statement index: Int) async throws {
    let rows = try await restoreCheckRows(Self.standardStringsQuery) {
      .standardStringsUnreadable($0)
    }
    guard rows.count == 1, rows[0].count == 1, case .string(let value) = rows[0][0] else {
      throw SQLRestoreError.standardStringsUnreadable("unexpected answer")
    }
    guard value == "on" else {
      throw SQLRestoreError.standardStringsOff(index: index, value: value)
    }
  }

  /// SQLite: SQLite's DROP TABLE first deletes every row, which runs the ON DELETE action of
  /// each foreign key to the table, even with `defer_foreign_keys` on. Refused when a table the
  /// plan does not drop has a foreign key to one it drops with any action but NO ACTION and
  /// RESTRICT (CASCADE, SET NULL, SET DEFAULT), which only fail the restore. Names compare as
  /// SQLite compares them (ASCII case-insensitive, `dropped` as `SQLRestorePlan.objectKey` folds).
  /// - Throws: `SQLRestoreError.dropFiresForeignKeyAction` / `.foreignKeysUnreadable`;
  ///   `DatabaseError` from the session.
  private func refuseSQLiteDropActions(dropping dropped: Set<[UInt8]>) async throws {
    let rows = try await restoreCheckRows(Self.sqliteForeignKeysQuery) {
      .foreignKeysUnreadable($0)
    }
    func key(_ name: String) -> [UInt8] { Array(SQLTokenizer.asciiLowercased(name).utf8) }
    for row in rows {
      guard row.count == 3, case .string(let table) = row[0], case .string(let parent) = row[1],
        case .string(let action) = row[2]
      else { throw SQLRestoreError.foreignKeysUnreadable("unexpected answer") }
      guard !dropped.contains(key(table)), dropped.contains(key(parent)) else { continue }
      let upper = SQLTokenizer.asciiUppercased(action)
      guard upper == "NO ACTION" || upper == "RESTRICT" else {
        throw SQLRestoreError.dropFiresForeignKeyAction(
          table: table, dropped: parent, action: action)
      }
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
