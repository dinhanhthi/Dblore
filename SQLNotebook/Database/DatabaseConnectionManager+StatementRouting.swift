// DatabaseConnectionManager+StatementRouting.swift
// Statements that are not reads are sent unchanged. The affected row count comes from the
// server command tag (no RETURNING) or from the rows read (RETURNING).

import Foundation
import Logging
import PostgresNIO

/// How `executeSingleStatement` sends one statement.
nonisolated enum StatementRoute: Sendable, Equatable {
  /// Reads and EXPLAIN: row stream with the LIMIT / ctid wrappers
  case read
  /// Row stream, text unchanged; affected rows = rows read (INSERT / UPDATE / DELETE / MERGE
  /// with its own, top-level RETURNING)
  case returningRows
  /// Row stream, text unchanged, no affected count (data-modifying WITH, utility, unrecognized:
  /// may return rows that are not the affected rows)
  case unwrappedRows
  /// Text unchanged, rows discarded; affected rows from the command tag
  case command

  /// Statements whose top-level RETURNING rows are exactly the rows they changed
  private static let returningVerbs: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE"]

  /// `nil` (empty / comment-only text) keeps the read path. A WITH that is not a plain read
  /// (a data-modifying CTE, or fail-closed on a column named like a DML keyword) returns the
  /// rows of its outer statement, and neither the rows read nor its command tag are the
  /// affected rows: row stream, count unknown.
  static func route(for statement: ClassifiedStatement?) -> StatementRoute {
    guard let statement else { return .read }
    let first = SQLTokenizer.tokens(statement.text).first { $0.kind == .word }?.keyword ?? ""
    return switch statement.kind {
    case .read, .explain: .read
    case _ where first == "WITH": .unwrappedRows
    case .dml where statement.hasTopLevelReturning && returningVerbs.contains(first):
      .returningRows
    case .dml, .ddl, .tcl, .sessionSet: .command
    case .utility, .unknown: .unwrappedRows
    }
  }

  /// Rows reported by a command tag. PostgresNIO parses `INSERT 0 n`, `UPDATE n`, `DELETE n`,
  /// `SELECT n` (also SELECT INTO / CREATE TABLE AS) and `COPY n` into `rows`; `MERGE n` is left
  /// whole in `command`.
  static func affectedRowCount(rows: Int?, command: String) -> Int? {
    if let rows { return rows }
    let parts = command.split(separator: " ")
    guard parts.count == 2, parts[0] == "MERGE" else { return nil }
    return Int(parts[1])
  }
}

/// Rows read from a stream; the internal ctid column is split into `rowIdentifiers`.
struct CollectedRows {
  var columns: [ColumnInfo] = []
  var rows: [[CellValue]] = []
  var rowIdentifiers: [CellValue] = []
}

extension DatabaseConnectionManager {
  /// Send `query` unchanged and read the command tag (rows, if any, are discarded).
  func executeCommand(
    _ query: String, on connection: PostgresConnection, startTime: Date
  ) async throws -> QueryResult {
    do {
      let metadata = try await connection.query(
        PostgresQuery(unsafeSQL: query), logger: Logger(label: "sqlnotebook")
      ) { _ in }.get()
      return QueryResult(
        columns: [], rows: [], rowCount: 0, executionTime: Date().timeIntervalSince(startTime),
        affectedRows: StatementRoute.affectedRowCount(
          rows: metadata.rows, command: metadata.command))
    } catch {
      throw queryFailure(error, query: query, startTime: startTime)
    }
  }

  /// Send `query` unchanged and read every row it returns. With `countRows`, the rows read
  /// are the affected rows (DML with RETURNING).
  func executeUnwrapped(
    _ query: String, on connection: PostgresConnection, countRows: Bool, startTime: Date
  ) async throws -> QueryResult {
    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query), logger: Logger(label: "sqlnotebook"))
      let collected = try await collectRows(stream, fetchCtid: false)
      return QueryResult(
        columns: collected.columns, rows: collected.rows, rowCount: collected.rows.count,
        executionTime: Date().timeIntervalSince(startTime),
        affectedRows: countRows ? collected.rows.count : nil)
    } catch {
      throw queryFailure(error, query: query, startTime: startTime)
    }
  }

  /// Read all rows of `stream`, taking column names / types from the first row.
  func collectRows(_ stream: PostgresRowSequence, fetchCtid: Bool) async throws -> CollectedRows {
    var collected = CollectedRows()
    var ctidColumnIndex: Int?
    var isFirstRow = true
    for try await row in stream {
      let randomAccess = row.makeRandomAccess()
      if isFirstRow {
        for (index, cell) in randomAccess.enumerated() {
          if fetchCtid && cell.columnName == "_sqlnb_ctid" {
            ctidColumnIndex = index  // our internal identifier
          } else {
            collected.columns.append(
              ColumnInfo(
                name: cell.columnName, type: postgresDataTypeName(cell.dataType),
                origin: stream.columns.dropFirst(index).first))
          }
        }
        isFirstRow = false
      }
      var rowValues: [CellValue] = []
      for (index, cell) in randomAccess.enumerated() {
        let value = parseCellValue(from: cell)
        if index == ctidColumnIndex {
          collected.rowIdentifiers.append(value)
        } else {
          rowValues.append(value)
        }
      }
      collected.rows.append(rowValues)
    }
    return collected
  }

  /// The error thrown for a failed statement (PostgreSQL details when available).
  func queryFailure(_ error: Error, query: String, startTime: Date) -> DatabaseError {
    let executionTime = Date().timeIntervalSince(startTime)
    if let error = error as? PSQLError {
      return .queryFailed(formatPostgresError(error, query: query), executionTime)
    }
    return .queryFailed(error.localizedDescription, executionTime)
  }
}
