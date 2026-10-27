//
//  SQLAutocompleteProvider+ContextParsing.swift
//  Dblore
//
//  SQL context detection and table reference extraction
//

import Foundation

// MARK: - Context Detection & Parsing

extension SQLAutocompleteProvider {
  /// Maximum size (UTF-16 units) of the statement window scanned around the cursor
  static let maxStatementWindow = 10_240

  /// The statement around the cursor: bounds are the nearest `;` before and after the cursor
  /// (the `;` themselves excluded), each side capped so the window is at most
  /// `maxStatementWindow` UTF-16 units. A `;` inside a string literal or comment may
  /// split the statement early; this is accepted for autocomplete purposes.
  /// SQLite and MySQL use the dialect lexer instead (see `lexedStatementWindow`).
  /// - Parameter position: cursor as a UTF-16 offset
  /// - Returns: the window text and the cursor as a UTF-16 offset inside it
  func statementWindow(
    in text: String, at position: Int, dialect: SQLDialect
  ) -> (text: String, cursor: Int) {
    if dialect == .sqlite || dialect == .mysql {
      return lexedStatementWindow(in: text, at: position, dialect: dialect)
    }
    let nsText = text as NSString
    let length = nsText.length
    let cursor = min(max(position, 0), length)
    let semicolon = UInt16(0x3B)  // ";"
    let halfWindow = Self.maxStatementWindow / 2

    var start = max(0, cursor - halfWindow)
    var index = cursor
    while index > start {
      if nsText.character(at: index - 1) == semicolon {
        start = index
        break
      }
      index -= 1
    }

    var end = min(length, cursor + halfWindow)
    index = cursor
    while index < end {
      if nsText.character(at: index) == semicolon {
        end = index
        break
      }
      index += 1
    }

    // Do not cut a surrogate pair in half
    if start > 0, start < length, UTF16.isTrailSurrogate(nsText.character(at: start)) {
      start += 1
    }
    if end > start, end < length, UTF16.isTrailSurrogate(nsText.character(at: end)) {
      end -= 1
    }
    start = min(start, cursor)
    end = max(end, cursor)

    if start == 0 && end == length { return (text, cursor) }
    return (nsText.substring(with: NSRange(location: start, length: end - start)), cursor - start)
  }

