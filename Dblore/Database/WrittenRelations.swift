// WrittenRelations.swift
// The tables a statement that ran writes, so the data viewer tabs showing them can be marked
// stale. Pure: the text is lexed with the connection's `SQLTokenizer` and only the statement's
// own level (depth 0) is read, so a CTE body, a column list or a subquery never names a target.
//
// Recognized: INSERT [OR ...] [INTO], REPLACE [INTO], UPDATE, DELETE FROM, MERGE INTO, TRUNCATE
// [TABLE] (several tables), ALTER TABLE, DROP TABLE [IF EXISTS] (several tables), each also
// after WITH (the main statement's target) and under EXPLAIN ANALYZE (which runs it). Anything
// else writes no relation it can name: CALL, DO, SELECT (a function it calls included), MySQL
// multi-table UPDATE / DELETE. An unqualified name is in the connection's default schema
// (PostgreSQL `public`: the session's search_path is not tracked; MySQL the connected database;
// SQLite and DuckDB `main`). A statement is read from its head (`headLength`), and whole only
// when its target lies past it; a run's statements are read off the main actor (`steps`,
// `statementsMaybeRun`).

import Foundation

nonisolated enum WrittenRelations {
  /// One written table: unquoted PostgreSQL names folded to lower case, quoted names as written
  struct Relation: Hashable, Sendable {
    let schema: String
    let name: String

    /// Whether this is the relation `schema`.`name` (a data viewer's, as the catalog spells it).
    /// PostgreSQL compares scalar for scalar. The other engines compare without case: SQLite and
    /// DuckDB names ignore it, and MySQL's depends on the server (`lower_case_table_names`), so
    /// a mark is never missed there.
    func matches(schema: String, name: String, dialect: SQLDialect) -> Bool {
      guard dialect == .postgresql else {
        return self.schema.lowercased() == schema.lowercased()
          && self.name.lowercased() == name.lowercased()
      }
      return self.schema.unicodeScalars.elementsEqual(schema.unicodeScalars)
        && self.name.unicodeScalars.elementsEqual(name.unicodeScalars)
    }
  }

  /// What became of what a run wrote before a statement
  enum Fate: Sendable, Equatable {
    case committed
    case rolledBack
    /// Still inside an open transaction
    case pending
  }

  /// The relations a run of statements wrote, by what became of them
  struct Outcome: Sendable, Equatable {
    var committed: Set<Relation> = []
    var pending: Set<Relation> = []
    /// What became of the relations written inside the transaction that was open before the run
    var earlier: Fate
  }

  /// How one statement ends the user's transaction
  enum Boundary: Sendable, Equatable {
    /// BEGIN / START: what ran before is committed (autocommitted, or committed by MySQL's
    /// BEGIN) and a transaction is open after it
    case begin
    /// COMMIT / END, a MySQL implicit commit and PREPARE TRANSACTION
    case commit
    /// ROLLBACK / ABORT (not ROLLBACK TO)
    case rollback
  }

  /// One statement of a run that writes a relation or is a transaction boundary
  struct Step: Sendable, Equatable {
    var relations: [Relation] = []
    var boundary: Boundary?
  }

  /// The statements' writes and boundaries, in run order, read off the main actor; the other
  /// statements are left out. Empty when there are none: the caller skips reading the
  /// transaction state.
  @concurrent static func steps(
    of statements: [String], dialect: SQLDialect, defaultSchema: String
  ) async -> [Step] {
    guard dialect != .mongodb else { return [] }
    return statements.compactMap { statement in
      let step = Step(
        relations: relations(writtenBy: statement, dialect: dialect, defaultSchema: defaultSchema),
        boundary: boundary(of: statement, dialect: dialect))
      return step.relations.isEmpty && step.boundary == nil ? nil : step
    }
  }

  /// Sorts the relations the `steps` (in run order, all of which ran) wrote by what became of
  /// them. A boundary decides for what ran since the previous one: a ROLLBACK drops it only
  /// when a transaction is known to be open there (after a BEGIN in the run, or from the run's
  /// start when one was open before it, `transactionOpenBefore`); with none it undid nothing,
  /// so what ran was autocommitted. After the last boundary, the writes are pending when a
  /// transaction is still open (`transactionOpenAfter`; Protected mode opens its own without a
  /// BEGIN), else committed. When a boundary is not certain (BEGIN inside an open PostgreSQL
  /// transaction is only a warning; COMMIT / ROLLBACK AND CHAIN open the next transaction) the
  /// writes count as committed: a mark too many shows a banner whose Reload changes nothing, a
  /// mark missed hides a change.
  static func outcome(
    of steps: [Step], transactionOpenBefore: Bool, transactionOpenAfter: Bool
  ) -> Outcome {
    var committed: Set<Relation> = []
    // Written since the previous boundary, and whether a transaction is known to be open there
    var written: Set<Relation> = []
    var inTransaction = transactionOpenBefore
    var earlier: Fate?
    for step in steps {
      if let boundary = step.boundary {
        let rolledBack = boundary == .rollback && inTransaction
        if !rolledBack { committed.formUnion(written) }
        written = []
        // The first boundary ends the transaction open before the run
        if earlier == nil { earlier = boundary == .rollback ? .rolledBack : .committed }
        inTransaction = boundary == .begin
        // A MySQL implicit commit (ALTER, DROP, TRUNCATE) commits before its statement runs,
        // and the statement commits itself: never pending, even in a transaction open after it
        if boundary == .commit {
          committed.formUnion(step.relations)
          continue
        }
      }
      written.formUnion(step.relations)
    }
    var outcome = Outcome(
      committed: committed, earlier: earlier ?? (transactionOpenAfter ? .pending : .committed))
    if transactionOpenAfter {
      outcome.pending = written
    } else {
      outcome.committed.formUnion(written)
    }
    return outcome
  }

  /// The statements of a script that threw which may have written, read off the main actor.
  /// None when the error says nothing was sent, or when the script is one statement (a failed
  /// statement writes nothing). Otherwise which statement failed is not known: every statement
  /// but a ROLLBACK counts (one that may not have run must not drop earlier writes; a BEGIN or
  /// COMMIT kept proves the writes before it committed, and one that did not run only costs an
  /// extra banner).
  @concurrent static func statementsMaybeRun(
    failedScript sql: String, error: any Error, dialect: SQLDialect
  ) async -> [String] {
    if let error = error as? DatabaseError {
      switch error {
      case .blockedByProtection, .missingParameters, .mixedPlaceholders, .emptyQuery,
        .notConnected, .transactionPendingInAnotherTab, .transactionEnding, .connectionLocked:
        return []
      default: break
      }
    }
    let statements = SQLTokenizer(dialect: dialect).splitStatements(sql)
    guard statements.count > 1 else { return [] }
    return statements.filter { boundary(of: $0, dialect: dialect) != .rollback }
  }

  // MARK: - One statement

  /// How much of a statement is lexed first (in scalars): its verb and target are near the
  /// start, so a multi-MB INSERT ... VALUES body is never lexed whole
  static let headLength = 4_096

  /// The first `headLength` scalars of `statement`; `truncated` when it is longer
  private static func head(of statement: String) -> (text: String, truncated: Bool) {
    let scalars = statement.unicodeScalars
    guard
      let end = scalars.index(
        scalars.startIndex, offsetBy: headLength, limitedBy: scalars.endIndex),
      end != scalars.endIndex
    else { return (statement, false) }
    return (String(scalars[..<end]), true)
  }

  /// The tables `statement` writes, in the order it names them; none for anything else. Read
  /// from the statement's head; when the head ends before the target (a WITH whose CTEs are
  /// longer, a long leading comment or name list), from the whole statement, so a target is
  /// never missed for its position.
  static func relations(
    writtenBy statement: String, dialect: SQLDialect, defaultSchema: String
  ) -> [Relation] {
    guard dialect != .mongodb else { return [] }
    let head = head(of: statement)
    return read(
      head.text, truncated: head.truncated, dialect: dialect, defaultSchema: defaultSchema)
      ?? read(statement, truncated: false, dialect: dialect, defaultSchema: defaultSchema) ?? []
  }

  /// The target read from `text`; nil when `text` is a cut head (`truncated`) that ends before
  /// the target could be read
  private static func read(
    _ text: String, truncated: Bool, dialect: SQLDialect, defaultSchema: String
  ) -> [Relation]? {
    var tokens = SQLTokenizer(dialect: dialect).tokens(text)
    // The cut may split the last token
    if truncated, !tokens.isEmpty { tokens.removeLast() }
    var reader = Reader(
      tokens: tokens.filter { $0.depth == 0 }, dialect: dialect, defaultSchema: defaultSchema,
      truncated: truncated)
    let ranOut: [Relation]? = truncated ? nil : []
    if reader.peek?.keyword == "EXPLAIN" {
      // Plain EXPLAIN runs nothing; EXPLAIN ANALYZE runs the statement
      guard
        case .explain(_, analyze: true) = SQLStatementClassifier.classifyStatement(
          text, dialect: dialect)?.kind
      else { return [] }
      guard reader.skip(toFirstOf: ["WITH"] + writeKeywords) else { return ranOut }
    }
    if reader.peek?.keyword == "WITH" {
      // The CTE bodies are deeper: the main statement is the first statement keyword here
      guard reader.skip(toFirstOf: writeKeywords + ["SELECT", "VALUES", "TABLE"]) else {
        return ranOut
      }
    }
    let relations = reader.target()
    return relations.isEmpty && reader.peek == nil ? ranOut : relations
  }

  private static let writeKeywords = [
    "INSERT", "REPLACE", "UPDATE", "DELETE", "MERGE", "TRUNCATE", "ALTER", "DROP",
  ]

  /// Read from the statement's head: transaction control is short, so a cut statement only
  /// commits (a MySQL implicit commit), never begins or rolls back
  private static func boundary(of statement: String, dialect: SQLDialect) -> Boundary? {
    guard dialect != .mongodb else { return nil }
    let head = head(of: statement)
    let first = SQLTokenizer(dialect: dialect).tokens(head.text).first?.keyword ?? ""
    // Only MySQL commits implicitly: elsewhere a boundary is transaction control
    guard dialect == .mysql || transactionControlWords.contains(first),
      let classified = SQLStatementClassifier.classifyStatement(head.text, dialect: dialect)
    else { return nil }
    if ProtectedTransactionRules.rolledBackUserTransaction(classified, dialect: dialect) {
      return head.truncated ? nil : .rollback
    }
    if ProtectedTransactionRules.committedUserTransaction(classified, dialect: dialect) {
      return .commit
    }
    guard classified.kind == .tcl else { return nil }
    switch first {
    case "BEGIN", "START": return head.truncated ? .commit : .begin
    case "PREPARE": return .commit
    default: return nil
    }
  }

  private static let transactionControlWords: Set<String> = [
    "BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "PREPARE",
  ]

  /// Reads the statement's own-level tokens from its first keyword
  private struct Reader {
    let tokens: [SQLToken]
    let dialect: SQLDialect
    let defaultSchema: String
    /// The tokens are a cut head's: a name they end on may go on past it
    let truncated: Bool
    var index = 0

    init(tokens: [SQLToken], dialect: SQLDialect, defaultSchema: String, truncated: Bool) {
      self.tokens = tokens
      self.dialect = dialect
      self.defaultSchema = defaultSchema
      self.truncated = truncated
    }

    var peek: SQLToken? { tokens.indices.contains(index) ? tokens[index] : nil }

    /// Moves to the first word in `words`; false when there is none
    mutating func skip(toFirstOf words: [String]) -> Bool {
      index += 1
      while let token = peek {
        if let word = token.keyword, words.contains(word) { return true }
        index += 1
      }
      return false
    }

    /// Consumes the words in `words`, in any order
    mutating func skipWords(_ words: Set<String>) {
      while let word = peek?.keyword, words.contains(word) { index += 1 }
    }

    /// Consumes `word` if it is next
    mutating func accept(_ word: String) -> Bool {
      guard peek?.keyword == word else { return false }
      index += 1
      return true
    }

    mutating func target() -> [Relation] {
      guard let keyword = peek?.keyword else { return [] }
      index += 1
      switch keyword {
      case "INSERT":
        // SQLite / DuckDB INSERT OR REPLACE, MySQL modifiers; INTO is optional on MySQL
        if accept("OR") { index += 1 }
        skipWords(["LOW_PRIORITY", "DELAYED", "HIGH_PRIORITY", "IGNORE"])
        _ = accept("INTO")
        return name().map { [$0] } ?? []
      case "REPLACE":
        skipWords(["LOW_PRIORITY", "DELAYED"])
        _ = accept("INTO")
        return name().map { [$0] } ?? []
      case "UPDATE":
        if accept("OR") { index += 1 }
        skipWords(["LOW_PRIORITY", "IGNORE", "ONLY"])
        guard let relation = name(), !joinsBeforeSet() else { return [] }
        return [relation]
      case "DELETE":
        // MySQL `DELETE t1, t2 FROM ...` names its targets before FROM
        skipWords(["LOW_PRIORITY", "QUICK", "IGNORE"])
        guard accept("FROM") else { return [] }
        skipWords(["ONLY"])
        // MySQL `DELETE FROM t1, t2 USING ...` deletes from several tables (PostgreSQL's USING
        // only lists the tables the WHERE reads)
        guard let relation = name(), peek?.isSymbol(",") != true else { return [] }
        if dialect == .mysql, tokens[index...].contains(where: { $0.isWord("USING") }) {
          return []
        }
        return [relation]
      case "MERGE":
        guard accept("INTO") else { return [] }
        skipWords(["ONLY"])
        return name().map { [$0] } ?? []
      case "TRUNCATE":
        _ = accept("TABLE")
        return names()
      case "ALTER":
        skipWords(["ONLINE", "IGNORE"])
        guard accept("TABLE") else { return [] }
        if accept("IF") { _ = accept("EXISTS") }
        skipWords(["ONLY"])
        return name().map { [$0] } ?? []
      case "DROP":
        skipWords(["TEMPORARY"])
        guard accept("TABLE") else { return [] }
        if accept("IF") { _ = accept("EXISTS") }
        return names()
      default:
        return []
      }
    }

    /// A comma or a JOIN before SET: a MySQL multi-table UPDATE
    private func joinsBeforeSet() -> Bool {
      for token in tokens[index...] {
        if token.isWord("SET") { return false }
        if token.isSymbol(",") || token.isWord("JOIN") || token.isWord("STRAIGHT_JOIN") {
          return true
        }
      }
      return false
    }

    /// Comma-separated names (TRUNCATE, DROP TABLE), each maybe followed by `*` (PostgreSQL
    /// descendant tables) and ONLY before the next; none when one cannot be read
    mutating func names() -> [Relation] {
      var relations: [Relation] = []
      repeat {
        skipWords(["ONLY"])
        guard let relation = name() else { return [] }
        relations.append(relation)
        if peek?.isSymbol("*") == true { index += 1 }
      } while consumeComma()
      return relations
    }

    private mutating func consumeComma() -> Bool {
      guard peek?.isSymbol(",") == true else { return false }
      index += 1
      return true
    }

    /// `[catalog.][schema.]name`: the last two parts, the default schema when there is one
    mutating func name() -> Relation? {
      var parts: [String] = []
      while let token = peek, let part = namePart(token) {
        parts.append(part)
        index += 1
        guard peek?.isSymbol(".") == true else { break }
        index += 1
      }
      guard let name = parts.last, !(truncated && peek == nil) else { return nil }
      return Relation(schema: parts.count > 1 ? parts[parts.count - 2] : defaultSchema, name: name)
    }

    /// An identifier as the server reads it: unquoted words folded to lower case (PostgreSQL's
    /// rule; the other engines compare without case), quoted ones as written. A string is a
    /// name on MySQL (ANSI_QUOTES) and SQLite (which accepts one where a name is expected).
    private func namePart(_ token: SQLToken) -> String? {
      switch token.kind {
      case .word:
        guard let first = token.text.unicodeScalars.first, !("0"..."9").contains(first) else {
          return nil
        }
        return SQLTokenizer.asciiLowercased(token.text)
      case .quotedIdentifier:
        return token.text
      case .string where dialect == .mysql || dialect == .sqlite:
        return token.text
      default:
        return nil
      }
    }
  }
}
