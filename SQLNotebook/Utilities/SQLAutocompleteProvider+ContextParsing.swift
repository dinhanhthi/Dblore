//
//  SQLAutocompleteProvider+ContextParsing.swift
//  SQLNotebook
//
//  SQL context detection and table reference extraction
//

import Foundation

// MARK: - Context Detection & Parsing

extension SQLAutocompleteProvider {
  /// Extract the current word/token being typed at cursor position
  func extractCurrentToken(from text: String, at position: Int) -> String {
    guard position > 0, position <= text.count else { return "" }

    let beforeCursor = String(text.prefix(position))
    let afterCursor = String(text.suffix(text.count - position))

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
    let textBefore = String(text.prefix(position)).uppercased()

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
  func extractTableReferences(from text: String) -> [String: String] {
    let upperText = text.uppercased()
    var tableRefs: [String: String] = [:]

    // Pattern: FROM table_name [alias] or JOIN table_name [alias]
    // We'll use a simple regex-like approach

    // Find all FROM and JOIN positions
    let keywords = [
      "FROM", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN",
    ]

    for keyword in keywords {
      var searchRange = upperText.startIndex..<upperText.endIndex

      while let range = upperText.range(of: keyword, range: searchRange) {
        // Get text after keyword (until next major keyword or end)
        let afterKeyword = upperText[range.upperBound...]
        let afterKeywordString = String(afterKeyword)

        // Extract the table reference (format: "table_name" or "table_name alias")
        // Stop at next SQL keyword or comma
        let stopKeywords = [
          "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "ON", "GROUP", "ORDER",
          "LIMIT", "UNION", "EXCEPT", "INTERSECT",
        ]
        var endIndex = afterKeywordString.endIndex

        for stopKeyword in stopKeywords {
          if let stopRange = afterKeywordString.range(of: stopKeyword) {
            let currentEnd = afterKeywordString.distance(
              from: afterKeywordString.startIndex, to: stopRange.lowerBound)
            let proposedEnd = afterKeywordString.distance(
              from: afterKeywordString.startIndex, to: endIndex)
            if currentEnd < proposedEnd {
              endIndex = stopRange.lowerBound
            }
          }
        }

        let tableRef = String(afterKeywordString[..<endIndex]).trimmingCharacters(
          in: .whitespacesAndNewlines)

        // Parse "table_name" or "table_name alias"
        // Split by whitespace, first part is table name, second part (if exists) is alias
        let parts = tableRef.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        if let tableName = parts.first, !tableName.isEmpty {
          // Find full table key from schema cache
          let matchingTableKey = findMatchingTableKey(for: tableName)

          if let tableKey = matchingTableKey {
            // Add table name itself as a reference
            tableRefs[tableName.lowercased()] = tableKey

            // If there's an alias, add it too
            if parts.count > 1 {
              let alias = parts[1]
              tableRefs[alias.lowercased()] = tableKey
            }
          }
        }

        // Move search range forward
        searchRange = range.upperBound..<upperText.endIndex
      }
    }

    return tableRefs
  }

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
