//
//  SQLSyntaxHighlighter.swift
//  Dblore
//

import AppKit
import SwiftUI

/// SQL syntax highlighter with token-based coloring
enum SQLSyntaxHighlighter {
  // MARK: - Token Types

  enum TokenType {
    case keyword
    case function
    case string
    case number
    case comment
    case `operator`
    case identifier
    case type

    var color: NSColor {
      switch self {
      case .keyword:
        return NSColor(Color.syntaxKeyword)
      case .function:
        return NSColor(Color.syntaxFunction)
      case .string:
        return NSColor(Color.syntaxString)
      case .number:
        return NSColor(Color.syntaxNumber)
      case .comment:
        return NSColor(Color.syntaxComment)
      case .operator:
        return NSColor(Color.syntaxOperator)
      case .identifier:
        return NSColor(Color.foreground)
      case .type:
        return NSColor(Color.syntaxFunction)
      }
    }
  }

  // MARK: - Keywords

  static let keywords: Set<String> = [
    // DDL
    "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
    "CONSTRAINT", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK",
    "DEFAULT", "CASCADE", "RESTRICT", "TRUNCATE",

    // DML
    "SELECT", "INSERT", "UPDATE", "DELETE", "FROM", "WHERE", "JOIN", "ON",
    "AND", "OR", "NOT", "IN", "BETWEEN", "LIKE", "ILIKE", "IS", "NULL", "AS",
    "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "UNION", "INTERSECT",
    "EXCEPT", "ALL", "DISTINCT", "INTO", "VALUES", "SET", "RETURNING",

    // Joins
    "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL",

    // Subqueries
    "EXISTS", "ANY", "SOME",

    // Case
    "CASE", "WHEN", "THEN", "ELSE", "END",

    // Transaction
    "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION", "SAVEPOINT",

    // Other
    "WITH", "RECURSIVE", "OVER", "PARTITION", "WINDOW", "FILTER",
    "ASC", "DESC", "NULLS", "FIRST", "LAST", "USING", "ONLY", "LATERAL",
    "EXPLAIN", "ANALYZE", "VERBOSE", "GRANT", "REVOKE", "TO", "ROLE",
  ]

  static let functions: Set<String> = [
    // Aggregate
    "COUNT", "SUM", "AVG", "MIN", "MAX", "ARRAY_AGG", "STRING_AGG",
    "BOOL_AND", "BOOL_OR", "BIT_AND", "BIT_OR", "EVERY",

    // String
    "CONCAT", "LENGTH", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM",
    "SUBSTRING", "REPLACE", "SPLIT_PART", "POSITION", "LEFT", "RIGHT",
    "LPAD", "RPAD", "REVERSE", "INITCAP", "REPEAT", "OVERLAY",

    // Numeric
    "ABS", "CEIL", "CEILING", "FLOOR", "ROUND", "TRUNC", "MOD",
    "POWER", "SQRT", "SIGN", "RANDOM", "LOG", "LN", "EXP",

    // Date/Time
    "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
    "DATE_TRUNC", "DATE_PART", "EXTRACT", "AGE", "INTERVAL",
    "TO_DATE", "TO_TIMESTAMP", "TO_CHAR",

    // Type conversion
    "CAST", "COALESCE", "NULLIF", "GREATEST", "LEAST",

    // JSON
    "JSON_BUILD_OBJECT", "JSON_BUILD_ARRAY", "JSON_AGG",
    "JSONB_BUILD_OBJECT", "JSONB_BUILD_ARRAY", "JSONB_AGG",
    "JSON_EXTRACT_PATH", "JSONB_EXTRACT_PATH",

    // Array
    "ARRAY_LENGTH", "ARRAY_POSITION", "ARRAY_REMOVE", "ARRAY_APPEND",
    "UNNEST", "ARRAY_TO_STRING",

    // Window
    "ROW_NUMBER", "RANK", "DENSE_RANK", "NTILE", "LAG", "LEAD",
    "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE",
  ]

  static let types: Set<String> = [
    // Numeric
    "INTEGER", "INT", "SMALLINT", "BIGINT", "SERIAL", "BIGSERIAL",
    "DECIMAL", "NUMERIC", "REAL", "DOUBLE", "PRECISION", "FLOAT",

    // Character
    "VARCHAR", "CHAR", "CHARACTER", "TEXT", "VARYING",

    // Binary
    "BYTEA", "BLOB",

    // Boolean
    "BOOLEAN", "BOOL",

    // Date/Time
    "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL",
    "TIMETZ",

    // UUID
    "UUID",

    // JSON
    "JSON", "JSONB",

    // Array
    "ARRAY",

    // Other
    "MONEY", "INET", "CIDR", "MACADDR", "BIT", "XML", "POINT",
    "LINE", "LSEG", "BOX", "PATH", "POLYGON", "CIRCLE",
  ]

