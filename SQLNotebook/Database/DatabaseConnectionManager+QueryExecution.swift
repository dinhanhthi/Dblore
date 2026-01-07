//
//  DatabaseConnectionManager+QueryExecution.swift
//  SQLNotebook
//
//  Query execution methods for DatabaseConnectionManager
//

import Foundation
import Logging
import PostgresNIO

extension DatabaseConnectionManager {
  // MARK: - Query Execution

  /// Execute a SQL query and return results
  /// - Parameters:
  ///   - query: The SQL query to execute
  ///   - maxRows: Maximum number of rows to fetch (defaults to defaultMaxFetchRows)
  func executeQuery(_ query: String, maxRows: Int = defaultMaxFetchRows) async throws -> QueryResult
  {
    guard let connection = _connection else {
      throw DatabaseError.notConnected
    }

    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DatabaseError.emptyQuery
    }

    // DEBUG: Log sanitized query before execution (redact sensitive data)
    let sanitizedQuery = AppLogger.shared.sanitizeQuery(query)
    await AppLogger.shared.debug("About to execute query: `\(sanitizedQuery)` (maxRows: \(maxRows))", category: "Database")

    let startTime = Date()

    // Check if this is a modification query (UPDATE, DELETE, INSERT)
    let isModification = isModificationQuery(query)

    // For modification queries, we need to get affected rows count
    if isModification {
      do {
        // NOTE: PostgresNIO 1.30.1 does not expose commandTag via onMetadata callback
        // The onMetadata parameter is not available in the current version
        // Solution: Use CTE with RETURNING to get affected rows count
        // This is reliable and works across all PostgreSQL versions (8.2+)
        let wrappedQuery = wrapModificationQueryForCount(query)

        let stream = try await connection.query(
          PostgresQuery(unsafeSQL: wrappedQuery),
          logger: Logger(label: "sqlnotebook")
        )

        // The wrapped query returns a single row with count
        var affectedRows = 0
        for try await row in stream {
          let randomAccess = row.makeRandomAccess()
          // Get the first column which contains the count
          if let cell = randomAccess.first {
            if let count = try? cell.decode(Int64.self, context: .default) {
              affectedRows = Int(count)
            }
          }
        }

        let executionTime = Date().timeIntervalSince(startTime)

        return QueryResult(
          columns: [],
          rows: [],
          rowCount: 0,
          executionTime: executionTime,
          affectedRows: affectedRows
        )

      } catch let error as PSQLError {
        let executionTime = Date().timeIntervalSince(startTime)
        let errorMessage = formatPostgresError(error, query: query)
        throw DatabaseError.queryFailed(errorMessage, executionTime)
      } catch {
        let executionTime = Date().timeIntervalSince(startTime)
        throw DatabaseError.queryFailed(error.localizedDescription, executionTime)
      }
    }

    // For SELECT queries, proceed with normal logic
    // Check if user specified a LIMIT that exceeds maxRows
    let userRequestedLimit = extractLimitValue(query)
    let userLimitExceeded =
      if let userLimit = userRequestedLimit {
        userLimit > maxRows
      } else {
        false
      }

    // Step 1: Wrap query with LIMIT to enforce maxRows
    // This prevents database from processing too many rows
    let limitedQuery = wrapQueryWithLimit(query, maxRows: maxRows)

    // Step 2: For PostgreSQL SELECT queries, wrap to include ctid
    let shouldFetchCtid = databaseType == .postgresql && isSelectQuery(limitedQuery)
    let executionQuery = shouldFetchCtid ? wrapQueryWithCtid(limitedQuery) : limitedQuery

    // DEBUG: Log sanitized final query (redact sensitive data)
    let sanitizedExecutionQuery = AppLogger.shared.sanitizeQuery(executionQuery)
    await AppLogger.shared.debug("Final query to be sent to database: `\(sanitizedExecutionQuery)`", category: "Database")

