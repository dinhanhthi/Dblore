// MySQLTempTableTracker.swift
// MySQL / MariaDB temporary tables of the open session. No catalog lists them
// (information_schema shows none), so the names come from the session's own successful
// statements: `CREATE [OR REPLACE] TEMPORARY TABLE [IF NOT EXISTS] [db.]name` adds one,
// `DROP [TEMPORARY] TABLE [IF EXISTS] a, b` removes the ones it names (a temporary table hides
// a base table of the same name, so a plain DROP TABLE drops it first), and MySQL error 1146
// (ER_NO_SUCH_TABLE) naming one removes it. An unqualified name is in the session's default
// database: the connected one until a successful `USE db` changes it. A statement that may have
// changed it unseen (a `USE` whose target cannot be read, or one opening with an executable
// comment, as `/*!32312 USE db*/`) stops the tracking of unqualified names until reset; an
// unqualified DROP then removes that name in every database.
// `DatabaseConnectionManager` resets it whenever the session is forgotten (disconnect,
// reconnect, capped-read reset, loss).
//
// Case rule: names are kept as typed (backticks removed, doubled backticks collapsed) and
// compared scalar by scalar, as a server with `lower_case_table_names = 0` (the Linux default)
// does. On a case-insensitive server a DROP spelled in another case leaves a stale name; opening
// it answers 1146, which removes it. Folding case instead would hide a live table on a
// case-sensitive server (`t` and `T` are two tables there), which nothing would undo.

import Foundation