  static let operators: Set<String> = [
    "=", "<>", "!=", "<", ">", "<=", ">=",
    "+", "-", "*", "/", "%", "^",
    "||", "->", "->>", "#>", "#>>",
    "@>", "<@", "?", "?|", "?&",
    "~", "~*", "!~", "!~*",
  ]

  // MARK: - Palette

  /// Colors and font resolved once per highlight pass (theme colors are computed on each access)
  struct Palette {
    let keyword = NSColor(Color.syntaxKeyword)
    let function = NSColor(Color.syntaxFunction)
    let string = NSColor(Color.syntaxString)
    let number = NSColor(Color.syntaxNumber)
    let comment = NSColor(Color.syntaxComment)
    let foreground = NSColor(Color.foreground)
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    var defaultAttributes: [NSAttributedString.Key: Any] {
      [.font: font, .foregroundColor: foreground]
    }

    func color(for type: TokenType) -> NSColor {
      switch type {
      case .keyword: return keyword
      case .function, .type: return function
      case .string: return string
      case .number: return number
      case .comment: return comment
      case .operator: return NSColor(Color.syntaxOperator)
      case .identifier: return foreground
      }
    }
  }

  // MARK: - Highlighting

  /// Returns plain text with default styling (no syntax highlighting)
  private static func plainText(_ text: String) -> NSAttributedString {
    let result = NSMutableAttributedString(string: text)
    result.addAttributes(
      Palette().defaultAttributes, range: NSRange(location: 0, length: (text as NSString).length))
    return result
  }

  static func highlight(_ text: String, dialect: SQLDialect = .postgresql) -> NSAttributedString {
    // Check if syntax highlighting is disabled
    if !AppSettings.shared.syntaxHighlightingEnabled {
      return plainText(text)
    }

    let result = NSMutableAttributedString(string: text)
    let palette = Palette()
    let full = NSRange(location: 0, length: result.length)
    result.addAttributes(palette.defaultAttributes, range: full)
    highlight(in: result, range: full, palette: palette, dialect: dialect)

    return result
  }

  /// Highlight text with both syntax highlighting and search matches
  static func highlightWithSearch(
    _ text: String,
    searchQuery: String,
    isCaseSensitive: Bool,
    currentMatchRange: NSRange?,
    dialect: SQLDialect = .postgresql
  ) -> NSAttributedString {
    // First apply syntax highlighting (or plain text if disabled)
    let result = NSMutableAttributedString(attributedString: highlight(text, dialect: dialect))

    // Then apply search highlighting on top
    guard !searchQuery.isEmpty else { return result }

    // Find all search matches
    let searchText = isCaseSensitive ? text : text.lowercased()
    let query = isCaseSensitive ? searchQuery : searchQuery.lowercased()

    var searchStartIndex = searchText.startIndex
    while let range = searchText.range(of: query, range: searchStartIndex..<searchText.endIndex) {
      let nsRange = NSRange(range, in: text)

      // Determine if this is the current match
      let isCurrentMatch = currentMatchRange != nil && nsRange == currentMatchRange

      // Apply search highlight background color
      let backgroundColor: NSColor
      if isCurrentMatch {
        // Orange-yellow for current match
        backgroundColor = NSColor(red: 1.0, green: 0.835, blue: 0.0, alpha: 1.0)  // #FFD500
      } else {
        // Dark mode: white with opacity / Light mode: gray with opacity
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        backgroundColor =
          isDarkMode
          ? NSColor.white.withAlphaComponent(0.8)
          : NSColor.gray.withAlphaComponent(0.6)
      }

      result.addAttribute(.backgroundColor, value: backgroundColor, range: nsRange)

      // Use black text for better contrast on highlight background
      result.addAttribute(.foregroundColor, value: NSColor.black, range: nsRange)

      searchStartIndex = range.upperBound
    }

    return result
  }

  // MARK: - Scanning

