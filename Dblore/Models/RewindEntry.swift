// RewindEntry.swift
// One recorded data viewer edit for Data Rewind: where it ran, its lifecycle state, and its rows
// with the text-form images read from the database (`RewindCaptureSQL`).

import Foundation

/// A column of a captured row. MySQL picks `HEX()` or `CAST(… AS CHAR)` from `typeName`, so the
/// entry keeps it to turn the stored text back into binds later.
nonisolated struct RewindColumn: Codable, Equatable, Sendable {
  var name: String
  /// Engine type name (`int4`, `VARBINARY`, `INTEGER`)
  var typeName: String
}

/// Column name to value text in the capture's form. Nil is SQL NULL, never the text `NULL`.
typealias RewindImage = [String: String?]

/// One edit batch (a staged commit or an inline edit) and how far it got.
nonisolated struct RewindEntry: Equatable, Sendable, Identifiable {
  /// Pending until the write is known to be committed (or rolled back). Rewound goes back to
  /// committed when the rewind itself rolls back; discarded is final.
  nonisolated enum State: String, Sendable, CaseIterable {
    case pending
    case committed
    case discarded
    case rewound

    /// Staying in the same state is allowed (a repeated mark is a no-op).
    func canMove(to next: State) -> Bool {
      if next == self { return true }
      switch (self, next) {
      case (.pending, .committed), (.pending, .discarded), (.pending, .rewound),
        (.committed, .rewound), (.rewound, .committed):
        return true
      default:
        return false
      }
    }
  }

  /// Where the edit came from: a staged batch, or an inline edit (Row Details Apply included).
  nonisolated enum EditKind: String, Sendable {
    case staged
    case inline
  }

  /// Store row id. Ignored by `RewindStore.record`.
  var id: Int64
  /// `databaseType|host|port|database` (`connectionKey(for:)`)
  var connectionKey: String
  /// Unquoted catalog schema, nil when unknown
  var schema: String?
  /// Unquoted catalog table name
  var table: String
  /// Server-formatted relation text, as the edit statements used it
  var qualifiedName: String
  var engine: DatabaseType
  var created: Date
  var state: State
  var editKind: EditKind
  var statementCount: Int
  /// Every column the capture read, in SELECT order
  var columns: [RewindColumn]
  /// A capture failed, so at least one row has no image
  var notCaptured: Bool
  /// Why part of the entry cannot be rewound (an insert without its whole key), or nil
  var notRewindableReason: String?

  static func connectionKey(for config: ConnectionConfig) -> String {
    [config.databaseType.rawValue, config.host, String(config.port), config.database]
      .joined(separator: "|")
  }
}

/// One row the edit wrote. Images are nil when the capture did not run or failed.
nonisolated struct RewindRow: Equatable, Sendable {
  nonisolated enum Operation: String, Sendable {
    case update
    case delete
    case insert
  }

  var operation: Operation
  /// Key column values in the capture's text form. Empty for an insert without its whole key.
  var primaryKey: RewindImage
  /// The row read right before an UPDATE or DELETE
  var before: RewindImage?
  /// The row read again right after an UPDATE or INSERT, in the same transaction: what the
  /// server stored, never the edit's bind text
  var after: RewindImage?
}
