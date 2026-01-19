//
//  DatabaseConnectionManager+QueryParsing.swift
//  SQLNotebook
//
//  Query parsing and analysis helpers
//

import Foundation

extension DatabaseConnectionManager {
  // MARK: - Query Type Detection

  /// Check if a query is a SELECT statement
  func isSelectQuery(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.uppercased().hasPrefix("SELECT")
  }

  /// Check if a query is a data modification statement (UPDATE, DELETE, INSERT)
  func isModificationQuery(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return trimmed.hasPrefix("UPDATE") || trimmed.hasPrefix("DELETE") || trimmed.hasPrefix("INSERT")
  }

  // MARK: - LIMIT Clause Detection

  /// Check if a query already has a LIMIT clause
  func hasLimitClause(_ query: String) -> Bool {
    let normalized = query.lowercased()
    // Use regex to find LIMIT as a separate word (not part of another word)
    return normalized.range(of: "\\blimit\\b", options: .regularExpression) != nil
  }

  /// Check if a query has a FROM clause
  /// Queries without FROM clause are typically function calls like SELECT pg_sleep(3), SELECT now()
  func hasFromClause(_ query: String) -> Bool {
    let normalized = query.lowercased()
    // Use regex to find FROM as a separate word (not part of another word)
    return normalized.range(of: "\\bfrom\\b", options: .regularExpression) != nil
  }

  /// Extract LIMIT value from a query (returns nil if no LIMIT or cannot parse)
  func extractLimitValue(_ query: String) -> Int? {
    // Remove semicolons and trim
    let cleaned = query.replacingOccurrences(of: ";", with: "").trimmingCharacters(
      in: .whitespacesAndNewlines)
    let normalized = cleaned.lowercased()

    // Pattern: LIMIT <number> (may have whitespace, semicolon, or end of string after)
    let pattern = "\\blimit\\s+(\\d+)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
      let match = regex.firstMatch(
        in: normalized, options: [], range: NSRange(normalized.startIndex..., in: normalized)),
      match.numberOfRanges > 1,
      let numberRange = Range(match.range(at: 1), in: normalized)
    else {
      return nil
    }

    let numberString = String(normalized[numberRange])
    return Int(numberString)
  }

  // MARK: - Table Name Extraction

  /// Extract single table name from a simple SELECT query
  /// Returns nil for complex queries (JOINs, subqueries, CTEs)
  func extractSingleTableName(_ query: String) -> String? {
    // Normalize query for parsing
    let normalized = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .lowercased()

    // Only handle SELECT queries
    guard normalized.hasPrefix("select") else {
      return nil
    }

    // Check for disqualifying patterns (complex queries)
    let complexPatterns = [
      "\\bjoin\\b",  // Any type of JOIN
      "\\bunion\\b",  // UNION queries
      "\\bwith\\b",  // CTEs
      "\\bexcept\\b",  // EXCEPT queries
      "\\bintersect\\b",  // INTERSECT queries
    ]

    for pattern in complexPatterns {
      if normalized.range(of: pattern, options: .regularExpression) != nil {
        return nil  // Complex query - skip enrichment
      }
    }

    // Check for subqueries in FROM clause
    if normalized.range(of: "from\\s*\\(", options: .regularExpression) != nil {
      return nil  // Subquery in FROM - skip enrichment
    }

    // Extract table name from FROM clause
    // Pattern: FROM <table_name> [optional: WHERE, GROUP BY, ORDER BY, LIMIT, etc.]
    // Note: This regex handles schema-qualified names like "public.users"
    let fromPattern = "\\bfrom\\s+([a-z_][a-z0-9_]*(?:\\.[a-z_][a-z0-9_]*)?)(?:\\s|\\(|$)"

    guard
      let regex = try? NSRegularExpression(pattern: fromPattern, options: []),
      let match = regex.firstMatch(
        in: normalized, options: [], range: NSRange(normalized.startIndex..., in: normalized)),
      match.numberOfRanges > 1,
      let tableRange = Range(match.range(at: 1), in: normalized)
    else {
      return nil
    }

    let tableName = String(normalized[tableRange])

    // Validate table name (exclude SQL keywords that might be misdetected)
    let sqlKeywords = [
      "select", "where", "group", "order", "having", "limit",
      "offset", "union", "except", "intersect",
    ]
    if sqlKeywords.contains(tableName) {
      return nil
    }

    return tableName
  }

  // MARK: - Command Tag Parsing

  /// Parse affected rows count from PostgreSQL commandTag
  /// NOTE: This is for future use when PostgresNIO exposes commandTag
  /// CommandTag format examples:
  /// - "UPDATE 5" -> 5 rows affected
  /// - "DELETE 3" -> 3 rows affected
  /// - "INSERT 0 1" -> 1 row inserted (oid is 0)
  func parseAffectedRows(from commandTag: String) -> Int? {
    let parts = commandTag.split(separator: " ")

    // For INSERT: "INSERT oid rows" - we want the last part (rows)
    // For UPDATE/DELETE: "UPDATE rows" or "DELETE rows" - we want the last part
    if let last = parts.last, let count = Int(last) {
      return count
    }

    return nil
  }
}