  /// Same window as `statementWindow`, but a `;` inside a string, comment, or quoted
  /// identifier is not a statement boundary (per the `dialect` lexer, so MySQL `#` comments and
  /// backticks count). A MySQL `DELIMITER` directive is ignored: only `;` splits. The scan is
  /// still capped at `maxStatementWindow`.
  private func lexedStatementWindow(
    in text: String, at position: Int, dialect: SQLDialect
  ) -> (text: String, cursor: Int) {
    let nsText = text as NSString
    let length = nsText.length
    let cursor = min(max(position, 0), length)
    let halfWindow = Self.maxStatementWindow / 2
    var start = max(0, cursor - halfWindow)
    var end = min(length, cursor + halfWindow)
    if start > 0, start < length, UTF16.isTrailSurrogate(nsText.character(at: start)) {
      start += 1
    }
    if end > start, end < length, UTF16.isTrailSurrogate(nsText.character(at: end)) {
      end -= 1
    }
    start = min(start, cursor)
    end = max(end, cursor)

    let window = nsText.substring(with: NSRange(location: start, length: end - start))
    let scalars = Array(window.unicodeScalars)
    var utf16At = [Int](repeating: 0, count: scalars.count + 1)
    var unit = 0
    for (index, scalar) in scalars.enumerated() {
      utf16At[index] = unit
      unit += scalar.utf16.count
    }
    utf16At[scalars.count] = unit

    let localCursor = cursor - start
    let tokenizer = SQLTokenizer(dialect: dialect)
    var splitBefore: Int?
    var splitAfter: Int?
    var i = 0
    while i < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: i)
      if case .symbol = lexeme.kind, scalars[lexeme.range.lowerBound] == ";" {
        let at = utf16At[lexeme.range.lowerBound]
        if at < localCursor {
          splitBefore = at + 1
        } else if splitAfter == nil {
          splitAfter = at
        }
      }
      let next = lexeme.range.upperBound
      i = next > i ? next : i + 1
    }

    let localStart = splitBefore ?? 0
    let localEnd = splitAfter ?? (end - start)
    if localStart == 0 && localEnd == end - start && start == 0 && end == length {
      return (text, cursor)
    }
    let slice = (window as NSString).substring(
      with: NSRange(location: localStart, length: localEnd - localStart))
    return (slice, localCursor - localStart)
  }

  /// Extract the current word/token being typed at cursor position
  /// - Parameter position: cursor as a UTF-16 offset
  func extractCurrentToken(from text: String, at position: Int) -> String {
    let nsText = text as NSString
    guard position > 0, position <= nsText.length else { return "" }

    let beforeCursor = nsText.substring(to: position)
    let afterCursor = nsText.substring(from: position)

    // Find start of token (word boundary) - search backwards in beforeCursor
    var tokenStart = 0
    for (index, char) in beforeCursor.enumerated().reversed() {
      if char.isWhitespace || "(),;".contains(char) {
        tokenStart = index + 1
        break
      }
    }

    // Find end of token in afterCursor
    var tokenEndInAfter = afterCursor.count
    for (index, char) in afterCursor.enumerated() {
      if char.isWhitespace || "(),;".contains(char) {
        tokenEndInAfter = index
        break
      }
    }

    let tokenInBefore = String(beforeCursor.suffix(beforeCursor.count - tokenStart))
    let tokenInAfter = String(afterCursor.prefix(tokenEndInAfter))

    let token = tokenInBefore + tokenInAfter
    return token.trimmingCharacters(in: CharacterSet.whitespaces)
  }

  /// Detect SQL context (what clause we're in)
  func detectContext(in text: String, before position: Int) -> SQLContext {
    let textBefore = (text as NSString).substring(
      to: min(max(position, 0), (text as NSString).length)
    )
    .uppercased()

    // Find the last SQL keyword before cursor
    let keywords = ["SELECT", "FROM", "WHERE", "JOIN", "ON", "GROUP BY", "ORDER BY", "HAVING"]

    var lastKeyword: String?
    var lastKeywordPosition = -1

    for keyword in keywords {
      if let range = textBefore.range(of: keyword, options: .backwards) {
        let keywordPosition = textBefore.distance(from: textBefore.startIndex, to: range.lowerBound)
        if keywordPosition > lastKeywordPosition {
          lastKeyword = keyword
          lastKeywordPosition = keywordPosition
        }
      }
    }

    switch lastKeyword {
    case "FROM", "JOIN":
      return .afterFromOrJoin
    case "SELECT", "WHERE", "ON", "HAVING":
      return .afterSelectOrWhere
    default:
      return .unknown
    }
  }

  /// Extract table names and aliases from FROM/JOIN clauses
  /// Returns a mapping of [alias/tableName: fullTableKey] where fullTableKey is "schema.table"
  ///
  /// Linear in the text length: the text is uppercased once, the start of the nearest stop keyword
  /// is precomputed for every position, and each FROM/JOIN occurrence only reads its own
  /// "table [alias]" tokens. Keywords are matched as plain substrings (also inside identifiers) and
  /// processed keyword by keyword in the same order as before, so the result is unchanged.
  func extractTableReferences(from text: String) -> [String: String] {
    // One code per Character (grapheme cluster): a plain scalar keeps its value, a multi-scalar
    // cluster gets a code that no keyword contains. Integer compares keep the scan fast in Debug.
    let characters = Array(text.uppercased())
    let chars: [UInt32] = characters.map { char in
      var scalars = char.unicodeScalars.makeIterator()
      guard let first = scalars.next(), scalars.next() == nil else { return 0x11_0000 }
      return first.value
    }
    let count = chars.count
    var tableRefs: [String: String] = [:]

    let keywords = [
      "FROM", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN",
    ].map(Self.codes)
    let stopKeywords = [
      "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "ON", "GROUP", "ORDER",
      "LIMIT", "UNION", "EXCEPT", "INTERSECT",
    ].map(Self.codes)

    // Cheap reject on the first letter (ASCII table) before comparing a whole word
    func firstLetters(_ words: [[UInt32]]) -> [Bool] {
      var table = [Bool](repeating: false, count: 128)
      for word in words { table[Int(word[0])] = true }
      return table
    }
    let keywordStarts = firstLetters(keywords)
    let stopStarts = firstLetters(stopKeywords)
    func canStart(_ table: [Bool], _ index: Int) -> Bool {
      let code = chars[index]
      return code < 128 && table[Int(code)]
    }

    func matches(_ word: [UInt32], at index: Int) -> Bool {
      guard index + word.count <= count else { return false }
      for offset in 0..<word.count where chars[index + offset] != word[offset] { return false }
      return true
    }

    // nextStop[i]: start of the first stop keyword at or after i (count if none)
    var nextStop = [Int](repeating: count, count: count + 1)
    if count > 0 {
      for index in stride(from: count - 1, through: 0, by: -1) {
        nextStop[index] =
          canStart(stopStarts, index) && stopKeywords.contains { matches($0, at: index) }
          ? index : nextStop[index + 1]
      }
    }

    let space = UInt32(0x20)
    func isWhitespace(_ index: Int) -> Bool {
      if let scalar = Unicode.Scalar(chars[index]) {
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
      }
      return characters[index].unicodeScalars.allSatisfy {
        CharacterSet.whitespacesAndNewlines.contains($0)
      }
    }

    /// Token "chars[from..<limit]" up to the next space, plus the index after it
    func token(from start: Int, limit: Int) -> (text: String, next: Int) {
      var end = start
      while end < limit && chars[end] != space { end += 1 }
      return (String(characters[start..<end]), end)
    }

    func record(afterKeywordAt start: Int) {
      // Clause = text up to the next stop keyword, trimmed
      var low = start
      var high = nextStop[start]
      while low < high && isWhitespace(low) { low += 1 }
      while high > low && isWhitespace(high - 1) { high -= 1 }
      guard low < high else { return }

      let tableName = token(from: low, limit: high)
      guard !tableName.text.isEmpty, let tableKey = findMatchingTableKey(for: tableName.text)
      else { return }

      // Add table name itself as a reference
      tableRefs[tableName.text.lowercased()] = tableKey

      // If there's an alias, add it too
      var aliasStart = tableName.next
      while aliasStart < high && chars[aliasStart] == space { aliasStart += 1 }
      if aliasStart < high {
        tableRefs[token(from: aliasStart, limit: high).text.lowercased()] = tableKey
      }
    }

    for keyword in keywords {
      var index = 0
      while index + keyword.count <= count {
        if canStart(keywordStarts, index) && matches(keyword, at: index) {
          record(afterKeywordAt: index + keyword.count)
          index += keyword.count
        } else {
          index += 1
        }
      }
    }

    return tableRefs
  }

  private static func codes(_ word: String) -> [UInt32] { word.unicodeScalars.map(\.value) }

  /// Find full table key ("schema.table") from schema cache by table name
  func findMatchingTableKey(for tableName: String) -> String? {
    let lowerTableName = tableName.lowercased()

    // Try exact match first
    for table in tables {
      if table.name.lowercased() == lowerTableName {
        return "\(table.schema).\(table.name)"
      }
    }

    // Try matching the end part (in case user typed "schema.table")
    if let dotIndex = lowerTableName.lastIndex(of: ".") {
      let nameOnly = String(lowerTableName[lowerTableName.index(after: dotIndex)...])
      for table in tables {
        if table.name.lowercased() == nameOnly {
          return "\(table.schema).\(table.name)"
        }
      }
    }

    return nil
  }

  enum SQLContext {
    case afterFromOrJoin  // Expecting table names
    case afterSelectOrWhere  // Expecting column names
    case unknown
  }
}