  static let wordRegex = try! NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_]*\\b")

  /// Possessive digit run: same matches as `\b\d+\.?\d*\b`, without quadratic backtracking
  static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d++\\.?\\d*\\b")

  /// The precompiled regexes, exposed so tests can assert they are never rebuilt per call
  static var scanRegexes: [NSRegularExpression] { [wordRegex, numberRegex] }

  // MARK: - Block Scanner

  /// Comments and strings inside `range`, in order. Linear replacement of the regex
  /// `--[^\n]*|/\*[\s\S]*?\*/|'(?:[^'\\]|\\.)*'|\$\$[\s\S]*?\$\$` (leftmost match wins, scanning
  /// resumes after each match); an unterminated `/*`, `'` or `$$` matches nothing.
  static func scanBlockSpans(
    in text: NSString, range: NSRange, dialect: SQLDialect = .postgresql
  ) -> [(range: NSRange, isComment: Bool)] {
    if dialect == .sqlite {
      return sqliteBlockSpans(in: text, range: range)
    }
    guard range.length > 0 else { return [] }
    var buffer = [unichar](repeating: 0, count: range.length)
    text.getCharacters(&buffer, range: range)
    let n = buffer.count
    let base = range.location
    var result: [(range: NSRange, isComment: Bool)] = []

    // A failed closer search from i also fails from every later start, so remember it
    var noBlockCloser = false
    var noDollarCloser = false
    // A failed string scan stopped at this index; every later quote before it fails the same way
    var stringFailsBefore = 0

    func find(_ a: unichar, _ b: unichar, from start: Int) -> Int? {
      var k = start
      while k + 1 < n {
        if buffer[k] == a && buffer[k + 1] == b { return k }
        k += 1
      }
      return nil
    }
    func isLineTerminator(_ c: unichar) -> Bool {
      c == 0x0A || c == 0x0D || c == 0x85 || c == 0x2028 || c == 0x2029
    }

    var i = 0
    while i < n {
      let c = buffer[i]
      var end: Int?
      var isComment = false
      if c == 0x2D, i + 1 < n, buffer[i + 1] == 0x2D {  // --
        var k = i + 2
        while k < n && buffer[k] != 0x0A { k += 1 }
        end = k
        isComment = true
      } else if c == 0x2F, i + 1 < n, buffer[i + 1] == 0x2A, !noBlockCloser {  // /*
        if let k = find(0x2A, 0x2F, from: i + 2) {
          end = k + 2
          isComment = true
        } else {
          noBlockCloser = true
        }
      } else if c == 0x27, i >= stringFailsBefore {  // '
        var k = i + 1
        while k < n {
          let d = buffer[k]
          if d == 0x27 {
            end = k + 1
            break
          } else if d == 0x5C {
            if k + 1 < n, !isLineTerminator(buffer[k + 1]) { k += 2 } else { break }
          } else {
            k += 1
          }
        }
        if end == nil { stringFailsBefore = k }
      } else if c == 0x24, i + 1 < n, buffer[i + 1] == 0x24, !noDollarCloser {  // $$
        if let k = find(0x24, 0x24, from: i + 2) {
          end = k + 2
        } else {
          noDollarCloser = true
        }
      }

      if let end {
        result.append((NSRange(location: base + i, length: end - i), isComment))
        i = max(end, i + 1)
      } else {
        i += 1
      }
    }
    return result
  }

  /// Comments and `'…'` strings for SQLite. Dollar quotes are not strings, and a backslash
  /// does not escape a quote. Ranges are UTF-16, matching `scanBlockSpans`.
  private static func sqliteBlockSpans(
    in text: NSString, range: NSRange
  ) -> [(range: NSRange, isComment: Bool)] {
    guard range.length > 0 else { return [] }
    let substring = text.substring(with: range)
    let scalars = Array(substring.unicodeScalars)
    var utf16At = [Int](repeating: 0, count: scalars.count + 1)
    var unit = 0
    for (index, scalar) in scalars.enumerated() {
      utf16At[index] = unit
      unit += scalar.utf16.count
    }
    utf16At[scalars.count] = unit

    let tokenizer = SQLTokenizer(dialect: .sqlite)
    var result: [(range: NSRange, isComment: Bool)] = []
    var i = 0
    while i < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: i)
      let end = lexeme.range.upperBound
      let isString: Bool
      switch lexeme.kind {
      case .comment:
        isString = false
      case .quoted(.string, _), .quoted(.backslashString, _):
        isString = true
      default:
        i = end > i ? end : i + 1
        continue
      }
      let location = range.location + utf16At[lexeme.range.lowerBound]
      let length = utf16At[end] - utf16At[lexeme.range.lowerBound]
      result.append((NSRange(location: location, length: length), !isString))
      i = end > i ? end : i + 1
    }
    return result
  }

  // MARK: - Token Highlighting

  /// Colors comments, strings, numbers, keywords, functions and types inside `range` only. The
  /// range must start and end at safe boundaries (outside any block token); the caller has set
  /// the default attributes. Words and numbers inside a comment or string are left alone.
  static func highlight(
    in storage: NSMutableAttributedString, range: NSRange, palette: Palette,
    dialect: SQLDialect = .postgresql
  ) {
    guard range.length > 0 else { return }
    let text = storage.string
    let ns = text as NSString

    // 1. Block tokens, colored first and remembered as protected spans (sorted, disjoint)
    var spans: [NSRange] = []
    for block in scanBlockSpans(in: ns, range: range, dialect: dialect) {
      storage.addAttribute(
        .foregroundColor, value: block.isComment ? palette.comment : palette.string,
        range: block.range)
      spans.append(block.range)
    }

    // 2. Numbers
    numberRegex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
      guard let r = match?.range, !isProtected(r.location, in: spans) else { return }
      storage.addAttribute(.foregroundColor, value: palette.number, range: r)
    }

    // 3. Words: type > function followed by "(" > keyword
    let rangeEnd = NSMaxRange(range)
    wordRegex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
      guard let r = match?.range, !isProtected(r.location, in: spans) else { return }
      let upper = ns.substring(with: r).uppercased()
      let isType = types.contains(upper)
      if !isType && functions.contains(upper) {
        var end = NSMaxRange(r)
        while end < ns.length, isWhitespace(ns.character(at: end)) { end += 1 }
        if end < ns.length, ns.character(at: end) == 0x28 {
          let colored = NSRange(location: r.location, length: min(end, rangeEnd) - r.location)
          storage.addAttribute(.foregroundColor, value: palette.function, range: colored)
          return
        }
      }
      if isType {
        storage.addAttribute(.foregroundColor, value: palette.function, range: r)
      } else if keywords.contains(upper) {
        storage.addAttribute(.foregroundColor, value: palette.keyword, range: r)
      }
    }
  }

  private static func isWhitespace(_ c: unichar) -> Bool {
    c == 0x20 || (0x09...0x0D).contains(c) || c == 0x85 || c == 0xA0 || c == 0x2028 || c == 0x2029
  }

  /// Binary search: is `location` inside one of the sorted, disjoint `spans`
  private static func isProtected(_ location: Int, in spans: [NSRange]) -> Bool {
    var lo = 0
    var hi = spans.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if spans[mid].location <= location { lo = mid + 1 } else { hi = mid }
    }
    return lo > 0 && location < NSMaxRange(spans[lo - 1])
  }

  // MARK: - Query Processing

  /// Remove SQL comments from a query string
  /// Handles:
  /// - Single-line comments (-- ...)
  /// - Multi-line comments (/* ... */)
  /// - Comments inside string literals are preserved
  static func removeComments(_ query: String) -> String {
    var result = ""
    var inSingleQuote = false
    var inDoubleQuote = false

    var i = query.startIndex
    while i < query.endIndex {
      let char = query[i]

      // Handle multi-line comment (/* ... */)
      if !inSingleQuote && !inDoubleQuote && char == "/" {
        let next = query.index(after: i)
        if next < query.endIndex && query[next] == "*" {
          // Find the closing */
          var j = query.index(after: next)
          var found = false
          while j < query.endIndex {
            if query[j] == "*" {
              let nextJ = query.index(after: j)
              if nextJ < query.endIndex && query[nextJ] == "/" {
                // Found closing */
                i = query.index(after: nextJ)
                found = true
                break
              }
            }
            j = query.index(after: j)
          }
          if !found {
            // Unclosed comment - skip rest of query
            break
          }
          continue
        }
      }

      // Handle single-line comment (-- ...)
      if !inSingleQuote && !inDoubleQuote && char == "-" {
        let next = query.index(after: i)
        if next < query.endIndex && query[next] == "-" {
          // Skip until newline or end of string
          var j = next
          while j < query.endIndex && query[j] != "\n" {
            j = query.index(after: j)
          }
          // If we found a newline, skip it and continue
          if j < query.endIndex {
            i = query.index(after: j)
            result.append("\n")
          } else {
            // End of string - we're done
            break
          }
          continue
        }
      }

      // Toggle single quote (handle escaped quotes)
      if char == "'" && !inDoubleQuote {
        let next = query.index(after: i)
        if inSingleQuote && next < query.endIndex && query[next] == "'" {
          // Escaped quote - add both and continue
          result.append(char)
          result.append(query[next])
          i = query.index(after: next)
          continue
        }
        inSingleQuote.toggle()
      }

      // Toggle double quote
      if char == "\"" && !inSingleQuote {
        inDoubleQuote.toggle()
      }

      // Add character to result
      result.append(char)
      i = query.index(after: i)
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
