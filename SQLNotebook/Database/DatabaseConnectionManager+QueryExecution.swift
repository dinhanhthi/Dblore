//
//  DatabaseConnectionManager+QueryExecution.swift
//  SQLNotebook
//
//  Core query execution methods for DatabaseConnectionManager
//  Helper methods moved to:
//  - DatabaseConnectionManager+QueryParsing.swift (query analysis)
//  - DatabaseConnectionManager+QueryWrapping.swift (query transformation)
//

import Foundation
import Logging
import PostgresNIO

extension DatabaseConnectionManager {
  // MARK: - Query Execution

  /// Execute APP-OWNED SQL (no protection gate) and return results.
  /// Never pass user text here: user SQL must go through `execute(userSQL:policy:maxRows:)`.
  /// Automatically handles multiple statements separated by semicolons
  /// - Parameters:
  ///   - query: The SQL query to execute (may contain multiple statements)
  ///   - maxRows: Maximum number of rows to fetch (defaults to defaultMaxFetchRows)
  func executeInternal(
    _ query: String, maxRows: Int = defaultMaxFetchRows
  ) async throws
    -> QueryResult
  {
    guard _connection != nil else {
      throw DatabaseError.notConnected
    }

    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DatabaseError.emptyQuery
    }

    // Check if query contains multiple statements
    if hasMultipleStatements(query) {
      return try await executeMultipleStatements(query, maxRows: maxRows)
    }

