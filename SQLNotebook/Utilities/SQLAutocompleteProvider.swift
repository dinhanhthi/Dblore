//
//  SQLAutocompleteProvider.swift
//  SQLNotebook
//
//  Provides autocomplete suggestions for SQL keywords, table names, and column names
//

import Foundation

// MARK: - Autocomplete Suggestion Types

enum AutocompleteSuggestionType {
  case keyword
  case table
  case column(tableName: String)
}

struct AutocompleteSuggestion: Identifiable, Equatable {
  let id = UUID()
  let text: String
  let type: AutocompleteSuggestionType
  let description: String?

  static func == (lhs: AutocompleteSuggestion, rhs: AutocompleteSuggestion) -> Bool {
    lhs.text == rhs.text
  }
}

// MARK: - SQL Autocomplete Provider

@MainActor
class SQLAutocompleteProvider {
  // Common SQL keywords (PostgreSQL focus but covers standard SQL)
  private static let sqlKeywords: [String] = [
    // DML (Data Manipulation Language)
    "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
    "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN",
    "ON", "AND", "OR", "NOT", "IN", "EXISTS", "BETWEEN", "LIKE", "ILIKE",
    "IS NULL", "IS NOT NULL", "AS", "DISTINCT", "ALL",

    // Aggregation & Grouping
    "GROUP BY", "HAVING", "ORDER BY", "ASC", "DESC", "LIMIT", "OFFSET",
    "COUNT", "SUM", "AVG", "MIN", "MAX",

    // DDL (Data Definition Language)
    "CREATE", "CREATE TABLE", "CREATE INDEX", "CREATE VIEW",
    "ALTER", "ALTER TABLE", "DROP", "DROP TABLE", "TRUNCATE",

    // DCL (Data Control Language)
    "GRANT", "REVOKE",

    // Transaction Control
    "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT",

    // Data Types
    "INTEGER", "BIGINT", "SMALLINT", "SERIAL", "BIGSERIAL",
    "VARCHAR", "TEXT", "CHAR", "CHARACTER VARYING",
    "BOOLEAN", "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ",
    "NUMERIC", "DECIMAL", "REAL", "DOUBLE PRECISION",
    "JSON", "JSONB", "UUID", "BYTEA", "ARRAY",

    // Constraints
    "PRIMARY KEY", "FOREIGN KEY", "REFERENCES", "UNIQUE", "NOT NULL",
    "CHECK", "DEFAULT", "CASCADE",

    // Window Functions
    "OVER", "PARTITION BY", "ROW_NUMBER", "RANK", "DENSE_RANK",
    "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE",

    // CTEs and Subqueries
    "WITH", "RECURSIVE", "UNION", "UNION ALL", "INTERSECT", "EXCEPT",

    // PostgreSQL Specific
    "RETURNING", "CONFLICT", "DO NOTHING", "DO UPDATE",
    "LATERAL", "TABLESAMPLE", "MATERIALIZED", "REFRESH",
    "CONCURRENTLY", "IF EXISTS", "IF NOT EXISTS",

    // Case & Casting
    "CASE", "WHEN", "THEN", "ELSE", "END", "CAST", "::text", "::integer",

    // String Functions
    "CONCAT", "LENGTH", "LOWER", "UPPER", "TRIM", "SUBSTRING",

    // Date Functions
    "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
    "EXTRACT", "DATE_TRUNC", "INTERVAL",

    // NULL Handling
    "COALESCE", "NULLIF",

    // Logical
    "TRUE", "FALSE", "NULL",
  ]

  // Schema cache (tables and columns)
  private var tables: [DatabaseTable] = []
  private var columnsByTable: [String: [DatabaseColumn]] = [:]  // key: "schema.table"

  // Current connection manager reference
  private weak var connectionManager: DatabaseConnectionManager?

  // MARK: - Initialization

  func setConnectionManager(_ manager: DatabaseConnectionManager?) {
    connectionManager = manager
  }

  // MARK: - Schema Fetching

