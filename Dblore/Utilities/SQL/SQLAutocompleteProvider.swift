//
//  SQLAutocompleteProvider.swift
//  Dblore
//
//  Provides autocomplete suggestions for SQL keywords, table names, and column names
//
//  NOTE: This file has been split into focused modules:
//  - SQLAutocompleteProvider+Keywords.swift (SQL keyword definitions)
//  - SQLAutocompleteProvider+ContextParsing.swift (context detection and parsing)
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
  // Schema cache (tables and columns)
  var tables: [DatabaseTable] = []
  var columnsByTable: [String: [DatabaseColumn]] = [:]  // key: "schema.table"

  // MARK: - Schema

  /// Feed the provider from the already loaded schema (tables with their columns)
  func update(tables: [DatabaseTable]) {
    self.tables = tables
    var index: [String: [DatabaseColumn]] = [:]
    index.reserveCapacity(tables.count)
    for table in tables {
      index["\(table.schema).\(table.name)"] = table.columns
    }
    columnsByTable = index
  }

  /// Clear the schema cache (10.1.4 & 10.1.8 optimization)
  func clearCache() {
    tables = []
    columnsByTable = [:]
  }

  // MARK: - Autocomplete Suggestions

  /// Get autocomplete suggestions based on current input
  /// - Parameters:
  ///   - text: Full text content
  ///   - cursorPosition: Current cursor position in text (UTF-16 offset)
  /// - Returns: Array of suggestions
  func getSuggestions(for fullText: String, at fullCursorPosition: Int) -> [AutocompleteSuggestion]
  {
    // Only the current statement matters (bounded scan, see statementWindow)
    let (text, cursorPosition) = statementWindow(in: fullText, at: fullCursorPosition)

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
}
