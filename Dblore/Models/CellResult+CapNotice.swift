//
//  CellResult+CapNotice.swift
//  Dblore
//
//  Row cap notice of a result: "Showing first N rows", a stop at the byte budget, values cut
//  at the cell limit and, when the capped read reset the session, what the user lost.
//

import Foundation

extension CellResult {
  /// This result with the session reset details (session-only fields), the cut cells and the
  /// byte stop of `queryResult`
  func withCapInfo(from queryResult: QueryResult) -> CellResult {
    var result = self
    result.sessionReset = queryResult.sessionReset
    result.skippedStatements = queryResult.skippedStatements
    result.cutCells = queryResult.cutCells
    result.stoppedAtByteBudget = queryResult.stoppedAtByteBudget
    return result
  }

  /// nil when every row was read whole and the session was kept. The sizes are the app's
  /// limits (`CappedReadLimits.app`), the only limits that mark cut cells.
  var capNotice: String? {
    guard wasLimited || sessionReset || stoppedAtByteBudget || !cutCells.isEmpty else {
      return nil
    }
    var parts: [String] = []
    if wasLimited || sessionReset {
      parts.append("Showing first \(rowCount) rows")
    }
    if stoppedAtByteBudget {
      parts.append("Stopped at \(Self.mebibytes(CappedReadLimits.app.maxResultBytes)) of values.")
    }
    if sessionReset {
      parts.append("The statement was stopped on the server.")
      parts.append("Connection was reset — temp tables, SET and search_path were lost.")
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
    if !cutCells.isEmpty {
      let count = cutCells.count
      parts.append(
        "\(count) value\(count == 1 ? " was" : "s were") cut at "
          + "\(Self.mebibytes(CappedReadLimits.app.maxCellCharacters)).")
    }
    // "Showing first N rows" ends its sentence only when another one follows
    if parts.count > 1, wasLimited || sessionReset { parts[0] += "." }
    return parts.joined(separator: " ")
  }

  /// `count` (a multiple of 1 MiB) as "N MiB"
  private static func mebibytes(_ count: Int) -> String {
    "\(count / 1_048_576) MiB"
  }

  /// Shown on an editor result an inline edit made stale (`staleAfterEdit`)
  static let runAgainToRefreshNotice = "Run again to refresh"

  /// The editor result banner: `capNotice` and, on its own line, `runAgainToRefreshNotice`
  var editorNotice: String? {
    let parts = [capNotice, staleAfterEdit ? Self.runAgainToRefreshNotice : nil].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }

  /// "N queued cells were not run because the connection was reset."
  static func queuedCellsNotRunMessage(_ count: Int) -> String {
    "\(count) queued cell\(count == 1 ? " was" : "s were") not run because the connection was "
      + "reset."
  }
}
