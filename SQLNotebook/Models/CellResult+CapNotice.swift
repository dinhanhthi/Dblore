//
//  CellResult+CapNotice.swift
//  SQLNotebook
//
//  Row cap notice of a result: "Showing first N rows" and, when the capped read reset the
//  session, what the user lost.
//

import Foundation

extension CellResult {
  /// This result with the session reset details of `queryResult` (session-only fields)
  func withCapInfo(from queryResult: QueryResult) -> CellResult {
    var result = self
    result.sessionReset = queryResult.sessionReset
    result.userTxRolledBack = queryResult.userTxRolledBack
    result.skippedStatements = queryResult.skippedStatements
    return result
  }

  /// nil when every row was read and the session was kept
  var capNotice: String? {
    guard wasLimited || sessionReset else { return nil }
    var parts = ["Showing first \(rowCount) rows"]
    if sessionReset {
      parts[0] += "."
      parts.append("The statement was stopped on the server.")
      parts.append("Connection was reset — temp tables, SET and search_path were lost.")
      if userTxRolledBack {
        parts.append("Your open transaction was rolled back.")
      }
      if !skippedStatements.isEmpty {
        let count = skippedStatements.count
        parts.append(
          "\(count) statement\(count == 1 ? "" : "s") after this one "
            + "\(count == 1 ? "was" : "were") not run.")
      }
      if skippedQueuedCells > 0 {
        parts.append(Self.queuedCellsNotRunMessage(skippedQueuedCells))
      }
    }
    return parts.joined(separator: " ")
  }

  /// "N queued cells were not run because the connection was reset."
  static func queuedCellsNotRunMessage(_ count: Int) -> String {
    "\(count) queued cell\(count == 1 ? " was" : "s were") not run because the connection was "
      + "reset."
  }
}