    // Single statement - proceed with normal execution
    return try await executeSingleStatement(query, maxRows: maxRows)
  }

  /// Execute multiple APP-OWNED SQL statements (no protection gate) sequentially and return
  /// detailed results for each. User SQL must go through `executeDetailed(userSQL:policy:maxRows:)`.
  /// - Parameters:
  ///   - query: SQL string containing multiple statements
  ///   - maxRows: Maximum number of rows to fetch
  /// - Returns: Tuple of (array of results for each statement, total execution time)
  func executeInternalStatementsDetailed(
    _ query: String, maxRows: Int = defaultMaxFetchRows
  )
    async throws -> (results: [(queryText: String, result: QueryResult)], totalTime: TimeInterval)
  {
    let statements = splitSQLStatements(query)

    // Filter out comment-only statements
    let executableStatements = statements.filter { !isCommentOnlyStatement($0) }

    guard !executableStatements.isEmpty else {
      throw DatabaseError.emptyQuery
    }

    // Track execution time for all statements
    let overallStartTime = Date()

    var statementResults: [(queryText: String, result: QueryResult)] = []

    // Execute each statement sequentially
    for statement in executableStatements {
      do {
        let result = try await executeSingleStatement(statement, maxRows: maxRows)
        statementResults.append((queryText: statement, result: result))
      } catch {
        // If any statement fails, throw the error immediately
        throw error
      }
    }

    let totalExecutionTime = Date().timeIntervalSince(overallStartTime)

    return (results: statementResults, totalTime: totalExecutionTime)
  }

  /// Execute multiple SQL statements sequentially
  /// Returns result from the last statement that produces output
  /// - Parameters:
  ///   - query: SQL string containing multiple statements
  ///   - maxRows: Maximum number of rows to fetch
  private func executeMultipleStatements(
    _ query: String, maxRows: Int
  ) async throws
    -> QueryResult
  {
    let statements = splitSQLStatements(query)

    guard !statements.isEmpty else {
      throw DatabaseError.emptyQuery
    }

    // Track execution time for all statements
    let overallStartTime = Date()

    var lastResult: QueryResult?
    var totalAffectedRows = 0

    // Execute each statement sequentially
    for statement in statements {
      do {
        let result = try await executeSingleStatement(statement, maxRows: maxRows)

        // If this is a modification query, accumulate affected rows
        if let affectedRows = result.affectedRows {
          totalAffectedRows += affectedRows
        }

        // Keep the last result (for SELECT queries, we show the last result)
        lastResult = result

      } catch {
        // If any statement fails, throw the error immediately
        throw error
      }
    }

    let totalExecutionTime = Date().timeIntervalSince(overallStartTime)

    // Return the last result with updated execution time
    if let finalResult = lastResult {
      // If we accumulated affected rows, update the result
      if totalAffectedRows > 0 {
        return QueryResult(
          columns: finalResult.columns,
          rows: finalResult.rows,
          rowCount: finalResult.rowCount,
          executionTime: totalExecutionTime,
          wasLimited: finalResult.wasLimited,
          rowIdentifiers: finalResult.rowIdentifiers,
          userLimitExceeded: finalResult.userLimitExceeded,
          userRequestedLimit: finalResult.userRequestedLimit,
          affectedRows: totalAffectedRows
        )
      }

      // Otherwise just update execution time
      return QueryResult(
        columns: finalResult.columns,
        rows: finalResult.rows,
        rowCount: finalResult.rowCount,
        executionTime: totalExecutionTime,
        wasLimited: finalResult.wasLimited,
        rowIdentifiers: finalResult.rowIdentifiers,
        userLimitExceeded: finalResult.userLimitExceeded,
        userRequestedLimit: finalResult.userRequestedLimit,
        affectedRows: finalResult.affectedRows
      )
    }

    // Fallback: return empty result (shouldn't happen)
    throw DatabaseError.queryFailed("No statements executed", 0)
  }

  /// Execute a single SQL statement
  /// - Parameters:
  ///   - query: Single SQL statement
  ///   - maxRows: Maximum number of rows to fetch
  private func executeSingleStatement(_ query: String, maxRows: Int) async throws -> QueryResult {
    guard let connection = _connection else {
      throw DatabaseError.notConnected
    }

    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DatabaseError.emptyQuery
    }

    // DEBUG: Log sanitized query before execution (redact sensitive data)
    let sanitizedQuery = AppLogger.shared.sanitizeQuery(query)
    await AppLogger.shared.debug(
      "About to execute single statement: `\(sanitizedQuery)` (maxRows: \(maxRows))",
      category: "Database")

    let startTime = Date()

    // Check if this is a modification query (UPDATE, DELETE, INSERT)
    let isModification = countsAffectedRows(query)

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
    let userOriginalLimit = extractLimitValue(query)
    let hadUserLimit = userOriginalLimit != nil
    let userLimitExceeded =
      if let userLimit = userOriginalLimit {
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
    await AppLogger.shared.debug(
      "Final query to be sent to database: `\(sanitizedExecutionQuery)`", category: "Database")

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
                  name: columnName, type: postgresDataTypeName(cell.dataType),
                  origin: stream.columns.dropFirst(columnIndex).first))
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

      // Determine final userLimitExceeded and userRequestedLimit values
      // userRequestedLimit should always be the ACTUAL limit applied (not user's original limit)
      // IMPORTANT: userLimitExceeded should only be true if we ACTUALLY returned maxRows
      let finalUserLimitExceeded: Bool
      let finalUserRequestedLimit: Int?

      if wasLimited && !hadUserLimit {
        // We auto-added LIMIT and result was limited
        // This means there are potentially more rows available
        finalUserLimitExceeded = true
        finalUserRequestedLimit = maxRows
      } else if userLimitExceeded {
        // User had LIMIT but it exceeded maxRows, so we capped it
        // However, only show warning if we ACTUALLY returned maxRows
        // (if database has fewer rows than maxRows, no need to warn)
        if resultRows.count >= maxRows {
          finalUserLimitExceeded = true
          finalUserRequestedLimit = maxRows
        } else {
          // Database had fewer rows than maxRows, no warning needed
          finalUserLimitExceeded = false
          finalUserRequestedLimit = nil
        }
      } else if let userLimit = userOriginalLimit, userLimit <= maxRows {
        // User had LIMIT within maxRows, use their limit
        finalUserLimitExceeded = false
        finalUserRequestedLimit = userLimit
      } else {
        // No limiting occurred
        finalUserLimitExceeded = false
        finalUserRequestedLimit = nil
      }

      // Determine limitWasCapped and actualLimitUsed for UI display
      // limitWasCapped = true when user's LIMIT was > maxRows (regardless of result rows)
      // This is used to show correct query in "Run with query" bar and View Query sidebar
      let limitWasCapped = userLimitExceeded  // userLimitExceeded means user's LIMIT > maxRows
      let actualLimitUsed: Int? = limitWasCapped ? maxRows : userOriginalLimit

      // Try to enrich column type information with modifiers
      let enrichedColumns = await enrichColumnTypes(columns: columns, query: executionQuery)

      return QueryResult(
        columns: enrichedColumns,
        rows: resultRows,
        rowCount: resultRows.count,
        executionTime: executionTime,
        wasLimited: wasLimited,
        rowIdentifiers: rowIdentifiers,
        userLimitExceeded: finalUserLimitExceeded,
        userRequestedLimit: finalUserRequestedLimit,
        affectedRows: 0,  // SELECT queries always have 0 affected rows
        limitWasCapped: limitWasCapped,
        actualLimitUsed: actualLimitUsed
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
}
