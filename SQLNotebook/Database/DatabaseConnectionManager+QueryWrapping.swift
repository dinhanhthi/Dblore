//
//  DatabaseConnectionManager+QueryWrapping.swift
//  SQLNotebook
//
//  Query wrapping and transformation helpers
//

import Foundation
import Logging
import PostgresNIO

extension DatabaseConnectionManager {
  // MARK: - Modification Query Wrapping

  /// Wrap a modification query (UPDATE/DELETE/INSERT) to return affected row count
  /// Uses WITH (CTE) to capture the affected rows and count them
  /// This is necessary because PostgresNIO 1.30.1 doesn't expose commandTag in public API
  func wrapModificationQueryForCount(_ query: String) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let upperQuery = trimmed.uppercased()

    // Remove trailing semicolon if present
    let cleanQuery = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed

    // For UPDATE, DELETE, and INSERT, we can use RETURNING to get affected rows
    if upperQuery.hasPrefix("UPDATE") || upperQuery.hasPrefix("DELETE")
      || upperQuery.hasPrefix("INSERT")
    {
      // Wrap with CTE and count
      return """
        WITH affected AS (
          \(cleanQuery) RETURNING 1
        )
        SELECT COUNT(*) FROM affected;
        """
    }

    // Fallback (shouldn't happen if isModificationQuery is correct)
    return cleanQuery
  }

  // MARK: - LIMIT Wrapping

  /// Wrap a SELECT query with LIMIT clause to prevent fetching too many rows
  /// Enforces maxRows limit even if the query already has a LIMIT clause
  func wrapQueryWithLimit(_ query: String, maxRows: Int) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    // Don't wrap if it's not a SELECT query
    if !isSelectQuery(trimmed) {
      return trimmed
    }

    // Don't wrap if it's a SELECT without FROM clause (e.g., SELECT pg_sleep(3), SELECT now())
    // These queries call functions and don't return table data
    if !hasFromClause(trimmed) {
      return trimmed
    }

    // Check if query already has a LIMIT clause
    if hasLimitClause(trimmed) {
      // Replace existing LIMIT with min(userLimit, maxRows)
      return replaceLimitValue(trimmed, maxRows: maxRows)
    }

    // No LIMIT clause - append LIMIT maxRows
    return "\(trimmed) LIMIT \(maxRows)"
  }

  /// Replace LIMIT value in query with maxRows if user's LIMIT exceeds it
  /// If user's LIMIT is less than maxRows, keep the user's LIMIT
  func replaceLimitValue(_ query: String, maxRows: Int) -> String {
    // Extract user's LIMIT value
    guard let userLimit = extractLimitValue(query) else {
      return query
    }

    // If user's LIMIT is already within maxRows, keep it as-is
    if userLimit <= maxRows {
      return query
    }

    // User's LIMIT exceeds maxRows, replace it with maxRows
    let pattern = "\\bLIMIT\\s+\\d+"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return query
    }

    let nsRange = NSRange(query.startIndex..., in: query)
    let modifiedQuery = regex.stringByReplacingMatches(
      in: query,
      options: [],
      range: nsRange,
      withTemplate: "LIMIT \(maxRows)"
    )

    return modifiedQuery
  }

  // MARK: - CTID Wrapping

  /// Wrap a SELECT query to include ctid as an aliased column
  /// Note: This only works for simple SELECT * FROM table queries
  /// For complex queries (joins, subqueries, etc.), ctid won't be available
  func wrapQueryWithCtid(_ query: String) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    // Only process if query starts with "SELECT * FROM"
    guard trimmed.uppercased().hasPrefix("SELECT * FROM") else {
      return query
    }

    let upperQuery = trimmed.uppercased()

    // Skip queries with JOINs - ctid would be ambiguous (which table's ctid?)
    if upperQuery.contains(" JOIN ") || upperQuery.contains(" INNER JOIN ")
      || upperQuery.contains(" LEFT JOIN ") || upperQuery.contains(" RIGHT JOIN ")
      || upperQuery.contains(" FULL JOIN ") || upperQuery.contains(" CROSS JOIN ")
    {
      return query
    }

    // Skip queries with subqueries - ctid cannot be used with subquery aliases
    // Check for subquery patterns: (SELECT ... FROM ...) AS alias
    if upperQuery.contains("(SELECT") {
      return query
    }

    // Skip queries with UNION/INTERSECT/EXCEPT - ctid not meaningful for set operations
    if upperQuery.contains(" UNION ") || upperQuery.contains(" INTERSECT ")
      || upperQuery.contains(" EXCEPT ")
    {
      return query
    }

    // Safe to add ctid for simple SELECT * FROM table queries
    return trimmed.replacingOccurrences(
      of: "SELECT *",
      with: "SELECT *, ctid AS _sqlnb_ctid",
      options: [.caseInsensitive],
      range: trimmed.startIndex..<trimmed.index(trimmed.startIndex, offsetBy: 8)
    )
  }

  // MARK: - Column Type Enrichment

  /// Enrich column type information with modifiers (precision, scale, length)
  /// Uses information_schema to get detailed type info
  func enrichColumnTypes(columns: [ColumnInfo], query: String) async -> [ColumnInfo] {
    // Only proceed if we have columns and connection
    guard !columns.isEmpty, let connection = _connection, databaseType == .postgresql else {
      return columns
    }

    // Try to extract table name from query (simple SELECT from single table)
    guard let tableName = extractSingleTableName(query) else {
      return columns
    }

    do {
      // Build IN clause with column names
      let columnNames = columns.map { "'\($0.name)'" }.joined(separator: ", ")

      // Query information_schema to get detailed column types
      let typeQuery = """
        SELECT column_name, data_type,
               character_maximum_length,
               numeric_precision,
               numeric_scale,
               datetime_precision,
               interval_type
        FROM information_schema.columns
        WHERE table_name = '\(tableName)'
          AND column_name IN (\(columnNames))
        """

      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: typeQuery),
        logger: Logger(label: "sqlnotebook.typeinfo")
      )

      // Collect type information
      var typeMap: [String: String] = [:]

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()
        guard randomAccess.count >= 7 else { continue }

        // Extract values
        var cellValues: [PostgresCell] = []
        for cell in randomAccess {
          cellValues.append(cell)
        }

        guard let columnName = try? cellValues[0].decode(String.self, context: .default),
          let dataType = try? cellValues[1].decode(String.self, context: .default)
        else {
          continue
        }

        // Build detailed type string
        var detailedType = dataType.uppercased()

        // Add length for character types
        if let maxLength = try? cellValues[2].decode(Int.self, context: .default) {
          detailedType += "(\(maxLength))"
        }
        // Add precision and scale for numeric types
        else if let precision = try? cellValues[3].decode(Int.self, context: .default) {
          if let scale = try? cellValues[4].decode(Int.self, context: .default) {
            detailedType += "(\(precision),\(scale))"
          } else {
            detailedType += "(\(precision))"
          }
        }
        // Add precision for datetime types
        else if let datetimePrecision = try? cellValues[5].decode(Int.self, context: .default) {
          // For timestamp types, check if it's WITH/WITHOUT TIME ZONE
          if dataType.uppercased().contains("TIMESTAMP") {
            if dataType.uppercased().contains("WITH TIME ZONE") {
              detailedType = "TIMESTAMP(\(datetimePrecision)) W TZ"
            } else {
              detailedType = "TIMESTAMP(\(datetimePrecision)) W/O TZ"
            }
          }
        }

        typeMap[columnName] = detailedType
      }

      // Update columns with enriched type info
      return columns.map { column in
        if let enrichedType = typeMap[column.name] {
          return ColumnInfo(name: column.name, type: enrichedType)
        }
        return column
      }

    } catch {
      // If enrichment fails, return original columns
      await AppLogger.shared.warning("Failed to enrich column types: \(error)", category: "Database")
      return columns
    }
  }
}
