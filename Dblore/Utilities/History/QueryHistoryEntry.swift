// QueryHistoryEntry.swift
// One recorded SQL statement: when it ran, how it ended, and which connection it used.

import Foundation

/// A row in the query-history database. `id` is 0 until the store assigns the SQLite rowid.
nonisolated struct QueryHistoryEntry: Sendable, Codable, Equatable {
  nonisolated enum Status: String, Sendable, Codable, Equatable {
    case success
    case error
    case cancelled
  }

  nonisolated enum Source: String, Sendable, Codable, Equatable, CaseIterable {
    case cell
    case editor
    case dataViewerEdit
    case dataImport
    case mcp
    case structure
    case ai
    /// One summary row per SQL dump
    case dump
    /// One summary row per SQL dump restore
    case restore

    /// JSON from a newer version may hold an unknown source: it reads as editor, as the
    /// database read does, instead of failing the whole import. Encoding keeps the raw value.
    init(from decoder: Decoder) throws {
      let raw = try decoder.singleValueContainer().decode(String.self)
      self = Source(rawValue: raw) ?? .editor
    }
  }

  /// Classified effect of the SQL. Nil when the row has not been classified.
  nonisolated enum Kind: String, Sendable, Codable, Equatable, CaseIterable {
    case read
    case write
    case schema
    case transaction
    case other

    /// An unknown kind from newer JSON reads as `.other` (never a write), so the import goes on.
    init(from decoder: Decoder) throws {
      let raw = try decoder.singleValueContainer().decode(String.self)
      self = Kind(rawValue: raw) ?? .other
    }
  }

  var id: Int64
  var sql: String
  var executedAt: Date
  var durationMs: Int
  var rowCount: Int?
  var status: Status
  var errorMessage: String?
  var connectionKey: String
  var connectionLabel: String
  var workspaceID: UUID?
  var workspaceName: String?
  var source: Source
  /// Missing JSON decodes as nil. NULL in the database is not a write.
  var kind: Kind? = nil

  /// `COMMIT (n statements)` / `ROLLBACK (n statements)` is an audit label, not SQL that was sent.
  nonisolated static func isTransactionSummary(_ sql: String) -> Bool {
    for verb in ["COMMIT ", "ROLLBACK "] {
      guard sql.hasPrefix(verb), sql.hasSuffix(" statements)") else { continue }
      let inside = sql.dropFirst(verb.count).dropLast(" statements)".count)
      guard inside.first == "(", inside.dropFirst().allSatisfy(\.isNumber),
        !inside.dropFirst().isEmpty
      else { continue }
      return true
    }
    return false
  }

  /// A label row, not SQL that was sent, so Insert and Copy skip it: a dump or restore row by
  /// its source, or a transaction summary by its text.
  var isLabel: Bool {
    source == .dump || source == .restore || Self.isTransactionSummary(sql)
  }

  /// `isLabel` for callers with only the text: a transaction summary or the text of a dump
  /// ("SQL dump of <db>: n tables, m rows", "MongoDB backup of <db>: n collections,
  /// m documents") or restore ("Restore SQL dump: n statements", "Restore MongoDB backup:
  /// n collections, m documents") row.
  nonisolated static func isLabelText(_ sql: String) -> Bool {
    if isTransactionSummary(sql) { return true }
    let restorePrefix = "Restore SQL dump: "
    if sql.hasPrefix(restorePrefix) {
      return isCount(sql.dropFirst(restorePrefix.count), "statement")
    }
    let mongoRestorePrefix = "Restore MongoDB backup: "
    if sql.hasPrefix(mongoRestorePrefix) {
      return areCounts(sql.dropFirst(mongoRestorePrefix.count), "collection", "document")
    }
    let nouns: (String, String)
    if sql.hasPrefix("SQL dump of ") {
      nouns = ("table", "row")
    } else if sql.hasPrefix("MongoDB backup of ") {
      nouns = ("collection", "document")
    } else {
      return false
    }
    guard let colon = sql.range(of: ": ", options: .backwards) else { return false }
    return areCounts(sql[colon.upperBound...], nouns.0, nouns.1)
  }

  /// "n <first>s, m <second>s"
  private nonisolated static func areCounts(
    _ text: Substring, _ first: String, _ second: String
  ) -> Bool {
    let counts = text.split(separator: ", ", omittingEmptySubsequences: false)
    return counts.count == 2 && isCount(counts[0], first) && isCount(counts[1], second)
  }

  /// "n noun" or "n nouns", with n in ASCII digits.
  private nonisolated static func isCount(_ text: Substring, _ noun: String) -> Bool {
    let parts = text.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty,
      parts[0].allSatisfy({ $0.isASCII && $0.isNumber })
    else { return false }
    return parts[1] == noun || parts[1] == noun + "s"
  }

  /// The one row a SQL dump records: "SQL dump of <db>: n tables, m rows", a read. Counts are
  /// what was written, so a cancelled or failed dump shows how far it got.
  nonisolated static func dumpSummary(
    _ progress: SQLDumpProgress, config: ConnectionConfig, workspaceID: UUID?,
    workspaceName: String?, durationMs: Int, status: Status, errorMessage: String?
  ) -> QueryHistoryEntry {
    let database =
      config.databaseType == .sqlite
      ? URL(fileURLWithPath: config.database).lastPathComponent : config.database
    let sql =
      "SQL dump of \(database): \(counted(progress.tablesDone, "table")), "
      + counted(progress.rowsWritten, "row")
    return summary(
      sql, config: config, workspaceID: workspaceID, workspaceName: workspaceName,
      durationMs: durationMs, rowCount: progress.rowsWritten, status: status,
      errorMessage: errorMessage, source: .dump, kind: .read)
  }

  /// The one row a restore records: "Restore SQL dump: n statements" (all of the script's),
  /// schema when it has DDL or triggers, else a write.
  nonisolated static func restoreSummary(
    _ restore: SQLRestoreSummary, config: ConnectionConfig, workspaceID: UUID?,
    workspaceName: String?, durationMs: Int, status: Status, errorMessage: String?
  ) -> QueryHistoryEntry {
    summary(
      "Restore SQL dump: \(counted(restore.statementCount, "statement"))", config: config,
      workspaceID: workspaceID, workspaceName: workspaceName, durationMs: durationMs,
      rowCount: nil, status: status, errorMessage: errorMessage, source: .restore,
      kind: restore.changesSchema ? .schema : .write)
  }

  /// The one row a MongoDB backup records: "MongoDB backup of <db>: n collections,
  /// m documents", a read. Counts are what was written, so a cancelled or failed backup shows
  /// how far it got.
  nonisolated static func mongoBackupSummary(
    database: String, collections: Int, documents: Int, config: ConnectionConfig,
    workspaceID: UUID?, workspaceName: String?, durationMs: Int, status: Status,
    errorMessage: String?
  ) -> QueryHistoryEntry {
    summary(
      "MongoDB backup of \(database): \(counted(collections, "collection")), "
        + counted(documents, "document"), config: config, workspaceID: workspaceID,
      workspaceName: workspaceName, durationMs: durationMs, rowCount: documents, status: status,
      errorMessage: errorMessage, source: .dump, kind: .read)
  }

  /// The one row a MongoDB restore records: "Restore MongoDB backup: n collections,
  /// m documents" (the collections restored and documents inserted), a schema change (it
  /// creates collections).
  nonisolated static func mongoRestoreSummary(
    collections: Int, documents: Int, config: ConnectionConfig, workspaceID: UUID?,
    workspaceName: String?, durationMs: Int, status: Status, errorMessage: String?
  ) -> QueryHistoryEntry {
    summary(
      "Restore MongoDB backup: \(counted(collections, "collection")), "
        + counted(documents, "document"), config: config, workspaceID: workspaceID,
      workspaceName: workspaceName, durationMs: durationMs, rowCount: documents, status: status,
      errorMessage: errorMessage, source: .restore, kind: .schema)
  }

  private nonisolated static func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
  }

  /// The label is the connection name, or `host/database` when it has none (as other rows).
  private nonisolated static func summary(
    _ sql: String, config: ConnectionConfig, workspaceID: UUID?, workspaceName: String?,
    durationMs: Int, rowCount: Int?, status: Status, errorMessage: String?, source: Source,
    kind: Kind
  ) -> QueryHistoryEntry {
    let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return QueryHistoryEntry(
      id: 0, sql: sql, executedAt: Date(), durationMs: durationMs, rowCount: rowCount,
      status: status, errorMessage: errorMessage,
      connectionKey: QueryHistoryIdentity.connectionKey(for: config),
      connectionLabel: name.isEmpty ? "\(config.host)/\(config.database)" : name,
      workspaceID: workspaceID, workspaceName: workspaceName, source: source, kind: kind)
  }
}
