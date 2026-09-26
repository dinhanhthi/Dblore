//
//  DatabaseConnectionManager+QueryExecution.swift
//  SQLNotebook
//
//  Core query execution methods for DatabaseConnectionManager
//  Helper methods moved to:
//  - DatabaseConnectionManager+QueryParsing.swift (query analysis)
//  - DatabaseConnectionManager+QueryWrapping.swift (query transformation)
//  - DatabaseConnectionManager+StatementRouting.swift (unchanged non-read statements, row reading)
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
  func executeSingleStatement(_ query: String, maxRows: Int) async throws -> QueryResult {
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

    // Everything but reads is sent unchanged (affected rows from the command tag or RETURNING)
    switch StatementRoute.route(for: SQLStatementClassifier.classifyStatement(query)) {
    case .command:
      return try await executeCommand(query, on: connection, startTime: startTime)
    case .returningRows:
      return try await executeUnwrapped(
        query, on: connection, countRows: true, startTime: startTime)
    case .unwrappedRows:
      return try await executeUnwrapped(
        query, on: connection, countRows: false, startTime: startTime)
    case .read:
      break
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

      let collected = try await collectRows(stream, fetchCtid: shouldFetchCtid)
      let columns = collected.columns
      let resultRows = collected.rows
      var wasLimited = false

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
        rowIdentifiers: collected.rowIdentifiers,
        userLimitExceeded: finalUserLimitExceeded,
        userRequestedLimit: finalUserRequestedLimit,
        affectedRows: 0,  // SELECT queries always have 0 affected rows
        limitWasCapped: limitWasCapped,
        actualLimitUsed: actualLimitUsed
      )

    } catch {
      throw queryFailure(error, query: query, startTime: startTime)
    }
  }
}