// MARK: - CTEs and SELECT aliases

/// What one token pass over the statement finds for completion
struct SQLStatementScope {
  /// CTEs in definition order with their column names
  var ctes: [(name: String, columns: [String])] = []
  /// Lowercased names of the CTEs used as a FROM / JOIN source
  var referencedCTEs: Set<String> = []
  /// SELECT-list aliases of the query level at the cursor when the cursor is in its
  /// ORDER BY or GROUP BY clause, else nil
  var orderByAliases: [String]?
}

/// A token of `SQLAutocompleteProvider.statementScope` (whitespace and comments dropped)
private struct ScopeToken {
  enum Kind { case word, quotedIdentifier, literal, symbol }
  let kind: Kind
  /// Raw text (content for a quoted identifier, empty for a literal)
  let text: String
  /// ASCII-uppercased text of a word, else nil
  let keyword: String?
  /// UTF-16 offset of the token start
  let offset: Int

  var isIdentifier: Bool { kind == .word || kind == .quotedIdentifier }
  func isSymbol(_ symbol: String) -> Bool { kind == .symbol && text == symbol }
}

/// Where a `WITH` clause is: `WITH [RECURSIVE] name [(columns)] AS [[NOT] MATERIALIZED] (body), ...`
private enum WithStep: Equatable {
  case none, name
  case afterName(String)
  case columns(String, [String])
  case afterColumns(String, [String])
  case body(String, [String]?)
  case afterBody
}

