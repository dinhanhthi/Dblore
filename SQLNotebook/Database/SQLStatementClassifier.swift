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
  static func classify(_ sql: String) -> [ClassifiedStatement] {
    SQLTokenizer.splitStatements(sql).compactMap(classifyStatement)
  }

  /// Classify one already-split statement; nil if it is empty / comment-only.
  /// Fails closed (`.unknown`) when the text may be lexed differently by the server:
  /// a `;` token (the splitter and the tokenizer disagree on a statement boundary) or a
  /// plain string containing a backslash (escape under `standard_conforming_strings = off`).
  static func classifyStatement(_ text: String) -> ClassifiedStatement? {
    let tokens = SQLTokenizer.tokens(text)
    guard !tokens.isEmpty else { return nil }
    let analysis = analyze(tokens[...])
    let ambiguous = tokens.contains { $0.isSymbol(";") || $0.kind == .backslashString }
    return ClassifiedStatement(
      text: text, kind: ambiguous ? .unknown : analysis.kind, hasReturning: analysis.hasReturning,
      affectsAllRows: analysis.affectsAllRows, nonTransactional: analysis.nonTransactional,
      resetsSessionBrakes: analysis.resetsSessionBrakes,
      changesPrivileges: analysis.changesPrivileges)
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

  private static func effectiveKind(_ kind: StatementKind) -> StatementKind {
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
    var affectsAllRows = false
    var nonTransactional = false
    var resetsSessionBrakes = false
    var changesPrivileges = false
  }

  private static func analyze(_ tokens: ArraySlice<SQLToken>) -> Analysis {
    let body = tokens.drop { $0.isSymbol("(") }
    guard let first = body.first, first.kind == .word else { return Analysis(kind: .unknown) }
    let base = first.depth
    let topWords = body.filter { $0.kind == .word && $0.depth == base }.map { $0.keyword ?? "" }

    if first.isWord("EXPLAIN") {
      return explain(body)
    }
    let kind = kind(of: body, keyword: first.keyword ?? "", topWords: topWords)
    let discardsAll = topWords.starts(with: ["DISCARD", "ALL"])
    return Analysis(
      kind: kind,
      hasReturning: body.contains { $0.isWord("RETURNING") },
      affectsAllRows: affectsAllRows(body),
      nonTransactional: nonTransactional(topWords),
      resetsSessionBrakes: kind == .sessionSet(touchesBrake: true) || discardsAll
        || beginsReadWrite(topWords),
      changesPrivileges: discardsAll || changesPrivileges(body))
  }

  private static func kind(
    of body: ArraySlice<SQLToken>, keyword: String, topWords: [String]
  ) -> StatementKind {
    switch keyword {
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
  private static func explain(_ body: ArraySlice<SQLToken>) -> Analysis {
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
    let inner = analyze(rest)
    guard isAnalyze else { return Analysis(kind: .explain(inner: inner.kind, analyze: false)) }
    return Analysis(
      kind: .explain(inner: inner.kind, analyze: true), hasReturning: inner.hasReturning,
      affectsAllRows: inner.affectsAllRows, nonTransactional: inner.nonTransactional,
      resetsSessionBrakes: inner.resetsSessionBrakes, changesPrivileges: inner.changesPrivileges)
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
