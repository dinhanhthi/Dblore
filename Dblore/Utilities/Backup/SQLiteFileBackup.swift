// SQLiteFileBackup.swift
// Copies a SQLite database file with the online backup API (`sqlite3_backup_*`), off the main
// actor. The source is opened read-only with normal locking (no `immutable=1`), so a WAL
// database copies its latest committed data. The copy is built in a temporary file in the
// container (its journal files stay inside the sandbox), checked with `PRAGMA integrity_check`,
// and only then replaces the destination in one step. The temporary file is created mode 0600
// (SQLite gives its journal files the same mode). A destination with a `-wal`, `-shm` or
// `-journal` file next to it is refused: SQLite would pair that file with the copy on the next
// open (replay an earlier WAL over it, roll a hot journal back into it). Cancel (task
// cancellation) deletes the temporary file and leaves the destination untouched.

import Foundation
import SQLite3

nonisolated enum SQLiteFileBackupError: Error, Equatable, LocalizedError {
  /// The destination is the source file or one of its journal files
  case destinationIsDatabase
  /// `PRAGMA integrity_check` on the copy did not return `ok`
  case integrityCheckFailed(String)
  /// A `-wal`, `-shm` or `-journal` file (named here) sits next to the destination. SQLite
  /// would pair it with the new copy by name.
  case journalFileNextToDestination(String)
  /// The sandbox did not let the copy check for that file
  case journalFileUncheckable(String)

  var errorDescription: String? {
    switch self {
    case .destinationIsDatabase:
      "Choose a different file: this is the open database."
    case .integrityCheckFailed(let detail):
      "The copy failed its integrity check: \(detail)"
    case .journalFileNextToDestination(let name):
      "Choose a different file: \"\(name)\" next to it belongs to an earlier database."
        + " Delete it or pick another name."
    case .journalFileUncheckable(let name):
      "Choose a different file: Dblore could not check whether \"\(name)\" exists next to it."
    }
  }
}

