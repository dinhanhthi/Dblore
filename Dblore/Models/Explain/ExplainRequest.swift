// ExplainRequest.swift
// One user statement wrapped as EXPLAIN, or as BEGIN / EXPLAIN ANALYZE / ROLLBACK.

import Foundation

/// Why an explain request was refused before any SQL was sent.
nonisolated enum ExplainRequestError: Error, Equatable, Sendable {
  /// The input splits into more than one statement.
  case multipleStatements
  /// The statement already begins with EXPLAIN.
  case alreadyExplain
  /// The connected server has no EXPLAIN ANALYZE (`analyzeUnavailableReason`).
  case analyzeUnavailable(String)

  var message: String {
    switch self {
    case .multipleStatements: "Explain one statement at a time"
    case .alreadyExplain: "This statement is already an EXPLAIN"
    case .analyzeUnavailable(let reason): reason
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
  /// MySQL: `EXPLAIN FORMAT=JSON` (shown in the plan view) instead of the tabular `EXPLAIN`.
  /// Unless the caller says, on for a MySQL server and off for MariaDB or an unknown server.
  let jsonFormat: Bool
  /// When true, ANALYZE of INSERT/UPDATE/DELETE/MERGE rolls back unless a transaction is open.
  let rollbackAfterAnalyze: Bool
  /// Connection dialect: splits and classifies `statement`, and is the `wrappedSQL` prefix.
  let dialect: SQLDialect
  private let changesData: Bool

  init(
    statement: String, analyze: Bool, buffers: Bool, rollbackAfterAnalyze: Bool = true,
    jsonFormat: Bool? = nil, dialect: SQLDialect = .postgresql,
    mysqlServer: MySQLServerInfo? = nil
  ) throws {
    if analyze,
      let reason = Self.analyzeUnavailableReason(dialect: dialect, mysqlServer: mysqlServer)
    {
      throw ExplainRequestError.analyzeUnavailable(reason)
    }
    let body = try Self.singleStatement(statement, dialect: dialect)
    self.statement = body
    self.analyze = analyze
    self.buffers = buffers
    self.jsonFormat = jsonFormat ?? (dialect == .mysql && mysqlServer?.flavor == .mysql)
    self.rollbackAfterAnalyze = rollbackAfterAnalyze
    self.dialect = dialect
    self.changesData = Self.statementChangesData(body, dialect: dialect)
  }

  /// `dialect.explainPrefix` plus the statement. Format is JSON on PostgreSQL (plan view);
  /// SQLite and DuckDB ignore it (grid / text plan). MySQL is the tabular plan unless
  /// `jsonFormat`; its ANALYZE is a text tree.
  var sql: String {
    let format = dialect == .mysql && !jsonFormat ? nil : "json"
    return dialect.explainPrefix(analyze: analyze, buffers: buffers, format: format) + " "
      + statement
  }

  /// Why Explain Analyze cannot run on this connection, nil when it can. MySQL needs 8.0.18 or
  /// later; MariaDB (which has `ANALYZE <statement>` instead) and an unknown server are refused.
  /// Other engines follow `DatabaseCapabilities.supportsExplainAnalyze`.
  static func analyzeUnavailableReason(
    dialect: SQLDialect, mysqlServer: MySQLServerInfo?
  ) -> String? {
    guard dialect == .mysql else { return nil }
    guard let server = mysqlServer else {
      return "Explain Analyze needs the MySQL server version. Reconnect and try again"
    }
    if server.supportsExplainAnalyze { return nil }
    if server.flavor == .mariadb {
      return "Explain Analyze is not available on MariaDB"
    }
    let version = "\(server.major).\(server.minor).\(server.patch)"
    return "Explain Analyze needs MySQL 8.0.18 or later (server is \(version))"
  }

  /// Explain text with the rollback wrapper when this request would use it, in `dialect`.
  var wrappedSQL: String {
    sqlToRun(protectedTransactionOpen: false)
  }

  /// SQL to send. A protected transaction already open skips `BEGIN` / `ROLLBACK`
  /// so the app's transaction is left in place.
  func sqlToRun(protectedTransactionOpen: Bool) -> String {
    let explained = sql
    guard analyze, rollbackAfterAnalyze, changesData, !protectedTransactionOpen else {
      return explained
    }
    return "BEGIN; \(explained); ROLLBACK;"
  }

  /// One statement, without a trailing `;`. Leading comments stay in the text; the first
  /// word is what `SQLTokenizer` sees after whitespace and comments.
  private static func singleStatement(_ raw: String, dialect: SQLDialect) throws -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasSuffix(";") {
      text.removeLast()
      text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let tokenizer = SQLTokenizer(dialect: dialect)
    let parts = tokenizer.splitStatements(text)
    guard parts.count == 1, let only = parts.first else {
      throw ExplainRequestError.multipleStatements
    }
    if tokenizer.tokens(only).first?.isWord("EXPLAIN") == true {
      throw ExplainRequestError.alreadyExplain
    }
    return only
  }

  /// INSERT, UPDATE, DELETE, MERGE, or a data-modifying WITH. SELECT (including SELECT INTO)
  /// is not wrapped.
  private static func statementChangesData(_ sql: String, dialect: SQLDialect) -> Bool {
    guard let classified = SQLStatementClassifier.classify(sql, dialect: dialect).first else {
      return false
    }
    guard SQLStatementClassifier.effectiveKind(classified.kind) == .dml else { return false }
    let tokens = SQLTokenizer(dialect: dialect).tokens(sql)
    guard let keyword = tokens.lazy.compactMap(\.keyword).first else {
      return false
    }
    return keyword != "SELECT" && keyword != "VALUES" && keyword != "TABLE"
  }
}
