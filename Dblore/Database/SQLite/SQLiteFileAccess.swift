// SQLiteFileAccess.swift
// Sandbox access for one SQLite or DuckDB file. Resolves the security-scoped bookmark, registers
// sidecar file presenters, then probes writability. `release()` drops presenters and stops
// access. Bookmarks go through `SecurityScopedAccess`.

import Foundation
import SQLite3
import os

/// Opens a SQLite file inside the App Sandbox and holds that access until `release()`.
nonisolated enum SQLiteFileAccess {
  /// Shown when the file is opened read-only because a sidecar could not be written.
  static let readOnlyBannerReason =
    "This database is open read-only. Allow its folder so Dblore can write the -wal, -shm, and -journal files."
  /// The DuckDB counterpart: the sandbox does not treat `data.duckdb.wal` as a related item
  /// (its base name is `data.duckdb`, not `data`), so writing needs the folder.
  static let duckDBReadOnlyBannerReason =
    "This database is open read-only. Allow its folder so Dblore can write the .wal file."

  /// Suffixes SQLite appends to the database path. Not a replacement extension.
  static let sidecarSuffixes = ["-wal", "-shm", "-journal"]
  /// DuckDB appends `.wal` to the database path (`data.duckdb.wal`).
  static let duckDBSidecarSuffixes = [".wal"]

  /// The write probe could not open a sidecar (`-wal`, `-shm`, or `-journal`).
  struct SidecarDenied: Error, Equatable {}

  enum Failure: Error, Equatable {
    case missingBookmark
    case accessNotGranted
  }

  /// Bookmark resolution, panels, presenters, and the write probe. Tests replace these.
  /// The live panel does not open under the test host (`FileAccessPanel`).
  @MainActor
  struct Hooks {
    var resolve: (Data) throws -> (url: URL, isStale: Bool) = {
      try SecurityScopedAccess.resolve($0)
    }
    var makeBookmark: (URL) -> Data? = { SecurityScopedAccess.bookmarkIfPossible(for: $0) }
    var startAccess: (URL) -> SecurityScopedAccessToken = { SecurityScopedAccessToken(url: $0) }
    var chooseFolder: @MainActor (URL) async -> URL? = { url in
      await FileAccessPanel.chooseFolder(
        containing: url,
        message:
          "Allow access to the folder \"\(url.deletingLastPathComponent().lastPathComponent)\" "
          + "so Dblore can write the journal files of \"\(url.lastPathComponent)\".")
    }
    /// Arbiter calls go through `presenterQueue`, in order, so none blocks the caller
    var addPresenter: (SidecarFilePresenter) -> Void = { presenter in
      presenterQueue.async { NSFileCoordinator.addFilePresenter(presenter) }
    }
    /// Once after the presenters of one open are added
    var waitForPresenters: () -> Void = { waitForPresenterRegistration() }
    var removePresenter: @Sendable (SidecarFilePresenter) -> Void = { presenter in
      presenterQueue.async { NSFileCoordinator.removeFilePresenter(presenter) }
    }
    var probe: (URL) throws -> Void = { url in
      try probeWritable(url)
    }
    var probeDuckDB: (URL) throws -> Void = { url in
      try probeDuckDBWAL(url)
    }

    static var live: Hooks { Hooks() }
  }

  /// One sidecar. `primaryPresentedItemURL` is the database; `presentedItemURL` is the sidecar.
  nonisolated final class SidecarFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let primaryURL: URL
    let sidecarURL: URL
    private let queue: OperationQueue

    var primaryPresentedItemURL: URL? { primaryURL }
    var presentedItemURL: URL? { sidecarURL }
    var presentedItemOperationQueue: OperationQueue { queue }

    init(primaryURL: URL, suffix: String, queue: OperationQueue) {
      self.primaryURL = primaryURL
      self.sidecarURL = URL(fileURLWithPath: primaryURL.path + suffix)
      self.queue = queue
      super.init()
    }
  }

  /// Longest wait for a file coordination call. Past it, checks go on without the grant and
  /// fail closed where the sandbox denies them.
  static let presenterRegistrationTimeout: DispatchTimeInterval = .seconds(2)
  /// Serial: a stalled arbiter holds one thread here, not one per wait. Once a block stalls,
  /// the queue stays blocked for the rest of the process: later opens and backups pay the
  /// timeout and fail closed, and queued adds and removals never run.
  static let presenterQueue = DispatchQueue(label: "dblore.sqlite.presenter-registration")

  /// Waits until the presenters added so far are registered, at most
  /// `presenterRegistrationTimeout`. Registration finishes asynchronously and reading the list
  /// waits for it. The arbiter registers a sidecar presenter with a synchronous request to the
  /// file coordination daemon, which has been seen never to answer. Returns false then.
  @discardableResult
  static func waitForPresenterRegistration() -> Bool {
    onPresenterQueue { _ = NSFileCoordinator.filePresenters }
  }

  /// Runs `work` on `presenterQueue` and waits for it at most `presenterRegistrationTimeout`,
  /// so a stalled arbiter stalls that queue, not the caller. Returns false when the wait ends.
  @discardableResult
  static func onPresenterQueue(_ work: @escaping @Sendable () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    presenterQueue.async {
      work()
      done.signal()
    }
    return done.wait(timeout: .now() + presenterRegistrationTimeout) == .success
  }

  /// Security scope and sidecar presenters for one open. `release()` is idempotent and
  /// safe to call from the connection actor on disconnect.
  nonisolated final class AccessGrant: @unchecked Sendable {
    let url: URL
    let readOnly: Bool
    /// Set when the file was opened read-only because a sidecar could not be written.
    let bannerReason: String?
    /// The bookmark to keep for the database file. A stale bookmark is replaced.
    let bookmark: Data?
    /// The folder bookmark from the one-time folder prompt. Nil when that prompt was declined.
    let folderBookmark: Data?

    private let removePresenter: @Sendable (SidecarFilePresenter) -> Void
    private let state: OSAllocatedUnfairLock<State>

    private struct State: Sendable {
      var released = false
      var presenters: [SidecarFilePresenter]
      var tokens: [SecurityScopedAccessToken]
    }

    fileprivate init(
      url: URL,
      readOnly: Bool,
      bannerReason: String?,
      bookmark: Data?,
      folderBookmark: Data?,
      presenters: [SidecarFilePresenter],
      tokens: [SecurityScopedAccessToken],
      removePresenter: @escaping @Sendable (SidecarFilePresenter) -> Void
    ) {
      self.url = url
      self.readOnly = readOnly
      self.bannerReason = bannerReason
      self.bookmark = bookmark
      self.folderBookmark = folderBookmark
      self.removePresenter = removePresenter
      state = OSAllocatedUnfairLock(
        initialState: State(presenters: presenters, tokens: tokens))
    }

    /// Removes sidecar presenters, then stops security-scoped access. Later calls do nothing.
    func release() {
      let held = state.withLock { state -> State? in
        if state.released { return nil }
        state.released = true
        return state
      }
      guard let held else { return }
      for presenter in held.presenters {
        removePresenter(presenter)
      }
      for token in held.tokens {
        token.release()
      }
    }

    deinit {
      release()
    }
  }

  /// Resolve `config.fileBookmark`, start access, register sidecar presenters, then probe.
  /// A sidecar denial asks once for the folder. Declining that prompt opens read-only.
  /// A read-write DuckDB file without a bookmark (just picked with "New File…", so it does not
  /// exist yet) uses the path as given: the save panel grant covers the file, not its `.wal`.
  @MainActor
  static func open(config: ConnectionConfig, hooks: Hooks = .live) async throws -> AccessGrant {
    let isDuckDB = config.databaseType == .duckdb
    let url: URL
    let bookmark: Data?
    var tokens: [SecurityScopedAccessToken] = []
    if let storedBookmark = config.fileBookmark {
      let resolved = try hooks.resolve(storedBookmark)
      let fileToken = hooks.startAccess(resolved.url)
      guard fileToken.isGranted else {
        fileToken.release()
        throw Failure.accessNotGranted
      }
      tokens.append(fileToken)
      url = resolved.url
      bookmark =
        resolved.isStale ? hooks.makeBookmark(resolved.url) ?? storedBookmark : storedBookmark
    } else if isDuckDB, !config.readOnlyFile {
      url = URL(fileURLWithPath: config.database)
      bookmark = nil
    } else {
      throw Failure.missingBookmark
    }

    let presenters = makePresenters(
      for: url, suffixes: isDuckDB ? duckDBSidecarSuffixes : sidecarSuffixes)
    for presenter in presenters {
      hooks.addPresenter(presenter)
    }
    hooks.waitForPresenters()

    var folderBookmark: Data?
    var readOnly = config.readOnlyFile
    var bannerReason: String?
    var keep = false
    defer {
      if !keep {
        for presenter in presenters {
          hooks.removePresenter(presenter)
        }
        for token in tokens {
          token.release()
        }
      }
    }

    if !config.readOnlyFile {
      let writable = try await recoverWritability(
        of: url, probe: isDuckDB ? hooks.probeDuckDB : hooks.probe, hooks: hooks,
        tokens: &tokens, folderBookmark: &folderBookmark)
      if !writable {
        readOnly = true
        bannerReason = isDuckDB ? duckDBReadOnlyBannerReason : readOnlyBannerReason
      }
    }

    keep = true
    return AccessGrant(
      url: url,
      readOnly: readOnly,
      bannerReason: bannerReason,
      bookmark: bookmark,
      folderBookmark: folderBookmark,
      presenters: presenters,
      tokens: tokens,
      removePresenter: hooks.removePresenter)
  }

  /// Opens `url` read-write, runs `BEGIN IMMEDIATE`, creates `<db>-journal` (then removes it)
  /// while that lock keeps other writers out, then rolls back. Does not create the database.
  /// The journal step matters in rollback-journal mode, where the transaction alone writes no
  /// sidecar and a denied journal would only fail at the first write (SQLITE_CANTOPEN).
  /// A permission-style failure after the main file is present is a sidecar denial.
  /// The error text is SQLite's message only: file bytes are never read into it.
  static func probeWritable(_ url: URL) throws {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
    let code = url.path.withCString { pointer in
      sqlite3_open_v2(pointer, &handle, flags, nil)
    }
    guard code == SQLITE_OK, let opened = handle else {
      let message = sqliteMessage(handle) ?? "unable to open database"
      let denied = FileManager.default.fileExists(atPath: url.path) && isSidecarDenial(code)
      sqlite3_close_v2(handle)
      if denied { throw SidecarDenied() }
      throw SQLiteSessionError(extendedCode: code, message: message)
    }
    defer { sqlite3_close_v2(opened) }
    sqlite3_extended_result_codes(opened, 1)

    var errorMessage: UnsafeMutablePointer<CChar>?
    let execCode = sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, &errorMessage)
    let message = errorMessage.map { String(cString: $0) }
    sqlite3_free(errorMessage)
    guard execCode == SQLITE_OK else {
      if isSidecarDenial(execCode) { throw SidecarDenied() }
      throw SQLiteSessionError(
        extendedCode: execCode, message: message ?? "BEGIN IMMEDIATE failed")
    }
    defer { sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil) }
    try probeCreatable(url.path + "-journal")
  }

  /// Creates `<db>.wal` (then removes it), or opens an existing one for writing without
  /// changing it. A permission error is a sidecar denial. The database file is not touched.
  static func probeDuckDBWAL(_ url: URL) throws {
    try probeCreatable(url.path + duckDBSidecarSuffixes[0])
  }

  /// Creates `path` (then removes it), or opens an existing one for writing without changing
  /// it. A permission error is a sidecar denial.
  private static func probeCreatable(_ path: String) throws {
    var fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    let created = fd >= 0
    if fd < 0, errno == EEXIST { fd = Darwin.open(path, O_WRONLY) }
    guard fd >= 0 else {
      let code = errno
      if code == EPERM || code == EACCES { throw SidecarDenied() }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    Darwin.close(fd)
    if created { unlink(path) }
  }

  @MainActor
  private static func recoverWritability(
    of url: URL, probe: (URL) throws -> Void, hooks: Hooks,
    tokens: inout [SecurityScopedAccessToken], folderBookmark: inout Data?
  ) async throws -> Bool {
    var askedForFolder = false
    while true {
      do {
        try probe(url)
        return true
      } catch is SidecarDenied {
        if askedForFolder { return false }
        askedForFolder = true
        guard let folder = await hooks.chooseFolder(url) else { return false }
        tokens.append(hooks.startAccess(folder))
        folderBookmark = hooks.makeBookmark(folder)
      }
    }
  }

  private static func makePresenters(for url: URL, suffixes: [String]) -> [SidecarFilePresenter] {
    let queue = OperationQueue()
    queue.name = "dblore.sqlite.file-presenter"
    queue.maxConcurrentOperationCount = 1
    return suffixes.map { suffix in
      SidecarFilePresenter(primaryURL: url, suffix: suffix, queue: queue)
    }
  }

  private static func isSidecarDenial(_ code: Int32) -> Bool {
    switch code & 0xFF {
    case SQLITE_PERM, SQLITE_READONLY, SQLITE_IOERR, SQLITE_CANTOPEN, SQLITE_AUTH:
      true
    default:
      false
    }
  }

  /// An extended result code of a read-only file's first `mode=ro` read that `immutable=1` can
  /// get past: the -shm or -wal cannot be opened or created, or another connection holds a lock
  /// past the busy timeout. Other I/O errors are real and are not hidden.
  static func isReadProbeFallback(_ extendedCode: Int32) -> Bool {
    switch extendedCode & 0xFF {
    case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_AUTH, SQLITE_BUSY, SQLITE_LOCKED: return true
    default: break
    }
    // Swift does not import these sqlite3.h macros: READONLY_RECOVERY, READONLY_CANTINIT,
    // IOERR_SHMOPEN, IOERR_SHMSIZE, IOERR_SHMLOCK, IOERR_SHMMAP
    let readOnlyCodes: [Int32] = [SQLITE_READONLY | 1 << 8, SQLITE_READONLY | 5 << 8]
    let shmCodes: [Int32] = (18...21).map { SQLITE_IOERR | $0 << 8 }
    return (readOnlyCodes + shmCodes).contains(extendedCode)
  }

  private static func sqliteMessage(_ handle: OpaquePointer?) -> String? {
    guard let handle else { return nil }
    return String(cString: sqlite3_errmsg(handle))
  }
}
