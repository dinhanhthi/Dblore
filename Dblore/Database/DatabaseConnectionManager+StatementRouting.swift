// DatabaseConnectionManager+StatementRouting.swift
// Statements that are not reads are sent unchanged. The affected row count comes from the
// server command tag (no RETURNING) or from the rows read (RETURNING).

import Foundation
import Logging
import PostgresNIO

/// How `executeSingleStatement` sends one statement.
nonisolated enum StatementRoute: Sendable, Equatable {
  /// Reads and EXPLAIN: row stream, text unchanged, stops at the row cap (see
  /// `DatabaseConnectionManager+CappedRead.swift`)
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

extension DatabaseConnectionManager {
  /// Send `query` unchanged and read the command tag (rows, if any, are discarded).
  func executeCommand(
    _ query: String, on connection: PostgresConnection, startTime: Date
  ) async throws -> QueryResult {
    do {
      let metadata = try await send(on: connection) {
        try await $0.query(PostgresQuery(unsafeSQL: query), logger: Logger(label: "dblore")) {
          _ in
        }.get()
      }
      return QueryResult(
        columns: [], rows: [], rowCount: 0, executionTime: Date().timeIntervalSince(startTime),
        affectedRows: StatementRoute.affectedRowCount(
          rows: metadata.rows, command: metadata.command))
    } catch {
      throw queryFailure(error, query: query, startTime: startTime)
    }
  }

  /// Send `query` unchanged and read it to the end, keeping at most `maxRows` rows (it may
  /// write: the session is never closed mid-stream). With `countRows`, every row returned is
  /// an affected row (DML with RETURNING).
  func executeUnwrapped(
    _ query: String, on connection: PostgresConnection, countRows: Bool, maxRows: Int,
    startTime: Date
  ) async throws -> QueryResult {
    do {
      let stream = try await send(on: connection) {
        try await $0.query(PostgresQuery(unsafeSQL: query), logger: Logger(label: "dblore"))
      }
      let collected = try await readCapped(stream, maxRows: maxRows, readToEnd: true)
      var result = QueryResult(
        columns: collected.columns, rows: collected.rows, rowCount: collected.rows.count,
        executionTime: Date().timeIntervalSince(startTime), wasLimited: collected.truncated,
        affectedRows: countRows ? collected.total : nil)
      result.truncated = collected.truncated
      return result
    } catch {
      throw queryFailure(error, query: query, startTime: startTime)
    }
  }

  /// The error thrown for a failed statement (PostgreSQL details when available; a lost
  /// session keeps its `connectionLost` message).
  func queryFailure(_ error: Error, query: String, startTime: Date) -> DatabaseError {
    if let lost = error as? DatabaseError, case .connectionLost = lost { return lost }
    let executionTime = Date().timeIntervalSince(startTime)
    if let error = error as? PSQLError {
      return .queryFailed(formatPostgresError(error, query: query), executionTime)
    }
    return .queryFailed(error.localizedDescription, executionTime)
  }
}