/// One parenthesis level of the statement
private struct ScopeFrame {
  /// Last clause keyword at this level ("SELECT", "FROM", "ORDER", ...)
  var clause = ""
  var selects = 0
  /// Items of the first SELECT list at this level (top-level tokens only: a nested group
  /// shows as its `(` and `)`)
  var items: [[ScopeToken]] = []
  var item: [ScopeToken] = []
  /// FROM / JOIN sources of the first SELECT at this level
  var sources: [(name: String, alias: String?)] = []
  var expectSource = false
  var with = WithStep.none
  /// Set when this level is a CTE body
  var cte: (name: String, columns: [String]?)?

  var collecting: Bool { clause == "SELECT" && selects == 1 }

  mutating func commitItem() {
    if !item.isEmpty { items.append(item) }
    item = []
  }
}

/// Output name of one SELECT-list item
private enum SelectItem {
  case named(String, isAlias: Bool)
  case star(qualifier: String?)
}

extension SQLAutocompleteProvider {
  /// Most columns kept for one CTE (column list or `*` items over repeated or chained sources),
  /// and most CTE column suggestions in all
  static let maxCTEColumns = 500
  /// Most ORDER BY / GROUP BY aliases kept
  static let maxOrderByAliases = 500

  /// Words that end a SELECT list item or a FROM source: never an implicit alias
  private static let nonAliasWords: Set<String> = [
    "AND", "OR", "NOT", "IS", "IN", "LIKE", "ILIKE", "BETWEEN", "COLLATE", "ESCAPE", "CASE",
    "WHEN", "THEN", "ELSE", "END", "NULL", "TRUE", "FALSE", "DISTINCT", "ALL", "ANY", "SOME",
    "AS", "ON", "USING", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "OUTER",
    "LATERAL", "TABLESAMPLE", "SELECT", "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT",
    "OFFSET", "UNION", "INTERSECT", "EXCEPT", "WINDOW", "INTO", "FETCH", "FOR", "RETURNING",
    "SET", "VALUES", "WITH", "ASC", "DESC", "WITHIN", "OVER", "FILTER",
  ]

  /// Clause keywords that end a SELECT list at their level
  private static let clauseWords: Set<String> = [
    "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT",
    "WINDOW", "INTO", "FETCH", "RETURNING", "VALUES", "SET",
  ]

