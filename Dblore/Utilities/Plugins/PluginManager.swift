// PluginManager.swift
// Downloads, verifies, installs, removes and loads one optional plugin pinned by an entry of
// PluginCatalog.json. `PluginRegistry` holds one manager per entry, keyed by id.

import Foundation
import Observation

nonisolated enum PluginState: Equatable, Sendable {
  /// Initial state until the first `refresh()` has hashed the installed file.
  case checking
  case notInstalled
  case downloading(Double)
  case verifying
  case installed(version: String, size: Int64)
  case failed(String)
}

nonisolated enum PluginManagerError: LocalizedError, Equatable {
  case catalogUnavailable
  case notInstalled
  case httpStatus(Int)
  case insecureRedirect
  case tooLarge
  case integrityMismatch
  case io(String)

  var errorDescription: String? {
    switch self {
    case .catalogUnavailable: "The plugin catalog entry is missing or invalid."
    case .notInstalled: "The plugin is not installed."
    case .httpStatus(let code): "The download failed (HTTP \(code))."
    case .insecureRedirect: "The download was redirected to a non-HTTPS address."
    case .tooLarge: "The download is larger than expected and was stopped."
    case .integrityMismatch: "The downloaded file does not match the expected checksum."
    case .io(let message): "The plugin file could not be written: \(message)"
    }
  }
}

/// The plugins of the bundled catalog, one `PluginManager` per entry. Immutable after init; the
/// managers are main-actor observable models read by views.
@MainActor
final class PluginRegistry {
  /// From the bundled catalog, each manager's launch check started. An invalid catalog is logged
  /// and leaves the registry empty, so no plugin is offered, downloaded or loaded.
  static let shared: PluginRegistry = {
    let registry = PluginRegistry(catalog: { try PluginCatalog.bundled() })
    for manager in registry.managers { manager.startLaunchCheck() }
    return registry
  }()

  /// In catalog order.
  let managers: [PluginManager]

  init(
    entries: [PluginCatalogEntry],
    root: URL = PluginManager.defaultRoot,
    session: URLSession = PluginManager.downloadSession()
  ) {
    managers = entries.map { PluginManager(entry: $0, root: root, session: session) }
  }

  /// One manager per entry of the catalog `load` returns. A load that throws is logged and leaves
  /// the registry empty.
  convenience init(
    catalog load: () throws -> PluginCatalog,
    root: URL = PluginManager.defaultRoot,
    session: URLSession = PluginManager.downloadSession()
  ) {
    let entries: [PluginCatalogEntry]
    do {
      entries = try load().plugins
    } catch {
      entries = []
      let message = "Plugin catalog unavailable: \(error.localizedDescription)"
      Task { await AppLogger.shared.error(message, category: "Plugins") }
    }
    self.init(entries: entries, root: root, session: session)
  }

  /// The manager for the catalog entry `id`; nil when the catalog has no such plugin.
  func manager(id: String) -> PluginManager? {
    managers.first { $0.entry.id == id }
  }
}

@MainActor
@Observable
final class PluginManager {
  typealias State = PluginState

