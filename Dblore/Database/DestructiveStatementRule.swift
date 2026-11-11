// DestructiveStatementRule.swift
// Statements that remove data for good, read from their text: the rule the AI proposal Run
// asks a typed target name by, shared so MCP writes can ask the same.

import Foundation

/// Which statements need the user to type their target's name before they run. Read locally
/// from the classified text, never from anyone's description of it. Blind spot: a trivially
/// true WHERE (`WHERE true`, `WHERE 1=1`); no predicate is read.
nonisolated enum DestructiveStatementRule {
  enum Verdict: Sendable, Equatable {
    /// Not destructive
    case none
    /// Destructive; the target's name to type, as written (unquoted words keep their case,
    /// quoted identifiers lose their quotes, the parts of a qualified name joined with ".")
    case confirm(String)
    /// Destructive with no single target name that can be read: refused
    case unnamed
  }

  /// `statement` classified by `SQLStatementClassifier` for `dialect` (MongoDB by
  /// `MongoCommandClassifier`). `database` is the connection's, the target of MongoDB
  /// `db.dropDatabase()`. Destructive:
  /// - DROP and TRUNCATE; `DO`, `EXECUTE`, `CALL` and any MySQL executable comment (unnamed);
  /// - `CREATE OR REPLACE [TEMP | TEMPORARY]` TABLE, SCHEMA, DATABASE or SEQUENCE;
  /// - `ALTER [ONLINE] [IGNORE] TABLE name` with a top-level DROP other than the non-data ones (see
  ///   `dropsData`), or a top-level `TRUNCATE PARTITION`;
  /// - a MERGE with `THEN DELETE` (named only when it starts with `MERGE INTO name`);
  /// - an UPDATE or DELETE the classifier marks `affectsAllRows`, named only when it is a
  ///   plain single-table statement (see `allRowsTarget`);
  /// - an `EXPLAIN` that runs a statement other than a read (unnamed: the classifier keeps the
  ///   inner kind, not its text);
  /// - a statement the classifier marks `isDestructive` (ClickHouse `ALTER TABLE … DELETE`,
  ///   `CLEAR`, `REPLACE PARTITION`, `REPLACE TABLE`, `OPTIMIZE … DEDUPLICATE`), named by its
  ///   table when it starts `ALTER | REPLACE | OPTIMIZE [TEMPORARY] TABLE name` (see `tableTarget`);
  /// - MongoDB `drop()`, `dropIndex`, `dropDatabase()` and `deleteMany({})`;
  /// - on ClickHouse, unnamed: a `PARALLEL WITH` chain (every statement in it runs) and
  ///   `TRUNCATE ALL TABLES` / `TRUNCATE DATABASE` (see `namesNoSingleTarget`).
  ///
  /// Any other statement, an unrecognized one included, is `.none`: the caller's own rules
  /// apply to it.
  static func evaluate(
    _ statement: ClassifiedStatement, dialect: SQLDialect, database: String? = nil
  ) -> Verdict {
    if dialect == .mongodb {
      return verdict(mongoDestructive(statement, database: database))
    }
    let pieces = lexemes(statement.text, dialect: dialect)
    if dialect == .clickhouse, namesNoSingleTarget(pieces) { return .unnamed }
    if let destructive = sqlDestructive(pieces, dialect: dialect) { return verdict(destructive) }
    // A plain EXPLAIN runs nothing; EXPLAIN ANALYZE runs its statement
    if case .explain(let inner, let analyze) = statement.kind {
      guard analyze else { return .none }
      return SQLStatementClassifier.effectiveKind(inner) == .read ? .none : .unnamed
    }
    if let replaced = createOrReplace(pieces) { return verdict(replaced) }
    if let altered = alterTable(pieces, dialect: dialect) { return verdict(altered) }
    if let merged = mergeDelete(pieces) { return verdict(merged) }
    if statement.isDestructive { return verdict(.some(tableTarget(pieces))) }
    if statement.affectsAllRows { return verdict(.some(allRowsTarget(pieces))) }
    return .none
  }

  /// nil → `.none`; `.some(nil)` → `.unnamed`
  private static func verdict(_ destructive: String??) -> Verdict {
    switch destructive {
    case .none: .none
    case .some(.none): .unnamed
    case .some(.some(let name)): .confirm(name)
    }
  }

  /// nil when `statement` is not destructive; `.some(nil)` when it is but has no readable name
  private static func mongoDestructive(
    _ statement: ClassifiedStatement, database: String?
  ) -> String?? {
    let command = try? MongoshParser.parse(statement.text)
    switch command {
    case .admin(.drop(let collection)):
      return .some(nonEmpty(collection))
    case .admin(.dropIndex(_, let index)):
      if case .string(let name) = index { return .some(nonEmpty(name)) }
      return .some(nil)
    case .admin(.dropDatabase(let name)):
      return .some(nonEmpty(name ?? database))
    case .deleteMany(let collection, _) where statement.affectsAllRows:
      return .some(nonEmpty(collection))
    default:
      // A command the parser cannot read is unknown to the classifier: not destructive here,
      // and Safe Mode treats it as a write
      return statement.isDestructive ? .some(nil) : nil
    }
  }

  /// nil when `pieces` are not a DROP or TRUNCATE; `.some(nil)` when they are but name no
  /// single object. `DROP a, b` names no single object. A `DO` block, `EXECUTE` or `CALL`
  /// runs code the text does not show: destructive, with no name. So does a MySQL executable
  /// comment (`/*! ... */`), which MySQL runs as SQL.
  private static func sqlDestructive(_ pieces: [Piece], dialect: SQLDialect) -> String?? {
    if pieces.contains(where: \.isExecutableComment) { return .some(nil) }
    guard let first = pieces.first?.keyword else { return nil }
    if opaque.contains(first) { return .some(nil) }
    guard first == "DROP" || first == "TRUNCATE" else { return nil }
    var index = 1
    if first == "DROP" {
      skip(["TEMPORARY", "TEMP", "MATERIALIZED", "FOREIGN"], in: pieces, at: &index)
      guard index < pieces.count, let word = pieces[index].keyword, droppable.contains(word)
      else { return .some(nil) }
      index += 1
      skip(["CONCURRENTLY"], in: pieces, at: &index)
    } else {
      // ClickHouse `TRUNCATE TEMPORARY TABLE t`
      let words: Set<String> =
        dialect == .clickhouse ? ["TEMPORARY", "TABLE", "ONLY"] : ["TABLE", "ONLY"]
      skip(words, in: pieces, at: &index)
    }
    return .some(objectName(pieces, at: &index))
  }

  /// ClickHouse statements that are destructive with no single target: `PARALLEL WITH` at any
  /// depth (as the classifier reads it), or `TRUNCATE [TEMPORARY] [TABLE] ALL | DATABASE`
  private static func namesNoSingleTarget(_ pieces: [Piece]) -> Bool {
    let parallel = pieces.indices.dropLast().contains { index in
      pieces[index].keyword == "PARALLEL" && pieces[index + 1].keyword == "WITH"
    }
    guard !parallel else { return true }
    guard pieces.first?.keyword == "TRUNCATE" else { return false }
    var index = 1
    skip(["TEMPORARY", "TABLE"], in: pieces, at: &index)
    return index < pieces.count && ["ALL", "DATABASE"].contains(pieces[index].keyword ?? "")
  }

  /// `CREATE OR REPLACE [TEMP | TEMPORARY]` of an object that holds data: nil for any other
  /// statement, `.some(nil)` when the object's name cannot be read
  private static func createOrReplace(_ pieces: [Piece]) -> String?? {
    guard pieces.count > 3, pieces[0].keyword == "CREATE", pieces[1].keyword == "OR",
      pieces[2].keyword == "REPLACE"
    else { return nil }
    var index = 3
    skip(["TEMP", "TEMPORARY"], in: pieces, at: &index)
    guard index < pieces.count, let word = pieces[index].keyword, replaceable.contains(word)
    else { return nil }
    index += 1
    return .some(objectName(pieces, at: &index))
  }

  /// `ALTER TABLE name` (MySQL `ALTER [ONLINE] [IGNORE] TABLE`) with a top-level DROP that
  /// removes data or a `TRUNCATE PARTITION`: nil when it has none, `.some(nil)` when the
  /// table's name cannot be read
  private static func alterTable(_ pieces: [Piece], dialect: SQLDialect) -> String?? {
    guard pieces.first?.keyword == "ALTER" else { return nil }
    var start = 1
    skip(["ONLINE", "IGNORE"], in: pieces, at: &start)
    guard start + 1 < pieces.count, pieces[start].keyword == "TABLE" else { return nil }
    start += 1
    let base = pieces[0].depth
    let destructive = pieces.indices.dropFirst(start).contains { index in
      guard pieces[index].depth == base else { return false }
      switch pieces[index].keyword {
      case "DROP": return dropsData(pieces, at: index, dialect: dialect)
      case "TRUNCATE":
        return pieces.indices.contains(index + 1)
          && pieces[index + 1].keyword == "PARTITION"
      default: return false
      }
    }
    guard destructive else { return nil }
    var index = start
    return .some(objectName(pieces, at: &index, then: ["ONLY"]))
  }

  /// A DROP in an ALTER TABLE action list, other than the ones that remove no data:
  /// `ALTER [COLUMN] x DROP DEFAULT | NOT NULL | IDENTITY | EXPRESSION` and
  /// `DROP CONSTRAINT | PRIMARY KEY | FOREIGN KEY | CHECK`, plus `DROP INDEX | KEY` on MySQL
  /// (elsewhere `DROP index` drops a column named index). Fails closed: any other DROP counts.
  private static func dropsData(_ pieces: [Piece], at index: Int, dialect: SQLDialect) -> Bool {
    let next = pieces.indices.contains(index + 1) ? pieces[index + 1].keyword : nil
    if ["CONSTRAINT", "PRIMARY", "FOREIGN", "CHECK"].contains(next) { return false }
    if dialect == .mysql, ["INDEX", "KEY"].contains(next) { return false }
    guard ["DEFAULT", "NOT", "IDENTITY", "EXPRESSION"].contains(next) else { return true }
    if next == "NOT" {
      guard pieces.indices.contains(index + 2), pieces[index + 2].keyword == "NULL" else {
        return true
      }
    }
    // The column of `ALTER [COLUMN] x`
    guard index >= 3, pieces[index - 1].name != nil else { return true }
    let before = pieces[index - 2].keyword
    if before == "ALTER" { return false }
    return !(before == "COLUMN" && pieces[index - 3].keyword == "ALTER")
  }

  /// A MERGE with `THEN DELETE`: nil for any other statement; the target of a statement that
  /// starts with `MERGE INTO [ONLY] name`, else `.some(nil)` (a MERGE after WITH included: the
  /// classifier's `affectsAllRows` does not look inside MERGE)
  private static func mergeDelete(_ pieces: [Piece]) -> String?? {
    let hasMerge = pieces.contains { $0.keyword == "MERGE" }
    let deletes = pieces.indices.dropLast().contains {
      pieces[$0].keyword == "THEN" && pieces[$0 + 1].keyword == "DELETE"
    }
    guard hasMerge, deletes else { return nil }
    guard pieces.count > 2, pieces[0].keyword == "MERGE", pieces[1].keyword == "INTO" else {
      return .some(nil)
    }
    var index = 2
    skip(["ONLY"], in: pieces, at: &index)
    return .some(objectName(pieces, at: &index))
  }

  /// The table of `ALTER | REPLACE | OPTIMIZE [TEMPORARY] TABLE [IF EXISTS] name`; nil for any
  /// other statement or a name that cannot be read
  private static func tableTarget(_ pieces: [Piece]) -> String? {
    guard ["ALTER", "REPLACE", "OPTIMIZE"].contains(pieces.first?.keyword ?? "") else {
      return nil
    }
    var index = 1
    skip(["TEMPORARY"], in: pieces, at: &index)
    guard index < pieces.count, pieces[index].keyword == "TABLE" else { return nil }
    index += 1
    return objectName(pieces, at: &index)
  }

  /// The table of an UPDATE or DELETE with no WHERE, read only from a plain single-table
  /// statement: `DELETE FROM [ONLY] name [[AS] alias] [RETURNING …]` or
  /// `UPDATE [ONLY] name [[AS] alias] SET …` with no top-level FROM, USING or JOIN after SET.
  /// nil for anything else (a WITH, several targets, a join, a modifier keyword before the
  /// target, `DELETE … USING`, `UPDATE OR REPLACE`, ...)
  private static func allRowsTarget(_ pieces: [Piece]) -> String? {
    guard let first = pieces.first?.keyword, first == "DELETE" || first == "UPDATE" else {
      return nil
    }
    var index = 1
    if first == "DELETE" {
      guard pieces.count > 1, pieces[1].keyword == "FROM" else { return nil }
      index = 2
    }
    skip(["ONLY"], in: pieces, at: &index)
    guard index < pieces.count, !modifiers.contains(pieces[index].keyword ?? "") else {
      return nil
    }
    guard let name = objectName(pieces, at: &index) else { return nil }
    let ends: Set<String> = first == "DELETE" ? ["RETURNING"] : ["SET"]
    if index < pieces.count, !ends.contains(pieces[index].keyword ?? "") {
      if pieces[index].keyword == "AS" { index += 1 }
      guard index < pieces.count, pieces[index].name != nil else { return nil }
      index += 1
    }
    if first == "DELETE" {
      return index >= pieces.count || pieces[index].keyword == "RETURNING" ? name : nil
    }
    guard index < pieces.count, pieces[index].keyword == "SET" else { return nil }
    let base = pieces[0].depth
    let joins = pieces[index...].contains {
      $0.depth == base && ["FROM", "USING", "JOIN"].contains($0.keyword ?? "")
    }
    return joins ? nil : name
  }

  /// Reads `[IF EXISTS] [then…] name[.name…]` at `index`, leaving `index` after it; nil when
  /// no name can be read or a `,` follows it (several objects)
  private static func objectName(
    _ pieces: [Piece], at index: inout Int, then words: Set<String> = []
  ) -> String? {
    if index + 1 < pieces.count, pieces[index].keyword == "IF",
      pieces[index + 1].keyword == "EXISTS"
    {
      index += 2
    }
    skip(words, in: pieces, at: &index)
    var parts: [String] = []
    while index < pieces.count, let part = pieces[index].name {
      parts.append(part)
      index += 1
      guard index < pieces.count, pieces[index].symbol == "." else { break }
      index += 1
    }
    guard !parts.isEmpty, index >= pieces.count || pieces[index].symbol != "," else {
      return nil
    }
    return nonEmpty(parts.joined(separator: "."))
  }

  private static func skip(_ words: Set<String>, in pieces: [Piece], at index: inout Int) {
    while index < pieces.count, let word = pieces[index].keyword, words.contains(word) {
      index += 1
    }
  }

  /// Statements that run a block, a prepared statement or a procedure
  private static let opaque: Set<String> = ["DO", "EXECUTE", "CALL"]

  /// Object kinds a DROP names before the object
  private static let droppable: Set<String> = [
    "TABLE", "VIEW", "INDEX", "SCHEMA", "DATABASE", "SEQUENCE", "FUNCTION", "PROCEDURE",
    "TRIGGER", "TYPE", "DOMAIN", "EXTENSION", "EVENT", "MACRO", "COLLATION", "TABLESPACE",
  ]

  /// Object kinds whose `CREATE OR REPLACE` drops the data the old object held
  private static let replaceable: Set<String> = ["TABLE", "SCHEMA", "DATABASE", "SEQUENCE"]

  /// Words that may come before an UPDATE's target (MySQL `LOW_PRIORITY`, `IGNORE`, SQLite
  /// `OR REPLACE`)
  private static let modifiers: Set<String> = ["LOW_PRIORITY", "QUICK", "IGNORE", "OR"]

  private struct Piece {
    /// An unquoted word, ASCII uppercased; nil unless every scalar is ASCII
    var keyword: String?
    /// An unquoted word as written, or a quoted identifier's content
    var name: String?
    var symbol: String?
    /// A MySQL executable comment (`/*! ... */`)
    var isExecutableComment = false
    /// Parenthesis nesting level, as `SQLTokenizer.tokens` counts it (`(` and `)` carry the
    /// outer level)
    var depth = 0
  }

  /// The statement's lexemes without whitespace and comments
  private static func lexemes(_ text: String, dialect: SQLDialect) -> [Piece] {
    let tokenizer = SQLTokenizer(dialect: dialect)
    let scalars = Array(text.unicodeScalars)
    var pieces: [Piece] = []
    var depth = 0
    var index = 0
    while index < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: index)
      let raw = SQLTokenizer.text(scalars, lexeme.range)
      switch lexeme.kind {
      case .whitespace, .comment:
        break
      case .word:
        let ascii = raw.unicodeScalars.allSatisfy(\.isASCII)
        pieces.append(
          Piece(keyword: ascii ? SQLTokenizer.asciiUppercased(raw) : nil, name: raw, depth: depth))
      case .quoted(.quotedIdentifier, let content):
        pieces.append(Piece(name: content, depth: depth))
      case .symbol:
        if raw == ")" { depth = max(0, depth - 1) }
        pieces.append(Piece(symbol: raw, depth: depth))
        if raw == "(" { depth += 1 }
      case .executableComment:
        pieces.append(Piece(isExecutableComment: true, depth: depth))
      default:
        pieces.append(Piece(depth: depth))
      }
      index = max(lexeme.range.upperBound, index + 1)
    }
    return pieces
  }

  private static func nonEmpty(_ name: String?) -> String? {
    guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return name
  }
}
