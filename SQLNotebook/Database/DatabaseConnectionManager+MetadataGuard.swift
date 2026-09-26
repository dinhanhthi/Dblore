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
  func catalogConnection() throws -> PostgresConnection {
    guard let connection = _connection else { throw DatabaseError.notConnected }
    guard !isMetadataPaused else { throw DatabaseError.metadataPausedDuringTransaction }
    return connection
  }
}