  /// CTE columns, CTE sources and the ORDER BY / GROUP BY aliases at `cursor` (UTF-16), in one
  /// lex and one walk over the tokens with a stack of parenthesis levels: linear in the text.
  /// A CTE's columns are its explicit column list, else its body's first SELECT list (aliases,
  /// bare or qualified column names, `*` / `t.*` expanded from schema tables and CTEs defined
  /// before it).
  func statementScope(in text: String, cursor: Int, dialect: SQLDialect) -> SQLStatementScope {
    let tokens = scopeTokens(text, dialect: dialect)
    var scope = SQLStatementScope()
    var cteColumns: [String: [String]] = [:]
    var sourceNames: Set<String> = []
    var stack = [ScopeFrame()]
    var atCursor: ScopeFrame?
    var i = 0
    while i < tokens.count {
      let token = tokens[i]
      if atCursor == nil, token.offset >= cursor { atCursor = stack[stack.count - 1] }
      let top = stack.count - 1
      i += 1

      switch stack[top].with {
      case .none:
        break
      case .name:
        if token.keyword == "RECURSIVE" { continue }
        stack[top].with = token.isIdentifier ? .afterName(token.text) : .none
        if token.isIdentifier { continue }
      case .afterName(let name):
        if token.isSymbol("(") {
          stack[top].with = .columns(name, [])
          continue
        }
        stack[top].with = token.keyword == "AS" ? .body(name, nil) : .none
        if token.keyword == "AS" { continue }
      case .columns(let name, var columns):
        if token.isSymbol(")") {
          stack[top].with = .afterColumns(name, columns)
        } else if token.isIdentifier, columns.count < Self.maxCTEColumns {
          columns.append(token.text)
          stack[top].with = .columns(name, columns)
        }
        continue
      case .afterColumns(let name, let columns):
        stack[top].with = token.keyword == "AS" ? .body(name, columns) : .none
        if token.keyword == "AS" { continue }
      case .body(let name, let columns):
        if token.keyword == "NOT" || token.keyword == "MATERIALIZED" { continue }
        if token.isSymbol("(") {
          stack[top].with = .afterBody
          var body = ScopeFrame()
          body.cte = (name, columns)
          stack.append(body)
          continue
        }
        stack[top].with = .none
      case .afterBody:
        stack[top].with = token.isSymbol(",") ? .name : .none
        if token.isSymbol(",") { continue }
      }

      if token.isSymbol("(") {
        if stack[top].collecting { stack[top].item.append(token) }
        stack[top].expectSource = false
        stack.append(ScopeFrame())
        continue
      }
      if token.isSymbol(")") {
        guard stack.count > 1 else { continue }
        let frame = stack.removeLast()
        if let cte = frame.cte {
          let columns = cte.columns ?? outputColumns(of: frame, cteColumns: cteColumns)
          scope.ctes.append((cte.name, columns))
          cteColumns[cte.name.lowercased()] = columns
        }
        if stack[top - 1].collecting { stack[top - 1].item.append(token) }
        continue
      }

      if stack[top].expectSource {
        stack[top].expectSource = false
        if token.isIdentifier, !Self.isNonAliasWord(token) {
          // name(.name)* [AS] [alias]
          var name = token.text
          while i + 1 < tokens.count, tokens[i].isSymbol("."), tokens[i + 1].isIdentifier {
            name += "." + tokens[i + 1].text
            i += 2
          }
          if i < tokens.count, tokens[i].keyword == "AS" { i += 1 }
          var alias: String?
          if i < tokens.count, tokens[i].isIdentifier, !Self.isNonAliasWord(tokens[i]) {
            alias = tokens[i].text
            i += 1
          }
          sourceNames.insert(name.lowercased())
          if stack[top].selects <= 1 { stack[top].sources.append((name, alias)) }
          continue
        }
      }

      if let keyword = token.keyword {
        if keyword == "WITH" {
          stack[top].with = .name
          continue
        }
        // GROUP of `WITHIN GROUP (...)` and FROM of `IS [NOT] DISTINCT FROM` stay in the item
        let isWithinGroup = keyword == "GROUP" && i >= 2 && tokens[i - 2].keyword == "WITHIN"
        let isDistinctFrom =
          keyword == "FROM" && i >= 3 && tokens[i - 2].keyword == "DISTINCT"
          && (tokens[i - 3].keyword == "IS" || tokens[i - 3].keyword == "NOT")
        if !isWithinGroup, !isDistinctFrom,
          keyword == "SELECT" || keyword == "FROM" || Self.clauseWords.contains(keyword)
        {
          stack[top].commitItem()
          stack[top].clause = keyword
          if keyword == "SELECT" { stack[top].selects += 1 }
          if keyword == "FROM" { stack[top].expectSource = true }
          continue
        }
        if keyword == "JOIN" { stack[top].expectSource = true }
      }

      if token.isSymbol(",") {
        if stack[top].collecting {
          stack[top].commitItem()
          continue
        }
        if stack[top].clause == "FROM" { stack[top].expectSource = true }
      }
      if stack[top].collecting { stack[top].item.append(token) }
    }

    scope.referencedCTEs = sourceNames.intersection(cteColumns.keys)
    var frame = atCursor ?? stack[stack.count - 1]
    if frame.clause == "ORDER" || frame.clause == "GROUP" {
      frame.commitItem()
      scope.orderByAliases = Array(
        frame.items.lazy.compactMap { item in
          if case .named(let name, isAlias: true) = Self.selectItem(item) { name } else { nil }
        }.prefix(Self.maxOrderByAliases))
    }
    return scope
  }

  /// Column names a level's first SELECT list produces, at most `maxCTEColumns`
  private func outputColumns(of frame: ScopeFrame, cteColumns: [String: [String]]) -> [String] {
    var frame = frame
    frame.commitItem()
    var columns: [String] = []
    var sources: StarSources?
    for item in frame.items where columns.count < Self.maxCTEColumns {
      switch Self.selectItem(item) {
      case .named(let name, _):
        columns.append(name)
      case .star(let qualifier):
        if sources == nil { sources = starSources(of: frame, cteColumns: cteColumns) }
        guard let sources else { break }
        let lists = qualifier.map { sources.byReference[$0.lowercased()] ?? [] } ?? sources.all
        // Every list is non-empty, so this stops within `maxCTEColumns` appends
        for list in lists where columns.count < Self.maxCTEColumns {
          columns += list.prefix(Self.maxCTEColumns - columns.count)
        }
      case nil:
        break
      }
    }
    return columns
  }

  /// Most distinct FROM / JOIN sources of one level resolved for `*` items
  private static let maxStarSources = 200

