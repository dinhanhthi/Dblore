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
  /// - Parameter position: cursor as a UTF-16 offset
  /// - Returns: the window text and the cursor as a UTF-16 offset inside it
  func statementWindow(
    in text: String, at position: Int, dialect: SQLDialect = .postgresql
  ) -> (text: String, cursor: Int) {
    if dialect == .sqlite {
      return sqliteStatementWindow(in: text, at: position)
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
  /// identifier is not a statement boundary. The scan is still capped at `maxStatementWindow`.
  private func sqliteStatementWindow(
    in text: String, at position: Int
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
    let tokenizer = SQLTokenizer(dialect: .sqlite)
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
