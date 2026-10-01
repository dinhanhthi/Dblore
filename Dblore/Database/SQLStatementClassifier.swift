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
/// DO/CALL bodies and triggers are not detected.
nonisolated enum SQLStatementClassifier {

  /// Split `sql` into statements and classify each. Empty / comment-only statements are dropped.
  /// `dialect` defaults to PostgreSQL, which keeps every existing caller on today's rules.
  static func classify(
    _ sql: String, dialect: SQLDialect = .postgresql
  ) -> [ClassifiedStatement] {
    let tokenizer = SQLTokenizer(dialect: dialect)
    return tokenizer.splitStatements(sql).compactMap { classifyStatement($0, dialect: dialect) }
  }

  /// Classify one already-split statement; nil if it is empty / comment-only.
  /// Fails closed (`.unknown`) when the text may be lexed differently by the server:
  /// a `;` token (the splitter and the tokenizer disagree on a statement boundary) or a
  /// plain string containing a backslash (escape under `standard_conforming_strings = off`).
  static func classifyStatement(
    _ text: String, dialect: SQLDialect = .postgresql
  ) -> ClassifiedStatement? {
    let tokens = SQLTokenizer(dialect: dialect).tokens(text)
    guard !tokens.isEmpty else { return nil }
    let analysis = analyze(tokens[...], dialect: dialect)
    let ambiguous = tokens.contains { $0.isSymbol(";") || $0.kind == .backslashString }
    return ClassifiedStatement(
      text: text, kind: ambiguous ? .unknown : analysis.kind, hasReturning: analysis.hasReturning,
      hasTopLevelReturning: analysis.hasTopLevelReturning,
      affectsAllRows: analysis.affectsAllRows, nonTransactional: analysis.nonTransactional,
      resetsSessionBrakes: analysis.resetsSessionBrakes,
      changesPrivileges: analysis.changesPrivileges, createsTable: analysis.createsTable)
  }

  /// True when `sql` is a CREATE/ALTER ROLE or CREATE/ALTER USER (not `USER MAPPING`) whose
  /// text contains the word PASSWORD, including `WITH ENCRYPTED PASSWORD`. ASCII
  /// case-insensitive, and PASSWORD does not have to be the first clause.
  /// A SELECT is never a match, even when a column or a comment contains PASSWORD.
  nonisolated static func containsPasswordLiteral(_ sql: String) -> Bool {
    guard isRoleOrUserAdmin(sql) else { return false }
    return sql.range(of: #"\bPASSWORD\b"#, options: [.regularExpression, .caseInsensitive]) != nil
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
  }

  private static func analyze(
    _ tokens: ArraySlice<SQLToken>, dialect: SQLDialect
  ) -> Analysis {
    let body = tokens.drop { $0.isSymbol("(") }
    guard let first = body.first, first.kind == .word else {
      return sqliteAdjusted(Analysis(kind: .unknown), body: body, dialect: dialect)
    }
    let base = first.depth
    let topWords = body.filter { $0.kind == .word && $0.depth == base }.map { $0.keyword ?? "" }

    if first.isWord("EXPLAIN") {
      return sqliteAdjusted(explain(body, dialect: dialect), body: body, dialect: dialect)
    }
    let kind = kind(
      of: body, keyword: first.keyword ?? "", topWords: topWords, dialect: dialect)
    let discardsAll = topWords.starts(with: ["DISCARD", "ALL"])
    return sqliteAdjusted(
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

  /// `PRAGMA name` and `PRAGMA schema.name` query the setting. Assignment (`=` or the
  /// parenthesized form) is schema-changing: `journal_mode`, `writable_schema`,
  /// `foreign_keys`, and every other assignment. A bare `PRAGMA` with no name is unrecognized.
  private static func pragmaKind(_ body: ArraySlice<SQLToken>) -> StatementKind {
    let depth = body.first?.depth ?? 0
    let top = body.filter { $0.depth == depth }
    if isBarePragmaQuery(top) { return .read }
    return top.count > 1 ? .ddl : .unknown
  }

  /// `PRAGMA name` or `PRAGMA schema.name`, with nothing assigned.
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

  /// Commands whose effect cannot be checked from the text: another database file, a backup
  /// file, or a native `load_extension(` call. A read, including plain EXPLAIN of one, becomes
  /// a utility so read-only and schema protection both block it.
  private static func sqliteAdjusted(
    _ analysis: Analysis, body: ArraySlice<SQLToken>, dialect: SQLDialect
  ) -> Analysis {
    guard dialect == .sqlite else { return analysis }
    var analysis = analysis
    if callsLoadExtension(body) || containsAttachOrDetach(body) || isVacuumInto(body) {
      analysis.kind = .utility
    }
    if isVacuumInto(body) { analysis.nonTransactional = true }
    return analysis
  }

  /// `load_extension(` at any depth, including a quoted, bracketed, or backticked name.
  /// A mention inside a string or comment is not a call: those are not word tokens.
  private static func callsLoadExtension(_ body: ArraySlice<SQLToken>) -> Bool {
    body.indices.contains { index in
      let next = body.index(after: index)
      guard next < body.endIndex, body[next].isSymbol("(") else { return false }
      return isLoadExtension(body[index])
    }
  }

  private static func isLoadExtension(_ token: SQLToken) -> Bool {
    if token.isWord(sqliteLoadExtensionFunction) { return true }
    guard token.kind == .quotedIdentifier, let text = token.asciiText else { return false }
    return SQLTokenizer.asciiUppercased(text) == sqliteLoadExtensionFunction
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
    let inner = analyze(rest, dialect: dialect)
    guard isAnalyze else { return Analysis(kind: .explain(inner: inner.kind, analyze: false)) }
    return Analysis(
      kind: .explain(inner: inner.kind, analyze: true), hasReturning: inner.hasReturning,
      hasTopLevelReturning: inner.hasTopLevelReturning,
      affectsAllRows: inner.affectsAllRows, nonTransactional: inner.nonTransactional,
      resetsSessionBrakes: inner.resetsSessionBrakes, changesPrivileges: inner.changesPrivileges,
      createsTable: inner.createsTable)
  }

  /// SQLite `EXPLAIN` and `EXPLAIN QUERY PLAN` return a grid. They do not run the statement,
  /// so Analyze stays off (`supportsExplainJSON` is false for this engine).
  private static func sqliteExplain(_ body: ArraySlice<SQLToken>) -> Analysis {
    var rest = body.dropFirst()
    if rest.first?.isWord("QUERY") == true, rest.dropFirst().first?.isWord("PLAN") == true {
      rest = rest.dropFirst(2)
    }
    let inner = analyze(rest, dialect: .sqlite)
    return Analysis(kind: .explain(inner: inner.kind, analyze: false))
  }

  /// Leading verb is CREATE/ALTER ROLE or CREATE/ALTER USER, and not USER MAPPING.
  private static func isRoleOrUserAdmin(_ sql: String) -> Bool {
    let words = SQLTokenizer.tokens(sql).compactMap(\.keyword)
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
