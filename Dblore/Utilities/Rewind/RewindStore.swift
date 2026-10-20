// RewindStore.swift
// Data Rewind entries and row images in their own SQLite file, apart from query history.
// The file holds row data, so it never goes into a backup (`LocalDataCategory.dataRewind`).

import Foundation

nonisolated enum RewindStoreError: Error, Equatable, LocalizedError {
  /// The lifecycle does not allow this change (`RewindEntry.State.canMove(to:)`)
  case invalidTransition(from: RewindEntry.State, to: RewindEntry.State)
  /// The file was written by a newer build
  case unsupportedVersion(Int32)
  /// A stored entry or row has a value this build cannot read
  case corruptEntry(Int64)

  var errorDescription: String? {
    switch self {
    case .invalidTransition(let from, let to):
      "A \(from.rawValue) rewind entry cannot become \(to.rawValue)."
    case .unsupportedVersion(let version):
      "The Data Rewind file uses version \(version), which this version of Dblore cannot read."
    case .corruptEntry(let id):
      "Data Rewind entry \(id) is unreadable."
    }
  }
}

/// Entries, their rows, and the state of each entry. One lock serializes every call on the
/// handle, so callers on any actor share it. Tests pass a temporary file URL.
///
/// Size is the byte count of the stored row images, not the file size: SQLite keeps freed
/// pages until `VACUUM`, so the file would never shrink under the cap.
nonisolated final class RewindStore: @unchecked Sendable {
  /// Stored row image bytes kept before the oldest entries go
  static let defaultMaxBytes: Int64 = 100_000_000

  /// Application Support/Dblore/Rewind/rewind.sqlite
  static var defaultURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dblore/Rewind", isDirectory: true)
      .appendingPathComponent("rewind.sqlite")
  }

  /// The default file, opened on first use. Nil when it cannot be opened: edits still run,
  /// they just record nothing. Tests must not touch it.
  static let shared: RewindStore? = {
    let url = defaultURL
    do {
      try prepareDirectory(url.deletingLastPathComponent())
      return try RewindStore(url: url)
    } catch {
      let message = error.localizedDescription
      Task {
        await AppLogger.shared.error(
          "Data Rewind store failed to open: \(message)", category: "Rewind")
      }
      return nil
    }
  }()

  /// Creates `url` readable by this user only (tightening an existing one) and keeps it out of
  /// Time Machine and other backups, since the file holds row data.
  static func prepareDirectory(_ url: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var directory = url
    try directory.setResourceValues(values)
  }

  private let lock = NSLock()
  private let database: SQLiteHandle
  private let fileURL: URL
  private let maxBytes: Int64

  init(url: URL, maxBytes: Int64 = RewindStore.defaultMaxBytes) throws {
    let database = try SQLiteHandle(url: url)
    // Per connection: deleted row images are zeroed instead of left in free pages
    try database.execute("PRAGMA secure_delete = ON")
    switch database.userVersion {
    case 0: try Self.createVersion1(database)
    case 1: break
    case let version: throw RewindStoreError.unsupportedVersion(version)
    }
    self.database = database
    self.fileURL = url
    self.maxBytes = maxBytes
  }

  /// Writes the entry and its rows in one transaction, then drops the oldest other entries
  /// while the stored images pass the size cap (the new entry always stays).
  /// - Returns: the new entry id. `entry.id` is ignored.
  @discardableResult
  func record(_ entry: RewindEntry, rows: [RewindRow]) throws -> Int64 {
    try lock.withLock {
      let encoded = try rows.map(EncodedRow.init)
      var id: Int64 = 0
      try database.transaction {
        id = try insert(entry, byteCount: encoded.reduce(0) { $0 + $1.byteCount })
        for (position, row) in encoded.enumerated() {
          try insert(row, entryID: id, position: position)
        }
        try capSize(keeping: id)
      }
      return id
    }
  }

  /// Every entry newest first, or only the ones of `connectionKey`. Rows are not loaded.
  func entries(connectionKey: String?) throws -> [RewindEntry] {
    try lock.withLock {
      var sql = "SELECT \(Self.entryColumns) FROM entries"
      if connectionKey != nil {
        sql += " WHERE connection_key = ?"
      }
      sql += " ORDER BY created_at DESC, id DESC"
      let statement = try database.prepare(sql)
      if let connectionKey {
        try statement.bind(1, .string(connectionKey))
      }
      var entries: [RewindEntry] = []
      while try statement.step() {
        entries.append(try Self.readEntry(statement))
      }
      return entries
    }
  }

  /// The rows of one entry in recorded order. Empty when the entry is gone.
  func rows(entryID: Int64) throws -> [RewindRow] {
    try lock.withLock {
      let statement = try database.prepare(
        """
        SELECT op, primary_key, before_image, after_image FROM rows
        WHERE entry_id = ? ORDER BY position
        """)
      try statement.bind(1, .int(Int(entryID)))
      var rows: [RewindRow] = []
      while try statement.step() {
        rows.append(try Self.readRow(statement, entryID: entryID))
      }
      return rows
    }
  }

  /// Moves every listed entry to `state`, or none when one of them cannot move there.
  /// Ids no longer stored (pruned or deleted) are skipped.
  func setState(_ state: RewindEntry.State, ids: [Int64]) throws {
    try lock.withLock {
      try database.transaction {
        let read = try database.prepare("SELECT state FROM entries WHERE id = ?")
        let update = try database.prepare("UPDATE entries SET state = ? WHERE id = ?")
        for id in ids {
          try read.reset()
          try read.bind(1, .int(Int(id)))
          guard try read.step() else { continue }
          guard let text = read.columnText(0), let current = RewindEntry.State(rawValue: text)
          else { throw RewindStoreError.corruptEntry(id) }
          guard current.canMove(to: state) else {
            throw RewindStoreError.invalidTransition(from: current, to: state)
          }
          try update.reset()
          try update.bind(1, .string(state.rawValue))
          try update.bind(2, .int(Int(id)))
          while try update.step() {}
        }
      }
    }
  }

  /// Deletes entries created more than `retentionDays` 24-hour days before `now` (none when
  /// `retentionDays` is 0 or less), then the oldest while the images pass the size cap (the
  /// newest entry always stays, as in `record`). The checkpoint empties the WAL file, so the
  /// deleted images do not linger there.
  func prune(retentionDays: Int, now: Date = Date()) throws {
    try lock.withLock {
      try database.transaction {
        if retentionDays > 0 {
          let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 60 * 60)
          let statement = try database.prepare("DELETE FROM entries WHERE created_at < ?")
          try statement.bind(1, .double(cutoff.timeIntervalSince1970))
          while try statement.step() {}
        }
        let newest = try database.prepare(
          "SELECT id FROM entries ORDER BY created_at DESC, id DESC LIMIT 1")
        try capSize(keeping: try newest.step() ? newest.columnInt(0) : nil)
      }
      try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
  }

  /// Removes every entry and row, then compacts the file so its size drops.
  func deleteAll() throws {
    try lock.withLock {
      try database.transaction {
        try database.execute("DELETE FROM entries")
      }
      // VACUUM cannot run inside a transaction. The checkpoint empties the WAL file.
      try database.execute("VACUUM")
      try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
  }

  func count() throws -> Int {
    try lock.withLock {
      let statement = try database.prepare("SELECT COUNT(*) FROM entries")
      guard try statement.step() else { return 0 }
      return Int(statement.columnInt(0))
    }
  }

  /// Bytes of the file and its WAL on disk. In-memory databases report 0.
  func fileSize() throws -> Int64 {
    if fileURL.path == ":memory:" || fileURL.absoluteString == ":memory:" { return 0 }
    var total: Int64 = 0
    for path in [fileURL.path, fileURL.path + "-wal"]
    where FileManager.default.fileExists(atPath: path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
    return total
  }

  // MARK: - Writes

  private func insert(_ entry: RewindEntry, byteCount: Int) throws -> Int64 {
    let statement = try database.prepare(
      """
      INSERT INTO entries (
        connection_key, table_schema, table_name, qualified_name, engine, created_at, state,
        edit_kind, statement_count, columns, not_captured, not_rewindable, byte_count
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """)
    try statement.bind(1, .string(entry.connectionKey))
    try statement.bind(2, entry.schema.map(CellValue.string) ?? .null)
    try statement.bind(3, .string(entry.table))
    try statement.bind(4, .string(entry.qualifiedName))
    try statement.bind(5, .string(entry.engine.rawValue))
    try statement.bind(6, .double(entry.created.timeIntervalSince1970))
    try statement.bind(7, .string(entry.state.rawValue))
    try statement.bind(8, .string(entry.editKind.rawValue))
    try statement.bind(9, .int(entry.statementCount))
    try statement.bind(10, .string(try Self.json(entry.columns)))
    try statement.bind(11, .bool(entry.notCaptured))
    try statement.bind(12, entry.notRewindableReason.map(CellValue.string) ?? .null)
    try statement.bind(13, .int(byteCount))
    while try statement.step() {}
    return database.lastInsertRowID
  }

  private func insert(_ row: EncodedRow, entryID: Int64, position: Int) throws {
    let statement = try database.prepare(
      """
      INSERT INTO rows (entry_id, position, op, primary_key, before_image, after_image)
      VALUES (?, ?, ?, ?, ?, ?)
      """)
    try statement.bind(1, .int(Int(entryID)))
    try statement.bind(2, .int(position))
    try statement.bind(3, .string(row.operation.rawValue))
    try statement.bind(4, .string(row.primaryKey))
    try statement.bind(5, row.before.map(CellValue.string) ?? .null)
    try statement.bind(6, row.after.map(CellValue.string) ?? .null)
    while try statement.step() {}
  }

  /// Oldest first (other than `keeping`) until the stored images fit `maxBytes`.
  private func capSize(keeping: Int64?) throws {
    let sum = try database.prepare("SELECT COALESCE(SUM(byte_count), 0) FROM entries")
    guard try sum.step() else { return }
    var total = sum.columnInt(0)
    guard total > maxBytes else { return }
    let oldest = try database.prepare(
      "SELECT id, byte_count FROM entries WHERE id IS NOT ? ORDER BY created_at ASC, id ASC")
    try oldest.bind(1, keeping.map { .int(Int($0)) } ?? .null)
    var doomed: [Int64] = []
    while total > maxBytes, try oldest.step() {
      doomed.append(oldest.columnInt(0))
      total -= oldest.columnInt(1)
    }
    try oldest.reset()
    let delete = try database.prepare("DELETE FROM entries WHERE id = ?")
    for id in doomed {
      try delete.reset()
      try delete.bind(1, .int(Int(id)))
      while try delete.step() {}
    }
  }

  /// A row with its images as JSON text, and the byte count the size cap adds up.
  private struct EncodedRow {
    var operation: RewindRow.Operation
    var primaryKey: String
    var before: String?
    var after: String?

    var byteCount: Int {
      primaryKey.utf8.count + (before?.utf8.count ?? 0) + (after?.utf8.count ?? 0)
    }

    init(_ row: RewindRow) throws {
      operation = row.operation
      primaryKey = try RewindStore.json(row.primaryKey)
      before = try row.before.map(RewindStore.json)
      after = try row.after.map(RewindStore.json)
    }
  }

  // MARK: - Reads

  private static let entryColumns = """
    id, connection_key, table_schema, table_name, qualified_name, engine, created_at, state, \
    edit_kind, statement_count, columns, not_captured, not_rewindable
    """

  private static func readEntry(_ row: SQLiteHandle.Statement) throws -> RewindEntry {
    let id = row.columnInt(0)
    guard let connectionKey = row.columnText(1),
      let table = row.columnText(3),
      let qualifiedName = row.columnText(4),
      let engine = row.columnText(5).flatMap(DatabaseType.init(rawValue:)),
      let state = row.columnText(7).flatMap(RewindEntry.State.init(rawValue:)),
      let editKind = row.columnText(8).flatMap(RewindEntry.EditKind.init(rawValue:)),
      let columnsText = row.columnText(10),
      let columns = try? decode([RewindColumn].self, from: columnsText)
    else { throw RewindStoreError.corruptEntry(id) }
    return RewindEntry(
      id: id, connectionKey: connectionKey, schema: row.columnText(2), table: table,
      qualifiedName: qualifiedName, engine: engine,
      created: Date(timeIntervalSince1970: row.columnDouble(6)), state: state,
      editKind: editKind, statementCount: Int(row.columnInt(9)), columns: columns,
      notCaptured: row.columnInt(11) != 0, notRewindableReason: row.columnText(12))
  }

  private static func readRow(_ row: SQLiteHandle.Statement, entryID: Int64) throws -> RewindRow {
    func image(_ index: Int32) throws -> RewindImage? {
      guard let text = row.columnText(index) else { return nil }
      do {
        return try decode(RewindImage.self, from: text)
      } catch {
        throw RewindStoreError.corruptEntry(entryID)
      }
    }
    guard let operation = row.columnText(0).flatMap(RewindRow.Operation.init(rawValue:)),
      let primaryKey = try image(1)
    else { throw RewindStoreError.corruptEntry(entryID) }
    return RewindRow(
      operation: operation, primaryKey: primaryKey, before: try image(2), after: try image(3))
  }

  // MARK: - Encoding

  /// `nil` image values are written as JSON `null`, so NULL never reads back as text.
  private static func json<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private static func decode<Value: Decodable>(
    _ type: Value.Type, from text: String
  ) throws
    -> Value
  {
    try JSONDecoder().decode(type, from: Data(text.utf8))
  }

  // MARK: - Schema

  private static func createVersion1(_ database: SQLiteHandle) throws {
    try database.transaction {
      try database.execute(
        """
        CREATE TABLE entries (
          id INTEGER PRIMARY KEY,
          connection_key TEXT NOT NULL,
          table_schema TEXT,
          table_name TEXT NOT NULL,
          qualified_name TEXT NOT NULL,
          engine TEXT NOT NULL,
          created_at REAL NOT NULL,
          state TEXT NOT NULL,
          edit_kind TEXT NOT NULL,
          statement_count INTEGER NOT NULL,
          columns TEXT NOT NULL,
          not_captured INTEGER NOT NULL,
          not_rewindable TEXT,
          byte_count INTEGER NOT NULL
        )
        """)
      try database.execute(
        """
        CREATE TABLE rows (
          id INTEGER PRIMARY KEY,
          entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          op TEXT NOT NULL,
          primary_key TEXT NOT NULL,
          before_image TEXT,
          after_image TEXT
        )
        """)
      try database.execute(
        "CREATE INDEX entries_connection ON entries(connection_key, created_at)")
      try database.execute("CREATE INDEX entries_created ON entries(created_at)")
      try database.execute("CREATE INDEX rows_entry ON rows(entry_id, position)")
      try database.execute("PRAGMA user_version = 1")
    }
  }
}
