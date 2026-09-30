// ExplainRequest.swift
// One user statement wrapped as EXPLAIN, or as BEGIN / EXPLAIN ANALYZE / ROLLBACK.

import Foundation

/// Why an explain request was refused before any SQL was sent.
nonisolated enum ExplainRequestError: Error, Equatable, Sendable {
  /// The input splits into more than one statement.
  case multipleStatements
  /// The statement already begins with EXPLAIN.
  case alreadyExplain

  var message: String {
    switch self {
    case .multipleStatements: "Explain one statement at a time"
    case .alreadyExplain: "This statement is already an EXPLAIN"
    }
  }
}

/// The SQL for Explain or Explain Analyze of a single statement.
/// `EXPLAIN ANALYZE` runs the inner statement. Data-changing ANALYZE is wrapped in
/// `BEGIN` / `ROLLBACK` unless the caller already has a protected transaction open.
nonisolated struct ExplainRequest: Sendable {
  /// Statement text with one trailing `;` and surrounding whitespace removed.
  let statement: String
  let analyze: Bool
  let buffers: Bool
  /// When true, ANALYZE of INSERT/UPDATE/DELETE/MERGE rolls back unless a transaction is open.
  let rollbackAfterAnalyze: Bool
  private let changesData: Bool

  init(statement: String, analyze: Bool, buffers: Bool, rollbackAfterAnalyze: Bool = true) throws {
    let body = try Self.singleStatement(statement)
    self.statement = body
    self.analyze = analyze
    self.buffers = buffers
    self.rollbackAfterAnalyze = rollbackAfterAnalyze
    self.changesData = Self.statementChangesData(body)
  }

  /// `dialect.explainPrefix` plus the statement. Format is JSON.
  func sql(dialect: SQLDialect) -> String {
    dialect.explainPrefix(analyze: analyze, buffers: buffers, format: "json") + " " + statement
  }

  /// Explain text with the rollback wrapper when this request would use it.
  /// PostgreSQL is the default dialect. Pass `sqlToRun` when the connection differs.
  var wrappedSQL: String {
    sqlToRun(protectedTransactionOpen: false, dialect: .postgresql)
  }

  /// SQL to send. A protected transaction already open skips `BEGIN` / `ROLLBACK`
  /// so the app's transaction is left in place.
  func sqlToRun(protectedTransactionOpen: Bool, dialect: SQLDialect) -> String {
    let explained = sql(dialect: dialect)
    guard analyze, rollbackAfterAnalyze, changesData, !protectedTransactionOpen else {
      return explained
    }
    return "BEGIN; \(explained); ROLLBACK;"
  }

  /// One statement, without a trailing `;`. Leading comments stay in the text; the first
  /// word is what `SQLTokenizer` sees after whitespace and comments.
  private static func singleStatement(_ raw: String) throws -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasSuffix(";") {
      text.removeLast()
      text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let parts = SQLTokenizer.splitStatements(text)
    guard parts.count == 1, let only = parts.first else {
      throw ExplainRequestError.multipleStatements
    }
    if SQLTokenizer.tokens(only).first?.isWord("EXPLAIN") == true {
      throw ExplainRequestError.alreadyExplain
    }
    return only
  }

  /// INSERT, UPDATE, DELETE, MERGE, or a data-modifying WITH. SELECT (including SELECT INTO)
  /// is not wrapped.
  private static func statementChangesData(_ sql: String) -> Bool {
    guard let classified = SQLStatementClassifier.classify(sql).first else { return false }
    guard SQLStatementClassifier.effectiveKind(classified.kind) == .dml else { return false }
    guard let keyword = SQLTokenizer.tokens(sql).lazy.compactMap(\.keyword).first else {
      return false
    }
    return keyword != "SELECT" && keyword != "VALUES" && keyword != "TABLE"
  }
}