nonisolated enum SQLiteFileBackup {
  /// How far a copy is, in database pages
  struct Progress: Sendable, Equatable {
    var pagesCopied: Int
    var pageCount: Int
  }

  /// Pages copied per `sqlite3_backup_step` call (256 KiB with 4 KiB pages)
  static let pagesPerStep: Int32 = 64
  /// Retries of a step that returned SQLITE_BUSY or SQLITE_LOCKED, `busyRetryDelay` apart
  static let busyRetries = 20
  static let busyRetryDelay: Duration = .milliseconds(50)

  /// Copies the database at `source` to `destination` (an existing file is replaced) and
  /// returns the final progress. `progress` is called off the main actor after each step.
  /// - Throws: `SQLiteFileBackupError` (refused destination, failed integrity check),
  ///   `SQLiteSessionError`, file errors, `CancellationError` when the task is cancelled. The
  ///   destination is untouched and the temporary file deleted then.
  @concurrent static func copy(
    from source: URL, to destination: URL,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    progress: @escaping @Sendable (Progress) -> Void = { _ in }
  ) async throws -> Progress {
    let sourceConfig = ConnectionConfig(databaseType: .sqlite, database: source.path)
    if SQLDumpWriter.isConnectedDatabaseFile(destination, config: sourceConfig) {
      throw SQLiteFileBackupError.destinationIsDatabase
    }
    try checkNoJournalFiles(nextTo: destination)
    let temporary = temporaryDirectory.appendingPathComponent(
      "Dblore-backup-\(UUID().uuidString).sqlite")
    // An empty file is an empty database: SQLite opens it and keeps its mode
    Darwin.close(try SQLDumpWriter.createPrivateFile(at: temporary))
    defer { removeDatabaseFiles(at: temporary) }
    let result = try await backup(from: source.path, to: temporary.path, progress: progress)
    try checkIntegrity(temporary.path)
    try Task.checkCancellation()
    // Again right before the replace: the copy can take long
    if SQLDumpWriter.isConnectedDatabaseFile(destination, config: sourceConfig) {
      throw SQLiteFileBackupError.destinationIsDatabase
    }
    try checkNoJournalFiles(nextTo: destination)
    try SQLDumpWriter.replaceItem(at: destination, withItemAt: temporary)
    return result
  }

  /// Throws when `destination` + `-wal`, `-shm` or `-journal` exists, or when the sandbox does
  /// not let the copy look. The files are looked at while sidecar presenters of `destination`
  /// are registered, as for an opened database (`SQLiteFileAccess`): the sandbox grants a
  /// related item to them.
  private static func checkNoJournalFiles(nextTo destination: URL) throws {
    let queue = OperationQueue()
    queue.name = "dblore.sqlite.backup-presenter"
    queue.maxConcurrentOperationCount = 1
    let presenters = SQLiteFileAccess.sidecarSuffixes.map {
      SQLiteFileAccess.SidecarFilePresenter(primaryURL: destination, suffix: $0, queue: queue)
    }
    presenters.forEach(NSFileCoordinator.addFilePresenter)
    // Registration finishes asynchronously. Reading the list waits for it.
    _ = NSFileCoordinator.filePresenters
    defer { presenters.forEach(NSFileCoordinator.removeFilePresenter) }
    for presenter in presenters {
      let name = presenter.sidecarURL.lastPathComponent
      var info = stat()
      if lstat(presenter.sidecarURL.path, &info) == 0 {
        throw SQLiteFileBackupError.journalFileNextToDestination(name)
      }
      if errno != ENOENT { throw SQLiteFileBackupError.journalFileUncheckable(name) }
    }
  }

  /// Runs the backup from `sourcePath` into a new database at `targetPath`
  private static func backup(
    from sourcePath: String, to targetPath: String,
    progress: @Sendable (Progress) -> Void
  ) async throws -> Progress {
    let source = try open(sourcePath, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
    defer { sqlite3_close_v2(source) }
    let target = try open(
      targetPath, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX)
    defer { sqlite3_close_v2(target) }
    guard let backup = sqlite3_backup_init(target, "main", source, "main") else {
      throw error(target, code: sqlite3_extended_errcode(target))
    }
    var finished = false
    defer { if !finished { sqlite3_backup_finish(backup) } }
    var busy = 0
    var state = Progress(pagesCopied: 0, pageCount: 0)
    var step = SQLITE_OK
    while true {
      step = sqlite3_backup_step(backup, pagesPerStep)
      if step == SQLITE_BUSY || step == SQLITE_LOCKED {
        busy += 1
        guard busy <= busyRetries else { break }
        try await Task.sleep(for: busyRetryDelay)
        continue
      }
      guard step == SQLITE_OK || step == SQLITE_DONE else { break }
      busy = 0
      let total = Int(sqlite3_backup_pagecount(backup))
      state = Progress(pagesCopied: total - Int(sqlite3_backup_remaining(backup)), pageCount: total)
      progress(state)
      if step == SQLITE_DONE { break }
      try Task.checkCancellation()
    }
    finished = true
    let code = sqlite3_backup_finish(backup)
    // finish reports OK after a step that stayed busy, so the step's code decides first
    guard step == SQLITE_DONE else { throw error(target, code: step) }
    guard code == SQLITE_OK else { throw error(target, code: code) }
    return state
  }

  /// Opens the copy read-write (a WAL copy's `-wal` and `-shm` go away on close) and requires
  /// `PRAGMA integrity_check` to return the single row `ok`
  private static func checkIntegrity(_ path: String) throws {
    let db = try open(path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX)
    defer { sqlite3_close_v2(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
      let prepared = statement
    else { throw error(db, code: sqlite3_extended_errcode(db)) }
    defer { sqlite3_finalize(prepared) }
    var lines: [String] = []
    var code = sqlite3_step(prepared)
    while code == SQLITE_ROW {
      lines.append(sqlite3_column_text(prepared, 0).map { String(cString: $0) } ?? "")
      code = sqlite3_step(prepared)
    }
    guard code == SQLITE_DONE else { throw error(db, code: sqlite3_extended_errcode(db)) }
    guard lines == ["ok"] else {
      throw SQLiteFileBackupError.integrityCheckFailed(lines.joined(separator: "\n"))
    }
  }

  private static func open(_ path: String, flags: Int32) throws -> OpaquePointer {
    var handle: OpaquePointer?
    let code = sqlite3_open_v2(path, &handle, flags, nil)
    guard code == SQLITE_OK, let db = handle else {
      let failure = error(handle, code: code)
      sqlite3_close_v2(handle)
      throw failure
    }
    sqlite3_extended_result_codes(db, 1)
    return db
  }

  private static func error(_ db: OpaquePointer?, code: Int32) -> SQLiteSessionError {
    let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) }
    return SQLiteSessionError(
      extendedCode: code, message: message ?? String(cString: sqlite3_errstr(code)))
  }

  /// Deletes the file at `url` and any journal file next to it
  private static func removeDatabaseFiles(at url: URL) {
    for suffix in [""] + SQLiteFileAccess.sidecarSuffixes {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }
}
