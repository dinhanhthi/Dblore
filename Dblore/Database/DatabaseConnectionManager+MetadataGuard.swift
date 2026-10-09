// DatabaseConnectionManager+MetadataGuard.swift
// App-owned catalog queries (schema browser, autocomplete, foreign keys, edit targets, column
// type enrichment) are never sent inside the pending app transaction: they would run in the
// user's transaction, and a failing one would abort it. The UI serves cached metadata instead.

import Foundation
import PostgresNIO

extension DatabaseConnectionManager {
  /// True while the app transaction is pending or aborted (or its BEGIN is in flight)
  var isMetadataPaused: Bool {
    !txState.isIdle || txOwner != nil
  }

  /// The connection for one app catalog query.
  /// - Throws: `DatabaseError.notConnected`; `DatabaseError.metadataPausedDuringTransaction`
  ///   while the app transaction is pending (nothing is sent).
  /// The pause guard for one app catalog query. PostgreSQL also returns its socket; a file
  /// session returns nil and the caller reads through `withSession`.
  func catalogConnection() throws -> PostgresConnection? {
    guard session != nil else { throw DatabaseError.notConnected }
    guard !isMetadataPaused else { throw DatabaseError.metadataPausedDuringTransaction }
    catalogQueryCount += 1
    return _postgresConnection
  }

  func resetCatalogQueryCount() {
    catalogQueryCount = 0
  }

  /// One app catalog read on the open session. The pause guard and the query counter stay here.
  func withCatalogSession<T: Sendable>(
    _ body: (any DatabaseSession) async throws -> T
  ) async throws -> T {
    _ = try catalogConnection()
    return try await withCatalogReadSession(body)
  }

  /// `withSession` for an app catalog read. A DuckDB connection holds one open result and a new
  /// statement interrupts it, so DuckDB catalog reads (the schema load fetches in parallel) run
  /// one at a time. Other engines run them as they come.
  func withCatalogReadSession<T: Sendable>(
    _ body: (any DatabaseSession) async throws -> T
  ) async throws -> T {
    guard session is DuckDBSession else { return try await withSession(body) }
    if isDuckDBCatalogReadActive {
      await withCheckedContinuation { duckDBCatalogWaiters.append($0) }
    } else {
      isDuckDBCatalogReadActive = true
    }
    defer {
      if duckDBCatalogWaiters.isEmpty {
        isDuckDBCatalogReadActive = false
      } else {
        duckDBCatalogWaiters.removeFirst().resume()
      }
    }
    return try await withSession(body)
  }

  /// `withCatalogSession`, with a query failure wrapped as `Failed to fetch \(what)`.
  /// `catalogConnection()` errors (`notConnected`, `metadataPausedDuringTransaction`) stay as they are.
  func fetchCatalog<T: Sendable>(
    _ what: String,
    _ body: (any DatabaseSession) async throws -> T
  ) async throws -> T {
    _ = try catalogConnection()
    do {
      return try await withCatalogReadSession(body)
    } catch {
      throw DatabaseError.queryFailed(
        "Failed to fetch \(what): \(error.localizedDescription)", 0)
    }
  }
}