  /// Column lists of a level's sources, in source order and by lowercased reference
  private typealias StarSources = (all: [[String]], byReference: [String: [[String]]])

  /// Each distinct source (name and reference) of a level resolved once, at most
  /// `maxStarSources`; sources without columns are dropped
  private func starSources(of frame: ScopeFrame, cteColumns: [String: [String]]) -> StarSources {
    var sources: StarSources = ([], [:])
    var seen: Set<[String]> = []
    for source in frame.sources where seen.count < Self.maxStarSources {
      let name = source.name.lowercased()
      let reference =
        (source.alias ?? String(source.name.split(separator: ".").last ?? "")).lowercased()
      guard seen.insert([name, reference]).inserted else { continue }
      let columns =
        cteColumns[name]
        ?? findMatchingTableKey(for: source.name).flatMap { columnsByTable[$0] }.map {
          $0.prefix(Self.maxCTEColumns).map(\.name)
        } ?? []
      guard !columns.isEmpty else { continue }
      sources.all.append(columns)
      sources.byReference[reference, default: []].append(columns)
    }
    return sources
  }

  /// Name of a SELECT-list item: `expr AS name`, `expr name`, `col`, `t.col`, `*`, `t.*`;
  /// nil for an unnamed expression
  private static func selectItem(_ item: [ScopeToken]) -> SelectItem? {
    var tokens = item[...]
    while let first = tokens.first, first.keyword == "DISTINCT" || first.keyword == "ALL" {
      tokens = tokens.dropFirst()
    }
    // DISTINCT ON (...) keeps only its parentheses at this level
    if tokens.count > 3, tokens.first?.keyword == "ON",
      tokens[tokens.startIndex + 1].isSymbol("("), tokens[tokens.startIndex + 2].isSymbol(")")
    {
      tokens = tokens.dropFirst(3)
    }
    guard let last = tokens.last else { return nil }
    let parts = Array(tokens)
    // name(.name)* or name(.name)*.*
    let isPath =
      parts.count % 2 == 1
      && parts.indices.allSatisfy { index in
        index % 2 == 1
          ? parts[index].isSymbol(".")
          : parts[index].isIdentifier || (index == parts.count - 1 && parts[index].isSymbol("*"))
      }
    if isPath {
      if last.isSymbol("*") {
        return .star(qualifier: parts.count > 1 ? parts[parts.count - 3].text : nil)
      }
      return .named(last.text, isAlias: false)
    }
    guard parts.count >= 2, last.isIdentifier, !isNonAliasWord(last) else { return nil }
    let previous = parts[parts.count - 2]
    if previous.keyword == "AS" { return .named(last.text, isAlias: true) }
    // Implicit alias: after a value, not after an operator or a keyword
    let endsValue =
      previous.isSymbol(")") || previous.kind == .literal || previous.kind == .quotedIdentifier
      || previous.keyword == "END" || (previous.kind == .word && !isNonAliasWord(previous))
    return endsValue ? .named(last.text, isAlias: true) : nil
  }

  private static func isNonAliasWord(_ token: ScopeToken) -> Bool {
    token.keyword.map(nonAliasWords.contains) ?? false
  }

  /// Tokens of `text` with UTF-16 offsets, per the `dialect` lexer
  private func scopeTokens(_ text: String, dialect: SQLDialect) -> [ScopeToken] {
    let scalars = Array(text.unicodeScalars)
    let tokenizer = SQLTokenizer(dialect: dialect)
    var tokens: [ScopeToken] = []
    var unit = 0
    var i = 0
    while i < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: i)
      let next = max(lexeme.range.upperBound, i + 1)
      switch lexeme.kind {
      case .whitespace, .comment:
        break
      case .word:
        let word = SQLTokenizer.text(scalars, lexeme.range)
        tokens.append(
          ScopeToken(
            kind: .word, text: word, keyword: SQLTokenizer.asciiUppercased(word), offset: unit))
      case .quoted(.quotedIdentifier, let content):
        tokens.append(
          ScopeToken(kind: .quotedIdentifier, text: content, keyword: nil, offset: unit))
      case .symbol:
        tokens.append(
          ScopeToken(
            kind: .symbol, text: SQLTokenizer.text(scalars, lexeme.range), keyword: nil,
            offset: unit))
      case .number, .quoted, .dollarString, .executableComment:
        tokens.append(ScopeToken(kind: .literal, text: "", keyword: nil, offset: unit))
      }
      for scalar in scalars[i..<next] { unit += scalar.utf16.count }
      i = next
    }
    return tokens
  }
}