/// Temporary tables the current MySQL session created, read from statement text.
nonisolated struct MySQLTempTableTracker: Sendable {
  /// One temporary table: its database and name as typed, compared scalar by scalar.
  struct Name: Sendable, Equatable {
    let database: String
    let name: String

    static func == (lhs: Name, rhs: Name) -> Bool {
      lhs.database.unicodeScalars.elementsEqual(rhs.database.unicodeScalars)
        && lhs.name.unicodeScalars.elementsEqual(rhs.name.unicodeScalars)
    }

    /// Whether dropping this name drops `tracked`. An unqualified name while the default
    /// database is unknown (empty database) drops that name in any database: removing too much
    /// only hides a live temporary table, never labels a base table as one.
    func drops(_ tracked: Name) -> Bool {
      guard database.isEmpty else { return self == tracked }
      return name.unicodeScalars.elementsEqual(tracked.name.unicodeScalars)
    }
  }

  /// What one statement does to the session's temporary tables
  enum Change: Sendable, Equatable {
    case created(Name)
    case dropped([Name])
    /// The session's default database changed: to this one, or to one unknown (nil)
    case usedDatabase(String?)
  }

  /// Tracked tables, in creation order
  private(set) var names: [Name] = []
  /// The session's default database after a `USE` (nil: the connected one). Empty once it is
  /// unknown: unqualified names are then not tracked.
  private(set) var usedDatabase: String?

  /// The tracked tables as catalog rows: schema = database, `isTemporary`
  var tables: [DatabaseTable] {
    names.map { DatabaseTable(schema: $0.database, name: $0.name, isTemporary: true) }
  }

  /// Track or untrack after `sql` succeeded. An unqualified name is in the default database:
  /// `usedDatabase`, else `connected`; with none (empty) it is not tracked.
  mutating func noteSucceeded(_ sql: String, connected: String) {
    switch Self.change(in: sql, database: usedDatabase ?? connected) {
    case .created(let name):
      if !name.database.isEmpty, !names.contains(name) { names.append(name) }
    case .dropped(let dropped):
      names.removeAll { tracked in dropped.contains { $0.drops(tracked) } }
    case .usedDatabase(let database):
      usedDatabase = database ?? ""
    case nil:
      break
    }
  }

  /// The server answered 1146 (ER_NO_SUCH_TABLE): its message names the table as `'db.name'`
  /// (in any `lc_messages` language), which leaves the tracker. True when one was removed.
  @discardableResult
  mutating func forgetMissing(serverMessage: String) -> Bool {
    let count = names.count
    names.removeAll { serverMessage.contains("'\($0.database).\($0.name)'") }
    return names.count != count
  }

  /// A new session: no table, the connected database
  mutating func reset() {
    names.removeAll()
    usedDatabase = nil
  }

  // MARK: - Parsing

  /// The change `sql` (one statement) makes, or nil for any other statement. Only bare words
  /// and backtick-quoted identifiers are names; anything else (a string, an executable
  /// comment) fails to match. A `USE` must name exactly one database.
  static func change(in sql: String, database: String) -> Change? {
    var tokens = Tokens(sql)
    if tokens.opensWithExecutableComment { return .usedDatabase(nil) }
    if tokens.take("USE") {
      let used = tokens.identifier()
      return .usedDatabase(tokens.isAtEnd ? used : nil)
    }
    if tokens.take("CREATE") {
      if tokens.take("OR") && !tokens.take("REPLACE") { return nil }
      guard tokens.take("TEMPORARY"), tokens.take("TABLE") else { return nil }
      if tokens.take("IF") && !(tokens.take("NOT") && tokens.take("EXISTS")) { return nil }
      return tokens.qualifiedName(database: database).map { .created($0) }
    }
    guard tokens.take("DROP") else { return nil }
    _ = tokens.take("TEMPORARY")
    guard tokens.take("TABLE") || tokens.take("TABLES") else { return nil }
    if tokens.take("IF") && !tokens.take("EXISTS") { return nil }
    var dropped: [Name] = []
    repeat {
      guard let name = tokens.qualifiedName(database: database) else { return nil }
      dropped.append(name)
    } while tokens.takeSymbol(",")
    return .dropped(dropped)
  }

  /// MySQL lexemes of one statement read front to back, comments and whitespace skipped
  private struct Tokens {
    let scalars: [Unicode.Scalar]
    let tokenizer = SQLTokenizer(dialect: .mysql)
    var offset = 0

    init(_ sql: String) {
      scalars = Array(sql.unicodeScalars)
    }

    /// The next lexeme that is neither whitespace nor a comment, without consuming it
    private func peek() -> SQLLexeme? {
      var i = offset
      while i < scalars.count {
        let lexeme = tokenizer.lexeme(in: scalars, at: i)
        switch lexeme.kind {
        case .whitespace, .comment: i = lexeme.range.upperBound
        default: return lexeme
        }
      }
      return nil
    }

    var isAtEnd: Bool { peek() == nil }

    var opensWithExecutableComment: Bool {
      guard let lexeme = peek(), case .executableComment = lexeme.kind else { return false }
      return true
    }

    /// Consumes the next lexeme when it is the bare word `keyword` (ASCII, any case)
    mutating func take(_ keyword: String) -> Bool {
      guard let lexeme = peek(), case .word = lexeme.kind,
        SQLTokenizer.asciiUppercased(SQLTokenizer.text(scalars, lexeme.range)) == keyword
      else { return false }
      offset = lexeme.range.upperBound
      return true
    }

    mutating func takeSymbol(_ symbol: Unicode.Scalar) -> Bool {
      guard let lexeme = peek(), case .symbol = lexeme.kind,
        scalars[lexeme.range.lowerBound] == symbol
      else { return false }
      offset = lexeme.range.upperBound
      return true
    }

    /// Consumes a bare word (as typed) or a backtick-quoted identifier (its content)
    mutating func identifier() -> String? {
      guard let lexeme = peek() else { return nil }
      let text: String
      switch lexeme.kind {
      case .word: text = SQLTokenizer.text(scalars, lexeme.range)
      case .quoted(.quotedIdentifier, let content): text = content
      default: return nil
      }
      offset = lexeme.range.upperBound
      return text
    }

    /// `name` (in `database`) or `db.name`
    mutating func qualifiedName(database: String) -> Name? {
      guard let first = identifier() else { return nil }
      guard takeSymbol(".") else { return Name(database: database, name: first) }
      return identifier().map { Name(database: first, name: $0) }
    }
  }
}
