// SQLFormatter.swift
// Pretty-prints SQL for the editor's Format button

import Foundation

/// Reformats SQL with one clause per line and indented clause contents.
/// Built on the shared lexeme scanner, so string literals, quoted identifiers, dollar quotes
/// and comments are re-emitted verbatim. Only whitespace changes, plus keywords uppercased
/// (unquoted words are case-insensitive in PostgreSQL). Adjacent tokens stay adjacent, so
/// operators like `>=` and `::` are never split.
nonisolated enum SQLFormatter {

  static func format(_ sql: String) -> String {
    let items = lex(sql)
    guard !items.isEmpty else { return sql }
    var printer = Printer(items: items)
    printer.run()
    // Safety net: never return text whose tokens differ from the input's
    return signature(of: lex(printer.output)) == signature(of: items) ? printer.output : sql
  }

  /// Everything about `items` that affects meaning: kinds, texts (ASCII words by their
  /// uppercased form) and string continuations, compared scalar by scalar.
  private static func signature(of items: [Item]) -> [[Unicode.Scalar]] {
    items.map { item in
      let text = "\(item.kind)|\(item.continuesString)|\(item.keyword ?? item.text)"
      return Array(text.unicodeScalars)
    }
  }

  // MARK: - Keywords

  /// Words that start a clause in a query; their contents go on indented lines.
  private static let clauseKeywords: Set<String> = [
    "SELECT", "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "RETURNING",
    "SET", "VALUES", "WINDOW", "UNION", "INTERSECT", "EXCEPT",
  ]

  /// Clause words that only start a clause as the first word of a statement
  /// (`x::timestamp with time zone`, `FOR UPDATE`, `ON DELETE CASCADE`).
  private static let statementClauseKeywords: Set<String> = ["WITH", "UPDATE", "DELETE"]

  /// Words kept on the clause's header line (`GROUP BY`, `UNION ALL`, `DELETE FROM`).
  private static let clauseContinuations: [String: Set<String>] = [
    "SELECT": ["DISTINCT", "ALL"], "GROUP": ["BY"], "ORDER": ["BY"], "UNION": ["ALL", "DISTINCT"],
    "INTERSECT": ["ALL"], "EXCEPT": ["ALL"], "DELETE": ["FROM"], "WITH": ["RECURSIVE"],
  ]

  private static let joinModifiers: Set<String> = [
    "LEFT", "RIGHT", "FULL", "INNER", "CROSS", "NATURAL", "OUTER",
  ]

  private static let keywords: Set<String> =
    clauseKeywords.union(statementClauseKeywords).union(joinModifiers).union([
      "ALL", "ALTER", "ANALYZE", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE",
      "CAST", "CHECK", "COMMIT", "CONFLICT", "CONSTRAINT", "CREATE", "DEFAULT", "DESC",
      "DISTINCT", "DO", "DROP", "ELSE", "END", "EXISTS", "EXPLAIN", "FALSE", "FILTER", "FIRST",
      "FOREIGN", "ILIKE", "IN", "INDEX", "INSERT", "INTO", "IS", "JOIN", "KEY", "LAST",
      "LATERAL", "LIKE", "NOT", "NOTHING", "NULL", "NULLS", "ON", "OR", "OVER", "PARTITION",
      "PRIMARY", "RECURSIVE", "REFERENCES", "ROLLBACK", "SOME", "TABLE", "THEN", "TRUE",
      "TRUNCATE", "UNIQUE", "USING", "VIEW", "WHEN",
    ])

  // MARK: - Lexing

  private enum ItemKind {
    case word
    case symbol
    case lineComment
    case blockComment
    /// String, quoted identifier or dollar quote
    case literal
  }

  private struct Item {
    let kind: ItemKind
    let text: String
    /// ASCII-uppercased text of a word, for keyword checks
    let keyword: String?
    /// Whitespace or a comment preceded this item in the input
    let spaced: Bool
    /// A string constant continuing the previous one (a newline separates them, so
    /// PostgreSQL concatenates them)
    let continuesString: Bool

    var isComment: Bool { kind == .lineComment || kind == .blockComment }
  }

  private static func lex(_ sql: String) -> [Item] {
    let scalars = Array(sql.unicodeScalars)
    var items: [Item] = []
    var spaced = false
    var hadNewline = false
    var i = 0
    while i < scalars.count {
      let lexeme = SQLTokenizer.lexeme(in: scalars, at: i)
      let raw = SQLTokenizer.text(scalars, lexeme.range)
      i = lexeme.range.upperBound
      let kind: ItemKind
      switch lexeme.kind {
      case .whitespace:
        spaced = true
        hadNewline = hadNewline || raw.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
        continue
      case .comment:
        // Compare scalars: `hasPrefix` would miss `--` followed by a combining mark
        kind = scalars[lexeme.range.lowerBound] == "-" ? .lineComment : .blockComment
      case .word, .number:
        kind = .word
      case .quoted(.backslashString, _):
        // Where it ends depends on standard_conforming_strings: fail closed (no items, so
        // `format` returns its input unchanged)
        return []
      case .quoted, .dollarString:
        kind = .literal
      case .symbol:
        kind = .symbol
      }
      // Only all-ASCII words can be keywords: `Set<String>` uses canonical equivalence
      let isASCIIWord = kind == .word && raw.unicodeScalars.allSatisfy(\.isASCII)
      let upper = isASCIIWord ? SQLTokenizer.asciiUppercased(raw) : nil
      let text = upper.map { keywords.contains($0) ? $0 : raw } ?? raw
      let previous = items.last { !$0.isComment }
      let continuesString = kind == .literal && previous?.kind == .literal && hadNewline
      items.append(
        Item(
          kind: kind, text: text, keyword: upper, spaced: spaced,
          continuesString: continuesString))
      spaced = kind == .lineComment || kind == .blockComment
      if !spaced { hadNewline = false }
    }
    return items
  }

  // MARK: - Printing

  private struct Printer {
    /// A parenthesis level: the top level or a subquery is a query; anything else is inline.
    struct Frame {
      let isQuery: Bool
      /// Indent of this query's clause keywords
      let base: Int
      /// Indent of the line holding the opening parenthesis
      let openIndent: Int
    }

    enum Break: Equatable {
      case line(indent: Int)
      case blank
    }

    let items: [Item]
    var output = ""
    var lineIndent = 0
    var frames = [Frame(isQuery: true, base: 0, openIndent: 0)]
    var pendingBreak: Break?
    var lastText = ""
    var isStatementStart = true
    var isInBetween = false

    init(items: [Item]) {
      self.items = items
    }

    var frame: Frame { frames[frames.count - 1] }

    mutating func run() {
      var index = 0
      while index < items.count {
        index = handle(at: index)
      }
    }

    /// Prints the item at `index` and returns the index of the next unprinted item.
    mutating func handle(at index: Int) -> Int {
      let item = items[index]
      switch item.kind {
      case .lineComment:
        emit(item.text, spaced: true)
        requestBreak(.line(indent: lineIndent))
        return index + 1
      case .blockComment:
        emit(item.text, spaced: true)
        return index + 1
      case .symbol:
        handleSymbol(item, at: index)
        isStatementStart = item.text == ";"
        return index + 1
      case .literal:
        if item.continuesString { requestBreak(.line(indent: lineIndent)) }
        emit(item.text, spaced: item.spaced)
        isStatementStart = false
        return index + 1
      case .word:
        let next = handleWord(item, at: index)
        isStatementStart = false
        return next
      }
    }

    mutating func handleSymbol(_ item: Item, at index: Int) {
      switch item.text {
      case ",":
        emit(",", spaced: false)
        if frame.isQuery { requestBreak(.line(indent: frame.base + 1)) }
      case ";":
        emit(";", spaced: false)
        frames.removeSubrange(1...)
        isInBetween = false
        requestBreak(.blank)
      case "(":
        emit("(", spaced: item.spaced)
        let opensQuery = ["SELECT", "WITH"].contains(nextKeyword(after: index))
        frames.append(
          Frame(
            isQuery: opensQuery, base: opensQuery ? lineIndent + 1 : frame.base,
            openIndent: lineIndent))
        if opensQuery { requestBreak(.line(indent: lineIndent + 1)) }
      case ")":
        if frames.count > 1 {
          let closed = frames.removeLast()
          if closed.isQuery { requestBreak(.line(indent: closed.openIndent)) }
        }
        emit(")", spaced: false)
      default:
        emit(item.text, spaced: item.spaced)
      }
    }

    mutating func handleWord(_ item: Item, at index: Int) -> Int {
      guard frame.isQuery, let keyword = item.keyword else {
        emit(item.text, spaced: item.spaced)
        return index + 1
      }
      if SQLFormatter.clauseKeywords.contains(keyword)
        || (isStatementStart && SQLFormatter.statementClauseKeywords.contains(keyword))
      {
        var header = item.text
        var next = index + 1
        let continuations = SQLFormatter.clauseContinuations[keyword] ?? []
        while next < items.count, let word = items[next].keyword, continuations.contains(word) {
          header += " " + items[next].text
          next += 1
        }
        requestBreak(.line(indent: frame.base))
        emit(header, spaced: true)
        requestBreak(.line(indent: frame.base + 1))
        isInBetween = false
        return next
      }
      switch keyword {
      case "AND" where isInBetween:
        isInBetween = false
      case "AND", "OR":
        requestBreak(.line(indent: frame.base + 1))
      case "BETWEEN":
        isInBetween = true
      case "JOIN" where !SQLFormatter.joinModifiers.contains(previousKeyword(before: index)):
        requestBreak(.line(indent: frame.base + 1))
      case _ where SQLFormatter.joinModifiers.contains(keyword):
        let startsJoin = ["JOIN", "OUTER"].contains(nextKeyword(after: index))
        if startsJoin && !SQLFormatter.joinModifiers.contains(previousKeyword(before: index)) {
          requestBreak(.line(indent: frame.base + 1))
        }
      default:
        break
      }
      emit(item.text, spaced: item.spaced)
      return index + 1
    }

    /// Keyword of the next non-comment item, or "" if it is not a word.
    func nextKeyword(after index: Int) -> String {
      items[(index + 1)...].first { !$0.isComment }?.keyword ?? ""
    }

    /// Keyword of the previous non-comment item, or "" if it is not a word.
    func previousKeyword(before index: Int) -> String {
      items[..<index].last { !$0.isComment }?.keyword ?? ""
    }

    /// A blank line is never downgraded to a line break.
    mutating func requestBreak(_ newBreak: Break) {
      if pendingBreak != .blank { pendingBreak = newBreak }
    }

    mutating func emit(_ text: String, spaced: Bool) {
      if let pending = pendingBreak {
        pendingBreak = nil
        if case .line(let indent) = pending { lineIndent = indent } else { lineIndent = 0 }
        if !output.isEmpty { output += pending == .blank ? "\n\n" : "\n" }
        output += String(repeating: "  ", count: lineIndent)
      } else if !output.isEmpty, lastText == "," || (spaced && lastText != "(") {
        output += " "
      }
      output += text
      lastText = text
    }
  }
}
