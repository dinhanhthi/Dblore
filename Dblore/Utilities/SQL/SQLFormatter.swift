// SQLFormatter.swift
// Pretty-prints SQL for the editor's Format button

import Foundation

/// Reformats SQL with one clause per line and its contents on the same line. Only the
/// SELECT list breaks at commas; joins start a line with their ON condition below.
/// Built on the shared lexeme scanner, so string literals, quoted identifiers, dollar quotes
/// and comments are re-emitted verbatim. Only whitespace changes, plus the case `Options` sets
/// for keywords and for known built-in function names right before `(`. Other words, and words
/// right after `.`, `:`, `@` or `$` (names and parameters), keep their case. Adjacent tokens
/// stay adjacent, so operators like `>=` and `::` are never split.
nonisolated enum SQLFormatter {

  struct Options: Equatable, Sendable {
    enum Indent: Equatable, Sendable {
      case spaces(Int)
      case tab
    }

    enum WordCase: String, CaseIterable, Sendable {
      case upper
      case lower
      case preserve

      /// `word` (all ASCII) in this case
      func apply(to word: String) -> String {
        switch self {
        case .upper: SQLTokenizer.asciiUppercased(word)
        case .lower: SQLTokenizer.asciiLowercased(word)
        case .preserve: word
        }
      }
    }

    enum CommaPosition: String, CaseIterable, Sendable {
      /// `a,` then `b` on the next line
      case trailing
      /// `a` then `, b` on the next line
      case leading
    }

    /// One nesting level; the SELECT list stays aligned with spaces after it
    var indent = Indent.spaces(2)
    var keywordCase = WordCase.upper
    var functionCase = WordCase.preserve
    var commaPosition = CommaPosition.trailing
    /// Lines wider than this break at a comma, AND or OR; 0 turns wrapping off
    var maxLineWidth = 0

    static let `default` = Options()
  }

  static func format(
    _ sql: String, dialect: SQLDialect = .postgresql, options: Options = .default
  ) -> String {
    let items = lex(sql, dialect: dialect, options: options)
    guard !items.isEmpty else { return sql }
    var printer = Printer(items: items, options: options)
    printer.run()
    // Safety net: never return text whose tokens differ from the input's
    return signature(of: lex(printer.output, dialect: dialect)) == signature(of: items)
      ? printer.output : sql
  }

  /// Whether `a` and `b` have the same tokens in the same order. Only keywords and known
  /// function names before `(` may differ in case; other words must match exactly.
  static func hasSameTokens(_ a: String, _ b: String, dialect: SQLDialect) -> Bool {
    signature(of: lex(a, dialect: dialect)) == signature(of: lex(b, dialect: dialect))
  }

  /// Everything about `items` that affects meaning: kinds, texts (words whose case may
  /// change by their uppercased form) and string continuations, compared scalar by scalar.
  private static func signature(of items: [Item]) -> [[Unicode.Scalar]] {
    items.map { item in
      let word = item.foldsCase ? item.keyword ?? item.text : item.text
      let text = "\(item.kind)|\(item.continuesString)|\(item.foldsCase)|\(word)"
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

  /// Words before a table name, so `INSERT INTO t(a)` keeps the case of `t`. A function
  /// right after ON (`JOIN u ON lower(a) = b`) keeps its case too, as `ON t(a)` names a table.
  private static let tableNameKeywords: Set<String> = [
    "INTO", "TABLE", "REFERENCES", "VIEW", "INSERT", "EXISTS", "WITH", "RECURSIVE", "ON", "COPY",
    "ANALYZE", "VACUUM", "IGNORE", "LOW_PRIORITY", "HIGH_PRIORITY", "DELAYED", "REPLACE",
    "UPDATE",
  ]

  /// Built-in functions whose case `Options.functionCase` sets. Any other word before `(`
  /// may be a table name (case-sensitive on MySQL), so it keeps its case.
  private static let functionNames: Set<String> = [
    "ABS", "AGE", "ARRAY_AGG", "ARRAY_LENGTH", "ARRAY_TO_STRING", "AVG", "CEIL", "CEILING",
    "CHAR_LENGTH", "COALESCE", "CONCAT", "CONCAT_WS", "COUNT", "DATE_FORMAT", "DATE_PART",
    "DATE_TRUNC", "DENSE_RANK", "EXTRACT", "FIRST_VALUE", "FLOOR", "GREATEST", "GROUP_CONCAT",
    "IFNULL", "JSON_AGG", "JSON_BUILD_OBJECT", "JSON_EXTRACT", "JSONB_AGG",
    "JSONB_BUILD_OBJECT", "LAG", "LAST_VALUE", "LEAD", "LEAST", "LENGTH", "LOWER", "LPAD",
    "LTRIM", "MAX", "MIN", "MOD", "NOW", "NTILE", "NULLIF", "POSITION", "RANK", "REPLACE",
    "ROUND", "ROW_NUMBER", "RPAD", "RTRIM", "SPLIT_PART", "STRING_AGG", "SUBSTR", "SUBSTRING",
    "SUM", "TO_CHAR", "TO_DATE", "TO_TIMESTAMP", "TRIM", "TRUNC", "UNNEST", "UPPER",
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
    /// Printed text: keywords and function names in the case `Options` sets
    var text: String
    /// ASCII-uppercased text of a word, for keyword checks; nil for a word right after `.`,
    /// `:`, `@` or `$` (a name or a parameter, never a keyword or function)
    let keyword: String?
    /// A keyword or a known function name before `(`, whose case `Options` may change
    var foldsCase: Bool
    /// Whitespace or a comment preceded this item in the input
    let spaced: Bool
    /// A line break separates this item from the previous one in the input
    let startsLine: Bool
    /// A string constant continuing the previous one (a newline separates them, so
    /// PostgreSQL concatenates them)
    let continuesString: Bool

    var isComment: Bool { kind == .lineComment || kind == .blockComment }
  }

  private static func lex(
    _ sql: String, dialect: SQLDialect, options: Options = .default
  ) -> [Item] {
    let scalars = Array(sql.unicodeScalars)
    let tokenizer = SQLTokenizer(dialect: dialect)
    var items: [Item] = []
    var spaced = false
    var hadNewline = false
    var startsLine = false
    var i = 0
    while i < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: i)
      let raw = SQLTokenizer.text(scalars, lexeme.range)
      i = lexeme.range.upperBound
      let kind: ItemKind
      switch lexeme.kind {
      case .whitespace:
        spaced = true
        let isNewline = raw.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
        hadNewline = hadNewline || isNewline
        startsLine = startsLine || isNewline
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
      case .executableComment:
        // MySQL runs its content: leave the text unformatted
        return []
      case .quoted, .dollarString:
        kind = .literal
      case .symbol:
        kind = .symbol
      }
      // Only all-ASCII words can be keywords: `Set<String>` uses canonical equivalence
      let isASCIIWord = kind == .word && raw.unicodeScalars.allSatisfy(\.isASCII)
      let isName = isQualified(after: items, spaced: spaced)
      let upper = isASCIIWord && !isName ? SQLTokenizer.asciiUppercased(raw) : nil
      let isKeyword = upper.map(keywords.contains) == true
      let text = isKeyword ? options.keywordCase.apply(to: raw) : raw
      let previous = items.last { !$0.isComment }
      let continuesString = kind == .literal && previous?.kind == .literal && hadNewline
      items.append(
        Item(
          kind: kind, text: text, keyword: upper, foldsCase: isKeyword, spaced: spaced,
          startsLine: startsLine, continuesString: continuesString))
      startsLine = false
      spaced = kind == .lineComment || kind == .blockComment
      if !spaced { hadNewline = false }
    }
    applyFunctionCase(to: &items, options: options)
    return items
  }

  /// Sets the case of each known function name right before `(`, unless it names a table:
  /// after a table-name keyword (`INSERT INTO t(a)`), or before a CTE's column list
  /// (`t(a) AS (`).
  private static func applyFunctionCase(to items: inout [Item], options: Options) {
    /// Per open `(`: the index of the function name before it, if any
    var opens: [Int?] = []
    for index in items.indices where items[index].kind == .symbol {
      if items[index].text == "(" {
        opens.append(functionName(before: index, in: items))
      } else if items[index].text == ")", let open = opens.popLast() {
        let next = items[(index + 1)...].lazy.filter { !$0.isComment }
        let isCTEColumnList =
          next.first?.keyword == "AS" && next.dropFirst().first?.text == "("
        if let name = open, !isCTEColumnList { recase(&items[name], options: options) }
      }
    }
    // A `(` that is never closed opens no CTE body
    for name in opens.compactMap({ $0 }) { recase(&items[name], options: options) }
  }

  /// Index of the known function name directly before the `(` at `index`, or nil when there
  /// is none or it follows a table-name keyword.
  private static func functionName(before index: Int, in items: [Item]) -> Int? {
    guard !items[index].spaced, index > 0, let upper = items[index - 1].keyword,
      functionNames.contains(upper),
      !tableNameKeywords.contains(items[..<(index - 1)].last { !$0.isComment }?.keyword ?? "")
    else { return nil }
    return index - 1
  }

  private static func recase(_ item: inout Item, options: Options) {
    item.text = options.functionCase.apply(to: item.text)
    item.foldsCase = true
  }

  /// Whether a word follows `.`, `:`, `@` or `$` directly, so it is a name or a parameter
  /// (`t.first`, `:key`) whose case must not change.
  private static func isQualified(after items: [Item], spaced: Bool) -> Bool {
    guard !spaced, let last = items.last else { return false }
    return last.kind == .symbol && [".", ":", "@", "$"].contains(last.text)
  }

  // MARK: - Printing

  private struct Printer {
    /// A line's indent: nesting levels, then spaces that align it under a SELECT list.
    struct Margin: Equatable {
      var level = 0
      var align = 0

      var nested: Margin { Margin(level: level + 1, align: align) }
    }

    /// A parenthesis level: the top level or a subquery is a query; anything else is inline.
    struct Frame {
      let isQuery: Bool
      /// Indent of this query's clause keywords
      let base: Margin
      /// Indent of the line holding the opening parenthesis
      let openIndent: Margin
      /// Indent of the lines after a comma, set in a SELECT list
      var commaIndent: Margin?
      /// A JOIN is waiting for its ON condition
      var isInJoin = false
    }

    enum Break: Equatable {
      case line(indent: Margin)
      case blank
    }

    let items: [Item]
    let options: Options
    var output = ""
    /// The line being printed, kept out of `output` so a wrap can still split it
    var line = ""
    /// Width of `line` in characters, a tab counting as 4
    var column = 0
    /// UTF-8 offset in `line` where a wrap may break it
    var wrapPoint: Int?
    var lineIndent = Margin()
    /// Indent of the lines a wrap adds to the current line
    var wrapIndent = Margin(level: 1)
    var frames = [Frame(isQuery: true, base: Margin(), openIndent: Margin())]
    var pendingBreak: Break?
    var lastText = ""
    var isStatementStart = true
    /// The next AND belongs to a BETWEEN, so a wrap does not break before it
    var isInBetween = false

    init(items: [Item], options: Options) {
      self.items = items
      self.options = options
    }

    var frame: Frame {
      get { frames[frames.count - 1] }
      set { frames[frames.count - 1] = newValue }
    }

    mutating func run() {
      var index = 0
      while index < items.count {
        index = handle(at: index)
      }
      output += line
      line = ""
    }

    /// Prints the item at `index` and returns the index of the next unprinted item.
    mutating func handle(at index: Int) -> Int {
      let item = items[index]
      switch item.kind {
      case .lineComment, .blockComment:
        handleComment(item)
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
        if item.keyword == "AND" && isInBetween {
          isInBetween = false
        } else if item.keyword == "AND" || item.keyword == "OR" {
          markWrapPoint()
        }
        if item.keyword == "BETWEEN" { isInBetween = true }
        let next = handleWord(item, at: index)
        isStatementStart = false
        return next
      }
    }

    /// A comment on its own line in the input keeps its own line; a trailing comment stays
    /// on the line it follows, ahead of any pending break.
    mutating func handleComment(_ item: Item) {
      if item.startsLine {
        requestBreak(pendingBreak ?? .line(indent: lineIndent))
        emit(item.text, spaced: true)
        if item.kind == .lineComment { requestBreak(.line(indent: lineIndent)) }
      } else {
        let pending = pendingBreak
        pendingBreak = nil
        emit(item.text, spaced: true)
        pendingBreak = pending
        if item.kind == .lineComment { requestBreak(pending ?? .line(indent: lineIndent)) }
      }
    }

    mutating func handleSymbol(_ item: Item, at index: Int) {
      switch item.text {
      case ",":
        let listIndent = frame.isQuery ? frame.commaIndent : nil
        // A trailing line comment keeps its comma before it, so the tokens keep their order
        let next = items.indices.contains(index + 1) ? items[index + 1] : nil
        let isLeading =
          options.commaPosition == .leading
          && !(next?.kind == .lineComment && next?.startsLine == false)
        if isLeading, let indent = listIndent {
          requestBreak(.line(indent: Margin(level: indent.level, align: indent.align - 2)))
        } else if isLeading {
          markWrapPoint()
        }
        emit(",", spaced: false)
        if !isLeading, let indent = listIndent {
          requestBreak(.line(indent: indent))
        } else if listIndent == nil, !isLeading {
          markWrapPoint()
        }
      case ";":
        emit(";", spaced: false)
        frames.removeSubrange(1...)
        frame = Frame(isQuery: true, base: Margin(), openIndent: Margin())
        requestBreak(.blank)
      case "(":
        emit("(", spaced: item.spaced)
        let opensQuery = ["SELECT", "WITH"].contains(nextKeyword(after: index))
        frames.append(
          Frame(
            isQuery: opensQuery, base: opensQuery ? lineIndent.nested : frame.base,
            openIndent: lineIndent))
        if opensQuery { requestBreak(.line(indent: lineIndent.nested)) }
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
        frame.commaIndent =
          keyword == "SELECT"
          ? Margin(level: frame.base.level, align: frame.base.align + header.count + 1) : nil
        frame.isInJoin = false
        return next
      }
      switch keyword {
      case "JOIN" where !SQLFormatter.joinModifiers.contains(previousKeyword(before: index)):
        requestBreak(.line(indent: frame.base))
        frame.isInJoin = true
      case "JOIN":
        frame.isInJoin = true
      case "ON" where frame.isInJoin:
        requestBreak(.line(indent: frame.base.nested))
        frame.isInJoin = false
      case _ where SQLFormatter.joinModifiers.contains(keyword):
        let startsJoin = ["JOIN", "OUTER"].contains(nextKeyword(after: index))
        if startsJoin && !SQLFormatter.joinModifiers.contains(previousKeyword(before: index)) {
          requestBreak(.line(indent: frame.base))
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
      let hasOutput = !output.isEmpty || !line.isEmpty
      if let pending = pendingBreak {
        pendingBreak = nil
        if case .line(let indent) = pending { lineIndent = indent } else { lineIndent = Margin() }
        if hasOutput { output += line + (pending == .blank ? "\n\n" : "\n") }
        startLine(at: lineIndent)
        wrapIndent = lineIndent.nested
      } else if hasOutput, lastText == "," || (spaced && lastText != "(") {
        line += " "
        column += 1
      }
      line += text
      lastText = text
      if let newline = text.lastIndex(where: \.isNewline) {
        column = text[text.index(after: newline)...].count
        wrapPoint = nil
      } else {
        column += text.count
      }
      wrapIfNeeded()
    }

    /// The next item may start a wrapped line (it follows text on this line).
    mutating func markWrapPoint() {
      if pendingBreak == nil && !line.isEmpty { wrapPoint = line.utf8.count }
    }

    /// Once the line is wider than the limit, moves what follows its wrap point to a new
    /// line, one level deeper than the line the wrap started from.
    mutating func wrapIfNeeded() {
      guard options.maxLineWidth > 0, column > options.maxLineWidth, let point = wrapPoint
      else { return }
      wrapPoint = nil
      let cut = line.utf8.index(line.utf8.startIndex, offsetBy: point)
      var rest = line[cut...]
      if rest.first == " " { rest = rest.dropFirst() }
      output += line[..<cut] + "\n"
      lineIndent = wrapIndent
      startLine(at: lineIndent)
      line += rest
      column += rest.count
    }

    mutating func startLine(at margin: Margin) {
      switch options.indent {
      case .spaces(let width):
        line = String(repeating: " ", count: margin.level * max(width, 0) + margin.align)
        column = line.count
      case .tab:
        line =
          String(repeating: "\t", count: margin.level)
          + String(repeating: " ", count: margin.align)
        column = margin.level * 4 + margin.align
      }
      wrapPoint = nil
    }
  }
}