  nonisolated static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dblore", isDirectory: true)
      .appendingPathComponent("Plugins", isDirectory: true)
  }

  private(set) var state: State = .checking
  /// True after Remove while the library is loaded: it stays mapped until the app quits.
  private(set) var requiresRestartToUnload = false

  nonisolated let entry: PluginCatalogEntry
  nonisolated let root: URL
  /// `root/<id>`, `root/<id>/<version>/<libraryFileName>` and `root/.staging/<id>`; nil when the
  /// entry would not pass the catalog rules, and then install, remove and load do nothing or fail.
  nonisolated private let paths: (directory: URL, library: URL, staging: URL)?
  private let session: URLSession
  private let libraryCache = LibraryCache()
  /// Bumped by install and remove so an older refresh never overwrites their result.
  private var generation = 0
  private var activeTask: URLSessionTask?
  private var cancelRequested = false
  /// Cheap existence check from init, used only while `.checking`.
  @ObservationIgnored private var hasInstalledFile = false
  /// The launch `refresh()`, awaited by connects that start before it ends.
  @ObservationIgnored private var launchCheck: Task<Void, Never>?

  init(
    entry: PluginCatalogEntry,
    root: URL = PluginManager.defaultRoot,
    session: URLSession = PluginManager.downloadSession()
  ) {
    self.entry = entry
    self.root = root
    self.session = session
    paths = Self.paths(for: entry, root: root)
    hasInstalledFile = installedURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
  }

  /// No disk cache: the dylib is ~117 MB and is verified from the staged file.
  nonisolated static func downloadSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
  }

  // MARK: - Paths

  /// `root/.staging/<id>`: one per plugin, since an install empties it.
  nonisolated var stagingDirectory: URL? { paths?.staging }

  /// `root/<id>`, e.g. Application Support/Dblore/Plugins/duckdb.
  nonisolated var pluginDirectory: URL? { paths?.directory }

  /// `root/<id>/<version>/<libraryFileName>`, e.g.
  /// Application Support/Dblore/Plugins/duckdb/1.5.6/libduckdb.dylib (the path every earlier
  /// build installed DuckDB at, so an existing install is found as is).
  nonisolated var installedURL: URL? { paths?.library }

  /// The paths only when id, version and file name pass the catalog rules and each stays one
  /// component below its parent (no "." or ".." segment): the file name is the last component
  /// and the version directory is its direct parent inside `root/<id>`. Staging is
  /// `root/.staging/<id>`, so an install never empties anything else.
  private nonisolated static func paths(
    for entry: PluginCatalogEntry, root: URL
  ) -> (directory: URL, library: URL, staging: URL)? {
    guard PluginCatalogEntry.isValidID(entry.id),
      PluginCatalogEntry.isValidVersion(entry.version),
      PluginCatalogEntry.isValidLibraryFileName(entry.libraryFileName)
    else { return nil }
    let directory = root.appendingPathComponent(entry.id, isDirectory: true)
    let versionDirectory = directory.appendingPathComponent(entry.version, isDirectory: true)
    let library = versionDirectory.appendingPathComponent(
      entry.libraryFileName, isDirectory: false)
    let staging = root.appendingPathComponent(".staging", isDirectory: true)
      .appendingPathComponent(entry.id, isDirectory: true)
    guard library.lastPathComponent == entry.libraryFileName,
      library.standardized.path == library.path,
      library.deletingLastPathComponent().path == versionDirectory.path,
      library.path == versionDirectory.path + "/" + entry.libraryFileName,
      versionDirectory.path == directory.path + "/" + entry.version,
      directory.path == root.path + "/" + entry.id,
      staging.path == root.path + "/.staging/" + entry.id
    else { return nil }
    return (directory, library, staging)
  }

  // MARK: - Queries

  /// Cached: the file was present and matched the catalog SHA-256 at the last install/refresh.
  var isInstalled: Bool {
    if case .installed = state { return true }
    return false
  }

  /// Installed, or still checking a file that exists: keep the plugin's engine (DuckDB) offered
  /// in the picker and don't report a saved connection as missing its plugin.
  var isInstalledOrPending: Bool {
    switch state {
    case .installed: true
    case .checking: hasInstalledFile
    default: false
    }
  }

  /// `isInstalled` once the launch check is done: a connect made while `.checking` (a workspace
  /// auto-connecting at launch) waits for the hash instead of reporting the plugin as missing.
  func isInstalledAfterLaunchCheck() async -> Bool {
    if state == .checking { await launchCheck?.value }
    return isInstalled
  }

  var isBusy: Bool {
    switch state {
    case .checking, .downloading, .verifying: true
    default: false
    }
  }

  private var isTransferring: Bool {
    switch state {
    case .downloading, .verifying: true
    default: false
    }
  }

  /// Starts the launch `refresh()` that `isInstalledAfterLaunchCheck()` waits for.
  func startLaunchCheck() {
    launchCheck = Task { await refresh() }
  }

  /// Hashes the installed file off the main actor and publishes installed/notInstalled.
  func refresh() async {
    guard !isTransferring else { return }
    guard let url = installedURL else {
      if state == .checking { state = .notInstalled }
      return
    }
    let token = generation
    let size = await Self.verifiedSize(of: url, entry: entry)
    guard token == generation, !isTransferring else { return }
    if let size {
      state = .installed(version: entry.version, size: size)
    } else if case .failed = state {
      // Keep the last error visible.
    } else {
      state = .notInstalled
    }
  }

  // MARK: - Actions

  /// Downloads into `.staging`, verifies size and SHA-256, then moves the file into place.
  /// Ignored while busy. Nothing is installed unless every check passes.
  func install() async {
    guard !isBusy else { return }
    guard let target = installedURL, let directory = pluginDirectory,
      let staging = stagingDirectory
    else {
      state = .failed(PluginManagerError.catalogUnavailable.localizedDescription)
      return
    }
    let entry = entry
    generation += 1
    cancelRequested = false
    state = .downloading(0)
    let staged = staging.appendingPathComponent("\(UUID().uuidString)-\(entry.libraryFileName)")
    do {
      let file = try await Self.prepareStaging(staging, file: staged)
      try checkCancelled()
      try await download(entry: entry, into: file)
      try checkCancelled()
      state = .verifying
      let sha = try await PluginIntegrity.sha256(of: staged, maxSize: entry.maxSize)
      guard sha == entry.sha256 else { throw PluginManagerError.integrityMismatch }
      try checkCancelled()
      let size = try await Self.commit(staged, to: target)
      await Self.removeDirectory(staging)
      // A loaded library always comes from `entry.version` (the entry is fixed per manager),
      // which is kept anyway; skip pruning while one is mapped to stay safe.
      if !libraryCache.isLoaded {
        await Self.pruneOtherVersions(in: directory, keeping: entry.version)
      }
      state = .installed(version: entry.version, size: size)
    } catch {
      await Self.removeDirectory(staging)
      if cancelRequested || error is CancellationError {
        state = .notInstalled
      } else {
        state = .failed(Self.message(for: error))
      }
    }
    activeTask = nil
    cancelRequested = false
  }

  /// Stops a download or verification; `install()` then deletes the staging directory.
  func cancel() {
    guard isTransferring else { return }
    cancelRequested = true
    activeTask?.cancel()
  }

  /// Deletes the installed plugin (`root/<id>` only). A loaded library stays mapped until the
  /// app quits.
  func remove() async {
    guard !isBusy, let directory = pluginDirectory else { return }
    generation += 1
    do {
      try await Self.removeItem(directory)
      state = .notInstalled
      // Never blocks: `isLoaded` does not take the lock `load` holds while hashing.
      if libraryCache.isLoaded { requiresRestartToUnload = true }
    } catch {
      state = .failed(Self.message(for: error))
    }
  }

  /// Loads the installed plugin once per manager and caches it. `PluginLoader.open` checks the
  /// SHA-256 against the entry and the code-signature Team ID before dlopen; `bind` then resolves
  /// the plugin's symbols from the handle. Blocks while it hashes (~117 MB for DuckDB), so call
  /// it off the main actor.
  nonisolated func loadLibrary<Library: AnyObject & Sendable>(
    bind: (_ handle: UnsafeMutableRawPointer, _ entry: PluginCatalogEntry) throws -> Library
  ) throws -> Library {
    try libraryCache.load {
      guard let url = installedURL else { throw PluginManagerError.catalogUnavailable }
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw PluginManagerError.notInstalled
      }
      let handle = try PluginLoader.open(
        at: url, expectedSHA256: entry.sha256, expectedTeamID: PluginLoader.teamIdentifier,
        maxSize: entry.maxSize)
      return try bind(handle, entry)
    }
  }

  // MARK: - Download

  private func download(entry: PluginCatalogEntry, into file: FileHandle) async throws {
    let delegate = DownloadDelegate(file: file, maxSize: entry.maxSize) { [weak self] fraction in
      Task { @MainActor in self?.reportProgress(fraction) }
    }
    let task = session.dataTask(with: URLRequest(url: entry.url))
    task.delegate = delegate
    activeTask = task
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        delegate.start(task, continuation: continuation)
      }
    } onCancel: {
      task.cancel()
    }
  }

  private func reportProgress(_ fraction: Double) {
    guard case .downloading = state else { return }
    state = .downloading(fraction)
  }

  private func checkCancelled() throws {
    if cancelRequested { throw CancellationError() }
    try Task.checkCancellation()
  }

  private static func message(for error: Error) -> String {
    switch error {
    case let error as PluginManagerError: error.localizedDescription
    case PluginIntegrityError.tooLarge: PluginManagerError.tooLarge.localizedDescription
    case PluginIntegrityError.notRegularFile:
      PluginManagerError.integrityMismatch.localizedDescription
    case PluginIntegrityError.io(let message): PluginManagerError.io(message).localizedDescription
    default: error.localizedDescription
    }
  }

  // MARK: - File work (off the main actor)

  /// Empties the staging directory, sweeps legacy staged files, and opens a new staged file for
  /// writing.
  @concurrent private static func prepareStaging(
    _ staging: URL, file: URL
  ) async throws
    -> FileHandle
  {
    let manager = FileManager.default
    removeLegacyStagedFiles(in: staging.deletingLastPathComponent())
    try? manager.removeItem(at: staging)
    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
    guard manager.createFile(atPath: file.path, contents: nil) else {
      throw PluginManagerError.io("cannot create \(file.lastPathComponent)")
    }
    return try FileHandle(forWritingTo: file)
  }

  /// Best effort: deletes the regular files directly under `root/.staging`, left there by an older
  /// build's interrupted download (`libduckdb-<UUID>.dylib`, up to 128 MB). Symlinks and
  /// directories (other plugins' `.staging/<id>`) are left alone; no link is followed.
  private nonisolated static func removeLegacyStagedFiles(in stagingRoot: URL) {
    let manager = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    guard
      let items = try? manager.contentsOfDirectory(
        at: stagingRoot, includingPropertiesForKeys: keys)
    else { return }
    for item in items {
      guard let values = try? item.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true, values.isSymbolicLink == false
      else { continue }
      try? manager.removeItem(at: item)
    }
  }

  /// Atomically renames the verified file over `target` and excludes it from backups. Once the
  /// rename succeeds the plugin is installed, so later failures are logged, not thrown.
  @concurrent private static func commit(_ staged: URL, to target: URL) async throws -> Int64 {
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let stagedSize = fileSize(staged)
    guard rename(staged.path, target.path) == 0 else {
      throw PluginManagerError.io(String(cString: strerror(errno)))
    }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var installed = target
    do {
      try installed.setResourceValues(values)
    } catch {
      let message =
        "Plugin \(target.lastPathComponent): cannot exclude from backup: "
        + error.localizedDescription
      await AppLogger.shared.warning(message, category: "Plugins")
    }
    if let size = fileSize(target) { return size }
    await AppLogger.shared.warning(
      "Plugin \(target.lastPathComponent): cannot read installed size; using staged size",
      category: "Plugins")
    return stagedSize ?? 0
  }

  private nonisolated static func fileSize(_ url: URL) -> Int64? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value
  }

  /// Size of the file at `url` when it hashes to the entry's SHA-256; nil otherwise.
  @concurrent private static func verifiedSize(
    of url: URL, entry: PluginCatalogEntry
  ) async -> Int64? {
    guard
      let sha = try? await PluginIntegrity.sha256(of: url, maxSize: entry.maxSize),
      sha == entry.sha256
    else { return nil }
    return fileSize(url)
  }

  @concurrent private static func pruneOtherVersions(
    in directory: URL, keeping version: String
  )
    async
  {
    removeOtherVersions(in: directory, keeping: version)
  }

  /// Best effort: deletes `directory/<v>` for every real directory (never a symlink) whose name
  /// is a valid version other than `version`. Other names and failures are left alone.
  nonisolated static func removeOtherVersions(in directory: URL, keeping version: String) {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
    for name in names where name != version && PluginCatalogEntry.isValidVersion(name) {
      let path = directory.appendingPathComponent(name).path
      // attributesOfItem does not follow a symlink, so a link reports .typeSymbolicLink.
      guard let type = try? manager.attributesOfItem(atPath: path)[.type] as? FileAttributeType,
        type == .typeDirectory
      else { continue }
      try? manager.removeItem(atPath: path)
    }
  }

  @concurrent private static func removeDirectory(_ url: URL) async {
    try? FileManager.default.removeItem(at: url)
  }

  @concurrent private static func removeItem(_ url: URL) async throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}