  /// Fetch schema metadata (tables and columns) from the database
  func refreshSchema() async {
    guard let manager = connectionManager else { return }

    // Check if connected
    let isConnected = await manager.isConnected
    guard isConnected else {
      tables = []
      columnsByTable = [:]
      return
    }

    do {
      // Fetch all tables
      let fetchedTables = try await manager.fetchTables()
      tables = fetchedTables

      // Fetch columns for each table (limit to first 50 tables to avoid slowdown)
      var newColumnsCache: [String: [DatabaseColumn]] = [:]
      for table in fetchedTables.prefix(50) {
        do {
          let columns = try await manager.fetchColumns(
            tableSchema: table.schema, tableName: table.name)
          let key = "\(table.schema).\(table.name)"
          newColumnsCache[key] = columns
        } catch {
          // Skip tables we can't fetch columns for
          await AppLogger.shared.warning("Failed to fetch columns for \(table.schema).\(table.name): \(error)", category: "Autocomplete")
        }
      }
      columnsByTable = newColumnsCache

    } catch {
      await AppLogger.shared.error("Failed to refresh schema: \(error)", category: "Autocomplete")
    }
  }

  // MARK: - Autocomplete Suggestions

  /// Get autocomplete suggestions based on current input
  /// - Parameters:
  ///   - text: Full text content
  ///   - cursorPosition: Current cursor position in text
  /// - Returns: Array of suggestions
  func getSuggestions(for text: String, at cursorPosition: Int) -> [AutocompleteSuggestion] {
    // Find the word being typed (token at cursor position)
    let token = extractCurrentToken(from: text, at: cursorPosition)

    // If token is empty or too short, don't show suggestions
    guard !token.isEmpty else { return [] }

    var suggestions: [AutocompleteSuggestion] = []

    // Add keyword suggestions
    let keywordMatches = Self.sqlKeywords.filter { keyword in
      keyword.lowercased().hasPrefix(token.lowercased())
    }
    suggestions += keywordMatches.map { keyword in
      AutocompleteSuggestion(text: keyword, type: .keyword, description: "SQL Keyword")
    }

    // Add table suggestions
    let tableMatches = tables.filter { table in
      table.name.lowercased().hasPrefix(token.lowercased())
    }
    suggestions += tableMatches.map { table in
      AutocompleteSuggestion(
        text: table.name,
        type: .table,
        description: "Table (\(table.schema))"
      )
    }

    // Add column suggestions (context-aware)
    // Try to be smart: if we're after FROM/JOIN, prioritize tables
    // If we're after SELECT/WHERE, prioritize columns
    let context = detectContext(in: text, before: cursorPosition)

    if context != .afterFromOrJoin {
      // Extract table references from FROM/JOIN clauses
      let tableRefs = extractTableReferences(from: text)

      if !tableRefs.isEmpty {
        // We have table context - only show columns from referenced tables
        for (_, tableKey) in tableRefs {
          if let columns = columnsByTable[tableKey] {
            let columnMatches = columns.filter { column in
              column.name.lowercased().hasPrefix(token.lowercased())
            }
            suggestions += columnMatches.map { column in
              AutocompleteSuggestion(
                text: column.name,
                type: .column(tableName: tableKey),
                description: "\(column.type) (\(tableKey))"
              )
            }
          }
        }
      } else {
        // No table context - show columns from all tables (fallback)
        for (tableKey, columns) in columnsByTable {
          let columnMatches = columns.filter { column in
            column.name.lowercased().hasPrefix(token.lowercased())
          }
          suggestions += columnMatches.map { column in
            AutocompleteSuggestion(
              text: column.name,
              type: .column(tableName: tableKey),
              description: "\(column.type) (\(tableKey))"
            )
          }
        }
      }
    }

    // Sort by relevance: exact matches first, then alphabetically
    suggestions.sort { lhs, rhs in
      let lhsExact = lhs.text.lowercased() == token.lowercased()
      let rhsExact = rhs.text.lowercased() == token.lowercased()

      if lhsExact != rhsExact {
        return lhsExact
      }

      // Prioritize shorter matches (more specific)
      if lhs.text.count != rhs.text.count {
        return lhs.text.count < rhs.text.count
      }

      return lhs.text.lowercased() < rhs.text.lowercased()
    }

    // Limit to 20 suggestions to keep popup manageable
    return Array(suggestions.prefix(20))
  }

  // MARK: - Helper Methods

  /// Extract the current word/token being typed at cursor position
  private func extractCurrentToken(from text: String, at position: Int) -> String {
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
  private func detectContext(in text: String, before position: Int) -> SQLContext {
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
  private func extractTableReferences(from text: String) -> [String: String] {
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
  private func findMatchingTableKey(for tableName: String) -> String? {
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
