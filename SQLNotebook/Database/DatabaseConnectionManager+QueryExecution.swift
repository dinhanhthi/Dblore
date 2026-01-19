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
}
