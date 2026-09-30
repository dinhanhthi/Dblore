//
//  DatabaseConnectionManager+QueryExecution.swift
//  Dblore
//
//  Core query execution methods for DatabaseConnectionManager
//  Helper methods moved to:
//  - DatabaseConnectionManager+QueryParsing.swift (query analysis)
//  - DatabaseConnectionManager+CappedRead.swift (row cap)
//  - DatabaseConnectionManager+StatementRouting.swift (unchanged non-read statements, row reading)
//

import Foundation
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
    guard session != nil else {
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
  ///   - inTransaction: A transaction is open (app or user): a plain read goes through a cursor
  func executeSingleStatement(
    _ query: String, maxRows: Int, inTransaction: Bool = false
  ) async throws -> QueryResult {
    guard session != nil else {
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
    let statement = SQLStatementClassifier.classifyStatement(query)
    switch StatementRoute.route(for: statement) {
    case .command:
      return try await executeCommand(query, startTime: startTime)
    case .returningRows:
      return try await executeUnwrapped(
        query, countRows: true, maxRows: maxRows, startTime: startTime)
    case .unwrappedRows:
      return try await executeUnwrapped(
        query, countRows: false, maxRows: maxRows, startTime: startTime)
    case .read:
      if inTransaction, let statement, Self.usesCursor(statement),
        session?.capabilities.supportsServerCursor == true
      {
        return try await executeCursorRead(query, maxRows: maxRows, startTime: startTime)
      }
    }

    // Reads are sent as written (no LIMIT / ctid rewrite): the capped reader stops after
    // `maxRows` rows and breaks; the caller decides whether the session is reset
    // (`resetSessionIfCapped`) or drained.
    do {
      let collected = try await withSession { current in
        let source = try await current.query(query, binds: [])
        return try await self.readCapped(source, maxRows: maxRows, readToEnd: false)
      }
      let executionTime = Date().timeIntervalSince(startTime)
      // Try to enrich column type information with modifiers. Not after a truncated read: the
      // catalog query would first wait for the rest of the result to drain.
      let enrichedColumns =
        collected.truncated
        ? collected.columns : await enrichColumnTypes(columns: collected.columns, query: query)
      var result = QueryResult(
        columns: enrichedColumns, rows: collected.rows, rowCount: collected.rows.count,
        executionTime: executionTime, wasLimited: collected.truncated,
        affectedRows: 0)  // SELECT queries always have 0 affected rows
      result.truncated = collected.truncated
      return result
    } catch {
      throw queryFailure(error, query: query, startTime: startTime)
    }
  }
}
