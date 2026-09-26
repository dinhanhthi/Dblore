//
//  DatabaseConnectionManager+QueryParsing.swift
//  SQLNotebook
//
//  Query parsing and analysis helpers
//

import Foundation

extension DatabaseConnectionManager {
  // MARK: - Query Type Detection

  /// Strip leading comments from a query
  /// Removes single-line (--) and multi-line (/* */) comments from the beginning
  private nonisolated func stripLeadingComments(_ query: String) -> String {
    var result = query
    var changed = true

    while changed {
      changed = false
      let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)

      // Remove single-line comment
      if trimmed.hasPrefix("--") {
        if let newlineRange = trimmed.range(of: "\n") {
          result = String(trimmed[newlineRange.upperBound...])
          changed = true
        } else {
          // Comment extends to end of string
          return ""
        }
      }
      // Remove multi-line comment
      else if trimmed.hasPrefix("/*") {
        if let endRange = trimmed.range(of: "*/") {
          result = String(trimmed[endRange.upperBound...])
          changed = true
        } else {
          // Unclosed comment
          return ""
        }
      }
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Strip all comments from a query (not just leading)
  /// Removes single-line (--) and multi-line (/* */) comments from anywhere in the query
  /// Preserves string literals
  nonisolated func stripAllComments(_ query: String) -> String {
    var result = ""
    var inSingleQuote = false
    var inDoubleQuote = false
    var inSingleLineComment = false
    var inMultiLineComment = false

    var i = query.startIndex
    while i < query.endIndex {
      let char = query[i]

      // Handle single-line comment start
      if !inSingleQuote && !inDoubleQuote && !inMultiLineComment && char == "-" {
        let next = query.index(after: i)
        if next < query.endIndex && query[next] == "-" {
          inSingleLineComment = true
          i = next
          i = query.index(after: i)
          continue
        }
      }

      // End single-line comment at newline
      if inSingleLineComment {
        if char == "\n" {
          inSingleLineComment = false
          result.append(char)  // Keep the newline
        }
        i = query.index(after: i)
        continue
      }

      // Handle multi-line comment start
      if !inSingleQuote && !inDoubleQuote && !inSingleLineComment && char == "/" {
        let next = query.index(after: i)
        if next < query.endIndex && query[next] == "*" {
          inMultiLineComment = true
          i = next
          i = query.index(after: i)
          continue
        }
      }

      // End multi-line comment
      if inMultiLineComment {
        if char == "*" {
          let next = query.index(after: i)
          if next < query.endIndex && query[next] == "/" {
            inMultiLineComment = false
            i = query.index(after: next)
            continue
          }
        }
        i = query.index(after: i)
        continue
      }

      // Toggle quotes (outside comments)
      if char == "'" && !inDoubleQuote {
        let next = query.index(after: i)
        if inSingleQuote && next < query.endIndex && query[next] == "'" {
          // Escaped quote
          result.append(char)
          result.append(query[next])
          i = query.index(after: next)
          continue
        }
        inSingleQuote.toggle()
      }

      if char == "\"" && !inSingleQuote {
        inDoubleQuote.toggle()
      }

      // Add character to result
      result.append(char)
      i = query.index(after: i)
    }

    return result
  }

  /// Check if a query is a SELECT statement
  nonisolated func isSelectQuery(_ query: String) -> Bool {
    let withoutLeadingComments = stripLeadingComments(query)
    return withoutLeadingComments.uppercased().hasPrefix("SELECT")
  }

  /// True for a plain INSERT / UPDATE / DELETE, whose affected row count is read through
  /// `wrapModificationQueryForCount`. Uses the tokenizer, so leading comments are skipped.
  nonisolated func countsAffectedRows(_ query: String) -> Bool {
    let first = SQLTokenizer.tokens(query).first?.keyword ?? ""
    return ["INSERT", "UPDATE", "DELETE"].contains(first)
  }

  // MARK: - LIMIT Clause Detection

  /// Check if a query already has a LIMIT clause
  func hasLimitClause(_ query: String) -> Bool {
    // Strip comments first to avoid false positives from LIMIT in comments
    let withoutComments = stripAllComments(query)
    let normalized = withoutComments.lowercased()
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
  nonisolated func extractLimitValue(_ query: String) -> Int? {
    // Strip comments first to avoid false positives from LIMIT in comments
    let withoutComments = stripAllComments(query)

    // Remove semicolons and trim
    let cleaned = withoutComments.replacingOccurrences(of: ";", with: "").trimmingCharacters(
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
    let normalized =
      query
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

  // MARK: - Multiple Statement Parsing

  /// Split SQL string into individual statements
  /// Delegates to `SQLTokenizer.splitStatements` (quotes, E-strings, dollar quotes, comments)
  /// Returns array of trimmed SQL statements
  nonisolated func splitSQLStatements(_ sql: String) -> [String] {
    SQLTokenizer.splitStatements(sql)
  }

  /// Check if a SQL string contains multiple statements
  nonisolated func hasMultipleStatements(_ sql: String) -> Bool {
    return splitSQLStatements(sql).count > 1
  }

  /// Check if a SQL statement contains only comments and whitespace
  /// Returns true if the statement has no executable SQL code.
  /// Delegates to `SQLTokenizer.tokens`, which drops whitespace and (nested) comments.
  nonisolated func isCommentOnlyStatement(_ sql: String) -> Bool {
    SQLTokenizer.tokens(sql).isEmpty
  }
}
