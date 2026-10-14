// AIQueryResult.swift
// Rows of a query the app ran for the AI assistant, as shown and stored in the chat

import Foundation

nonisolated struct AIQueryResult: Codable, Equatable, Sendable {
  nonisolated struct Column: Codable, Equatable, Sendable {
    var name: String
    var type: String
  }

  var columns: [Column]
  /// Display text per cell, nil for NULL, cut to about `MCPResultEncoder.maxCellCharacters`.
  /// Kept in memory only, see the `Codable` extension.
  var rows: [[String?]]
  /// Number of rows kept, still known once `rows` is gone after decoding
  var rowCount: Int
  /// More rows existed than are kept here
  var rowsTruncated: Bool

  /// Keeps at most `maxRows` rows. Binary cells show their byte count.
  @MainActor
  static func make(from result: QueryResult, maxRows: Int) -> AIQueryResult {
    let rows = result.rows.prefix(maxRows).map { row in
      row.map { value -> String? in
        switch value {
        case .null: return nil
        case .data: return value.displayString
        default: return String(value.fullString.prefix(MCPResultEncoder.maxCellCharacters + 1))
        }
      }
    }
    return AIQueryResult(
      columns: result.columns.map { Column(name: $0.name, type: $0.type) }, rows: Array(rows),
      rowCount: rows.count,
      rowsTruncated: result.truncated || result.wasLimited || result.rows.count > maxRows)
  }
}

/// Row values can hold personal data or secrets, and chats are saved as plain JSON (and exported),
/// so `rows` stays in memory only: encoding leaves it out and decoding sets it to `[]`. A chat
/// reopened after relaunch shows only the row count.
nonisolated extension AIQueryResult {
  private enum CodingKeys: String, CodingKey {
    case columns, rowCount, rowsTruncated
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      columns: try container.decode([Column].self, forKey: .columns), rows: [],
      rowCount: try container.decode(Int.self, forKey: .rowCount),
      rowsTruncated: try container.decode(Bool.self, forKey: .rowsTruncated))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(columns, forKey: .columns)
    try container.encode(rowCount, forKey: .rowCount)
    try container.encode(rowsTruncated, forKey: .rowsTruncated)
  }
}