/// Process-lifetime cache of the loaded library. `loadLock` serializes concurrent first loads
/// and is held across the slow hash and dlopen; `isLoaded` uses its own lock so the main actor
/// never waits on a load in progress.
nonisolated final class LibraryCache: @unchecked Sendable {
  private let loadLock = NSLock()
  private var library: (any AnyObject & Sendable)?
  private let flagLock = NSLock()
  private var loaded = false

  var isLoaded: Bool { flagLock.withLock { loaded } }

  /// The cached library, or `make()`'s on the first successful call. A library already loaded
  /// under another type is never loaded again: the call throws instead.
  func load<Library: AnyObject & Sendable>(_ make: () throws -> Library) throws -> Library {
    try loadLock.withLock {
      if let library {
        guard let typed = library as? Library else {
          throw PluginLoaderError.loadFailed("plugin already loaded as \(type(of: library))")
        }
        return typed
      }
      let made = try make()
      library = made
      flagLock.withLock { loaded = true }
      return made
    }
  }
}

/// Streams a data task into the staged file, enforcing HTTP 200, https redirects and the
/// size cap as bytes arrive. Callbacks run serially on the session's delegate queue.
private nonisolated final class DownloadDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let file: FileHandle
  private let maxSize: Int64
  private let progress: @Sendable (Double) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var failure: Error?
  private var received: Int64 = 0
  private var expected: Int64 = 0
  private var lastReported = 0.0

  init(file: FileHandle, maxSize: Int64, progress: @escaping @Sendable (Double) -> Void) {
    self.file = file
    self.maxSize = maxSize
    self.progress = progress
  }

  func start(_ task: URLSessionTask, continuation: CheckedContinuation<Void, Error>) {
    lock.withLock { self.continuation = continuation }
    task.resume()
  }

  private func fail(_ error: Error, _ task: URLSessionTask) {
    lock.withLock { if failure == nil { failure = error } }
    task.cancel()
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status != 200 {
      fail(PluginManagerError.httpStatus(status), dataTask)
      completionHandler(.cancel)
    } else if response.expectedContentLength > maxSize {
      fail(PluginManagerError.tooLarge, dataTask)
      completionHandler(.cancel)
    } else {
      lock.withLock { expected = response.expectedContentLength }
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let (total, failed, expected) = lock.withLock {
      received += Int64(data.count)
      return (received, failure != nil, self.expected)
    }
    guard !failed else { return }
    guard total <= maxSize else {
      fail(PluginManagerError.tooLarge, dataTask)
      return
    }
    do {
      try file.write(contentsOf: data)
    } catch {
      fail(PluginManagerError.io(error.localizedDescription), dataTask)
      return
    }
    guard expected > 0 else { return }
    let fraction = min(1, Double(total) / Double(expected))
    let report = lock.withLock {
      guard fraction - lastReported >= 0.01 || fraction == 1 else { return false }
      lastReported = fraction
      return true
    }
    if report { progress(fraction) }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    if request.url?.scheme == "https" {
      completionHandler(request)
    } else {
      fail(PluginManagerError.insecureRedirect, task)
      completionHandler(nil)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    try? file.close()
    let (continuation, failure) = lock.withLock {
      defer { self.continuation = nil }
      return (self.continuation, self.failure)
    }
    if let error = failure ?? error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
  }
}
