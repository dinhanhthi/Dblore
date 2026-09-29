//
//  SQLSyntaxHighlighter.swift
//  SQLNotebook
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

  // MARK: - Highlighting

  /// Returns plain text with default styling (no syntax highlighting)
  private static func plainText(_ text: String) -> NSAttributedString {
    let result = NSMutableAttributedString(string: text)
    let defaultAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      .foregroundColor: NSColor(Color.foreground),
    ]
    result.addAttributes(defaultAttributes, range: NSRange(location: 0, length: text.count))
    return result
  }

  static func highlight(_ text: String) -> NSAttributedString {
    // Check if syntax highlighting is disabled
    if !AppSettings.shared.syntaxHighlightingEnabled {
      return plainText(text)
    }

    let result = NSMutableAttributedString(string: text)

    // Default attributes
    let defaultAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      .foregroundColor: NSColor(Color.foreground),
    ]
    result.addAttributes(defaultAttributes, range: NSRange(location: 0, length: text.count))

    // Apply highlighting
    applyPatterns(to: result, text: text)

    return result
  }

  /// Highlight text with both syntax highlighting and search matches
  static func highlightWithSearch(
    _ text: String,
    searchQuery: String,
    isCaseSensitive: Bool,
    currentMatchRange: NSRange?
  ) -> NSAttributedString {
    // First apply syntax highlighting (or plain text if disabled)
    let result = NSMutableAttributedString(attributedString: highlight(text))

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

  // MARK: - Token Highlighting

  /// Patterns in application order; later ones skip matches already colored as comment/string.
  /// Compiled once: building them per call (one regex per keyword) dominated every keystroke,
  /// undo and redo.
  private static let patterns: [(regex: NSRegularExpression, type: TokenType)] = [
    (regex("--[^\n]*"), .comment),
    (regex("/\\*[\\s\\S]*?\\*/"), .comment),
    (regex("'(?:[^'\\\\]|\\\\.)*'"), .string),
    (regex("\\$\\$[\\s\\S]*?\\$\\$"), .string),
    (regex("\\b\\d+\\.?\\d*\\b"), .number),
  ]

  /// Words are looked up in the keyword/function/type sets instead of matching one big
  /// alternation per set, which is several times slower on long text.
  private static let wordRegex = regex("\\w+")

  private static func regex(_ pattern: String) -> NSRegularExpression {
    // Force-try: the patterns are static and valid
    try! NSRegularExpression(pattern: pattern)
  }

  private static func applyPatterns(to attributed: NSMutableAttributedString, text: String) {
    // Resolve each color once per call (NSColor(Color) is not free)
    let commentColor = TokenType.comment.color
    let stringColor = TokenType.string.color
    let range = NSRange(text.startIndex..., in: text)

    /// Color `range` unless it already is a comment or string (those are applied first)
    func apply(_ color: NSColor, _ type: TokenType, _ range: NSRange) {
      var existingColor: NSColor?
      attributed.enumerateAttribute(.foregroundColor, in: range, options: []) { value, _, _ in
        existingColor = value as? NSColor
      }
      if type == .comment || type == .string
        || (existingColor != commentColor && existingColor != stringColor)
      {
        attributed.addAttribute(.foregroundColor, value: color, range: range)
      }
    }

    for (regex, type) in patterns {
      let color = type == .comment ? commentColor : type == .string ? stringColor : type.color
      for match in regex.matches(in: text, options: [], range: range) {
        apply(color, type, match.range)
      }
    }

    // Keywords, then functions (word + whitespace before "("), then types override
    let keywordColor = TokenType.keyword.color
    let functionColor = TokenType.function.color
    let typeColor = TokenType.type.color
    let nsText = text as NSString
    for match in wordRegex.matches(in: text, options: [], range: range) {
      let word = nsText.substring(with: match.range).uppercased()
      if keywords.contains(word) { apply(keywordColor, .keyword, match.range) }
      if functions.contains(word) {
        var end = match.range.upperBound
        while end < nsText.length,
          let scalar = UnicodeScalar(nsText.character(at: end)),
          CharacterSet.whitespacesAndNewlines.contains(scalar)
        {
          end += 1
        }
        if end < nsText.length, nsText.character(at: end) == 0x28 {  // "("
          apply(
            functionColor, .function,
            NSRange(location: match.range.location, length: end - match.range.location))
        }
      }
      if types.contains(word) { apply(typeColor, .type, match.range) }
    }
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