    do {
      // Execute query and collect rows
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: executionQuery),
        logger: Logger(label: "sqlnotebook")
      )

      var columns: [ColumnInfo] = []
      var resultRows: [[CellValue]] = []
      var rowIdentifiers: [CellValue] = []
      var isFirstRow = true

      var wasLimited = false
      var ctidColumnIndex: Int? = nil

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        // On first row, extract column metadata from PostgresCells
        if isFirstRow {
          // PostgresRandomAccessRow is a Sequence of PostgresCell
          var columnIndex = 0
          for cell in randomAccess {
            let columnName = cell.columnName
            // Detect ctid column (our internal identifier)
            if shouldFetchCtid && columnName == "_sqlnb_ctid" {
              ctidColumnIndex = columnIndex
            } else {
              columns.append(
                ColumnInfo(
                  name: columnName,
                  type: postgresDataTypeName(cell.dataType)
                ))
            }
            columnIndex += 1
          }
          isFirstRow = false
        }

        // Parse values for each cell
        var rowValues: [CellValue] = []
        var columnIndex = 0
        var ctidValue: CellValue? = nil

        for cell in randomAccess {
          let value = parseCellValue(from: cell)

          // If this is the ctid column, store it separately
          if let ctidIndex = ctidColumnIndex, columnIndex == ctidIndex {
            ctidValue = value
          } else {
            rowValues.append(value)
          }
          columnIndex += 1
        }

        resultRows.append(rowValues)

        // Store ctid value if we found it
        if let ctid = ctidValue {
          rowIdentifiers.append(ctid)
        }
      }

      let executionTime = Date().timeIntervalSince(startTime)

      // Check if result was limited:
      // - If we got exactly maxRows AND the original query didn't have LIMIT
      // - This indicates there might be more rows available
      // - Only for queries with FROM clause (table queries, not function calls)
      let hadNoLimit = !hasLimitClause(query)
      if resultRows.count == maxRows && hadNoLimit && isSelectQuery(query) && hasFromClause(query) {
        wasLimited = true
      }

      // Try to enrich column type information with modifiers
      let enrichedColumns = await enrichColumnTypes(columns: columns, query: executionQuery)

      return QueryResult(
        columns: enrichedColumns,
        rows: resultRows,
        rowCount: resultRows.count,
        executionTime: executionTime,
        wasLimited: wasLimited,
        rowIdentifiers: rowIdentifiers,
        userLimitExceeded: userLimitExceeded,
        userRequestedLimit: userRequestedLimit
      )

    } catch let error as PSQLError {
      let executionTime = Date().timeIntervalSince(startTime)
      // Extract detailed error information from PostgreSQL
      let errorMessage = formatPostgresError(error, query: query)
      throw DatabaseError.queryFailed(errorMessage, executionTime)
    } catch {
      let executionTime = Date().timeIntervalSince(startTime)
      throw DatabaseError.queryFailed(error.localizedDescription, executionTime)
    }
  }

  /// Execute an UPDATE statement for a single cell value
  /// - Parameters:
  ///   - tableName: The name of the table to update
  ///   - columnName: The column to update
  ///   - newValue: The new value as CellValue
  ///   - rowData: All column values for the row (used to build WHERE clause)
  ///   - rowIdentifier: Optional row identifier (ctid for PostgreSQL, rowid for SQLite)
  /// - Returns: Number of rows affected
  func updateCellValue(
    tableName: String,
    columnName: String,
    newValue: CellValue,
    rowData: [String: CellValue],
    primaryKeyColumns: [String],
    rowIdentifier: CellValue?
  ) async throws -> Int {
    guard _connection != nil else {
      throw DatabaseError.notConnected
    }

    // Build WHERE clause with priority strategy:
    // 1. Use primary key columns if available (most reliable and portable)
    // 2. Use row identifier (ctid for PostgreSQL) if available
    // 3. Fall back to all columns (current approach)
    var whereConditions: [String] = []

    // Priority 1: Use primary key columns if available
    if !primaryKeyColumns.isEmpty {
      var pkConditionsValid = true
      for pkColumn in primaryKeyColumns {
        if let pkValue = rowData[pkColumn] {
          let sqlValue = cellValueToSQL(pkValue)
          whereConditions.append("\"\(pkColumn)\" = \(sqlValue)")
        } else {
          // PK column not found in rowData, cannot use PK approach
          pkConditionsValid = false
          whereConditions = []
          break
        }
      }
      // If we successfully built PK conditions, we're done
      if pkConditionsValid {
        // Successfully used primary key
      }
    }

    // Priority 2: Use row identifier (ctid) for PostgreSQL if no PK available
    if whereConditions.isEmpty, let rowId = rowIdentifier, let dbType = databaseType {
      switch dbType {
      case .postgresql:
        // Use ctid for PostgreSQL
        let tidValue = cellValueToSQL(rowId)
        whereConditions.append("ctid = \(tidValue)::tid")
      case .sqlite:
        // SQLite rowid support planned for phase 5
        break
      }
    }

    // Priority 3 (Fallback): Use all columns if no PK and no row identifier
    if whereConditions.isEmpty {
      for (col, val) in rowData {
        let sqlValue = cellValueToSQL(val)
        whereConditions.append("\"\(col)\" = \(sqlValue)")
      }
    }

    let whereClause = whereConditions.joined(separator: " AND ")

    // Build UPDATE query
    let newSQLValue = cellValueToSQL(newValue)
    let updateQuery = """
      UPDATE "\(tableName)"
      SET "\(columnName)" = \(newSQLValue)
      WHERE \(whereClause)
      """

    let startTime = Date()

    do {
      guard let connection = _connection else {
        throw DatabaseError.notConnected
      }

      // Execute UPDATE
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: updateQuery),
        logger: Logger(label: "sqlnotebook.update")
      )

      // Count affected rows
      var rowsAffected = 0
      for try await _ in stream {
        rowsAffected += 1
      }

      return rowsAffected

    } catch let error as PSQLError {
      let executionTime = Date().timeIntervalSince(startTime)
      // Extract detailed error information from PostgreSQL
      let errorMessage = formatPostgresError(error, query: updateQuery)
      throw DatabaseError.queryFailed(errorMessage, executionTime)
    } catch {
      let executionTime = Date().timeIntervalSince(startTime)
      throw DatabaseError.queryFailed(error.localizedDescription, executionTime)
    }
  }

  // MARK: - Query Helpers

  /// Check if a query is a SELECT statement
  private func isSelectQuery(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.uppercased().hasPrefix("SELECT")
  }

  /// Check if a query is a data modification statement (UPDATE, DELETE, INSERT)
  private func isModificationQuery(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return trimmed.hasPrefix("UPDATE") || trimmed.hasPrefix("DELETE") || trimmed.hasPrefix("INSERT")
  }

  /// Wrap a modification query (UPDATE/DELETE/INSERT) to return affected row count
  /// Uses WITH (CTE) to capture the affected rows and count them
  /// This is necessary because PostgresNIO 1.30.1 doesn't expose commandTag in public API
  private func wrapModificationQueryForCount(_ query: String) -> String {
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

  /// Parse affected rows count from PostgreSQL commandTag
  /// NOTE: This is for future use when PostgresNIO exposes commandTag
  /// CommandTag format examples:
  /// - "UPDATE 5" -> 5 rows affected
  /// - "DELETE 3" -> 3 rows affected
  /// - "INSERT 0 1" -> 1 row inserted (oid is 0)
  private func parseAffectedRows(from commandTag: String) -> Int? {
    let parts = commandTag.split(separator: " ")

    // For INSERT: "INSERT oid rows" - we want the last part (rows)
    // For UPDATE/DELETE: "UPDATE rows" or "DELETE rows" - we want the last part
    if let last = parts.last, let count = Int(last) {
      return count
    }

    return nil
  }

  /// Check if a query already has a LIMIT clause
  private func hasLimitClause(_ query: String) -> Bool {
    let normalized = query.lowercased()
    // Use regex to find LIMIT as a separate word (not part of another word)
    return normalized.range(of: "\\blimit\\b", options: .regularExpression) != nil
  }

  /// Check if a query has a FROM clause
  /// Queries without FROM clause are typically function calls like SELECT pg_sleep(3), SELECT now()
  private func hasFromClause(_ query: String) -> Bool {
    let normalized = query.lowercased()
    // Use regex to find FROM as a separate word (not part of another word)
    return normalized.range(of: "\\bfrom\\b", options: .regularExpression) != nil
  }

  /// Extract LIMIT value from a query (returns nil if no LIMIT or cannot parse)
  private func extractLimitValue(_ query: String) -> Int? {
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

  /// Wrap a SELECT query with LIMIT clause to prevent fetching too many rows
  /// Enforces maxRows limit even if the query already has a LIMIT clause
  private func wrapQueryWithLimit(_ query: String, maxRows: Int) -> String {
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
  private func replaceLimitValue(_ query: String, maxRows: Int) -> String {
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

  /// Wrap a SELECT query to include ctid as an aliased column
  /// Note: This only works for simple SELECT * FROM table queries
  /// For complex queries (joins, subqueries, etc.), ctid won't be available
  private func wrapQueryWithCtid(_ query: String) -> String {
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

  /// Enrich column type information with modifiers (precision, scale, length)
  /// Uses information_schema to get detailed type info
  private func enrichColumnTypes(columns: [ColumnInfo], query: String) async -> [ColumnInfo] {
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

  /// Extract table name from a simple SELECT query (SELECT ... FROM table_name ...)
  /// Returns nil if query is complex (joins, subqueries, etc.)
  private func extractSingleTableName(_ query: String) -> String? {
    let normalized =
      query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

    // Pattern: SELECT ... FROM table_name (with optional WHERE/LIMIT/etc.)
    // This is a simple regex that handles basic cases
    let pattern = "(?i)SELECT\\s+.+?\\s+FROM\\s+([a-zA-Z_][a-zA-Z0-9_]*)"

    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
      let match = regex.firstMatch(
        in: normalized,
        options: [],
        range: NSRange(normalized.startIndex..., in: normalized)
      ),
      match.numberOfRanges > 1,
      let tableRange = Range(match.range(at: 1), in: normalized)
    else {
      return nil
    }

    let tableName = String(normalized[tableRange])

    // Exclude queries with JOINs or subqueries (simple check)
    let upperQuery = normalized.uppercased()
    if upperQuery.contains(" JOIN ") || upperQuery.contains("(SELECT") {
      return nil
    }

    return tableName
  }
}
