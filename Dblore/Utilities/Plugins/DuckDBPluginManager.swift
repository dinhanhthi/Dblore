// DuckDBPluginManager.swift
// Downloads, verifies, installs, removes and loads the optional DuckDB plugin (libduckdb.dylib)
// pinned by DuckDBPluginCatalog.json.

import Foundation
import Observation

nonisolated enum DuckDBPluginState: Equatable, Sendable {
  /// Initial state until the first `refresh()` has hashed the installed file.
  case checking
  case notInstalled
  case downloading(Double)
  case verifying
  case installed(version: String, size: Int64)
  case failed(String)
}

nonisolated enum DuckDBPluginError: LocalizedError, Equatable {
  case catalogUnavailable
  case notInstalled
  case httpStatus(Int)
  case insecureRedirect
  case tooLarge
  case integrityMismatch
  case io(String)

  var errorDescription: String? {
    switch self {
    case .catalogUnavailable: "The DuckDB plugin catalog is missing or invalid."
    case .notInstalled: "The DuckDB plugin is not installed."
    case .httpStatus(let code): "The download failed (HTTP \(code))."
    case .insecureRedirect: "The download was redirected to a non-HTTPS address."
    case .tooLarge: "The download is larger than expected and was stopped."
    case .integrityMismatch: "The downloaded file does not match the expected checksum."
    case .io(let message): "The plugin file could not be written: \(message)"
    }
  }
}

@MainActor
@Observable
final class DuckDBPluginManager {
  typealias State = DuckDBPluginState

  /// Team ID the plugin must be signed with (same as the app).
  nonisolated static let teamIdentifier = "86H6CNLN4C"

  static let shared: DuckDBPluginManager = {
    let manager = DuckDBPluginManager(catalog: try? DuckDBPluginCatalog.bundled())
    Task { await manager.refresh() }
    return manager
  }()

  nonisolated static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dblore", isDirectory: true)
      .appendingPathComponent("Plugins", isDirectory: true)
  }

  private(set) var state: State = .checking
  /// True after Remove while the library is loaded: it stays mapped until the app quits.
  private(set) var requiresRestartToUnload = false

  /// nil when the bundled catalog is missing or invalid; install and load then fail.
  nonisolated let catalog: DuckDBPluginCatalog?
  nonisolated let root: URL
  private let session: URLSession
  private let libraryCache = LibraryCache()
  /// Bumped by install and remove so an older refresh never overwrites their result.
  private var generation = 0
  private var activeTask: URLSessionTask?
  private var cancelRequested = false
  /// Cheap existence check from init, used only while `.checking`.
  @ObservationIgnored private var hasInstalledFile = false

  init(
    catalog: DuckDBPluginCatalog?,
    root: URL = DuckDBPluginManager.defaultRoot,
    session: URLSession = DuckDBPluginManager.downloadSession()
  ) {
    self.catalog = catalog
    self.root = root
    self.session = session
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

  nonisolated var stagingDirectory: URL {
    root.appendingPathComponent(".staging", isDirectory: true)
  }

  nonisolated var pluginDirectory: URL {
    root.appendingPathComponent("duckdb", isDirectory: true)
  }

  /// Application Support/Dblore/Plugins/duckdb/<version>/libduckdb.dylib
  nonisolated var installedURL: URL? {
    catalog.map {
      pluginDirectory.appendingPathComponent($0.version, isDirectory: true)
        .appendingPathComponent("libduckdb.dylib")
    }
  }

  // MARK: - Queries

  /// Cached: the file was present and matched the catalog SHA-256 at the last install/refresh.
  var isInstalled: Bool {
    if case .installed = state { return true }
    return false
  }

  /// Installed, or still checking a file that exists: keep DuckDB offered in the picker and
  /// don't report a saved DuckDB connection as missing its plugin.
  var isInstalledOrPending: Bool {
    switch state {
    case .installed: true
    case .checking: hasInstalledFile
    default: false
    }
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

  /// Hashes the installed file off the main actor and publishes installed/notInstalled.
  func refresh() async {
    guard !isTransferring else { return }
    guard let catalog, let url = installedURL else {
      if state == .checking { state = .notInstalled }
      return
    }
    let token = generation
    let size = await Self.verifiedSize(of: url, catalog: catalog)
    guard token == generation, !isTransferring else { return }
    if let size {
      state = .installed(version: catalog.version, size: size)
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
    guard let catalog, let target = installedURL else {
      state = .failed(DuckDBPluginError.catalogUnavailable.localizedDescription)
      return
    }
    generation += 1
    cancelRequested = false
    state = .downloading(0)
    let staging = stagingDirectory
    let staged = staging.appendingPathComponent("libduckdb-\(UUID().uuidString).dylib")
    do {
      let file = try await Self.prepareStaging(staging, file: staged)
      try checkCancelled()
      try await download(catalog: catalog, into: file)
      try checkCancelled()
      state = .verifying
      let sha = try await PluginIntegrity.sha256(of: staged, maxSize: catalog.maxSize)
      guard sha == catalog.sha256 else { throw DuckDBPluginError.integrityMismatch }
      try checkCancelled()
      let size = try await Self.commit(staged, to: target)
      await Self.removeDirectory(staging)
      // A loaded library always comes from `catalog.version` (the catalog is fixed per
      // manager), which is kept anyway; skip pruning while one is mapped to stay safe.
      if !libraryCache.isLoaded {
        await Self.pruneOtherVersions(in: pluginDirectory, keeping: catalog.version)
      }
      state = .installed(version: catalog.version, size: size)
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

  /// Deletes the installed plugin. A loaded library stays mapped until the app quits.
  func remove() async {
    guard !isBusy else { return }
    generation += 1
    do {
      try await Self.removeItem(pluginDirectory)
      state = .notInstalled
      // Never blocks: `isLoaded` does not take the lock `load` holds while hashing.
      if libraryCache.isLoaded { requiresRestartToUnload = true }
    } catch {
      state = .failed(Self.message(for: error))
    }
  }

  /// Loads the installed plugin once per manager and caches it. Each dlopen is preceded by a
  /// SHA-256 check against the catalog and a code-signature Team ID check. Blocks while it hashes
  /// (~117 MB), so call it off the main actor.
  nonisolated func loadLibrary() throws -> DuckDBLibrary {
    try libraryCache.load {
      guard let catalog, let url = installedURL else {
        throw DuckDBPluginError.catalogUnavailable
      }
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw DuckDBPluginError.notInstalled
      }
      return try DuckDBLibrary.load(
        at: url, expectedSHA256: catalog.sha256, expectedVersion: catalog.version,
        expectedTeamID: Self.teamIdentifier, maxSize: catalog.maxSize)
    }
  }

  // MARK: - Download

  private func download(catalog: DuckDBPluginCatalog, into file: FileHandle) async throws {
    let delegate = DownloadDelegate(file: file, maxSize: catalog.maxSize) { [weak self] fraction in
      Task { @MainActor in self?.reportProgress(fraction) }
    }
    let task = session.dataTask(with: URLRequest(url: catalog.url))
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
    case let error as DuckDBPluginError: error.localizedDescription
    case PluginIntegrityError.tooLarge: DuckDBPluginError.tooLarge.localizedDescription
    case PluginIntegrityError.notRegularFile:
      DuckDBPluginError.integrityMismatch.localizedDescription
    case PluginIntegrityError.io(let message): DuckDBPluginError.io(message).localizedDescription
    default: error.localizedDescription
    }
  }

  // MARK: - File work (off the main actor)

  /// Empties the staging directory and opens a new staged file for writing.
  @concurrent private static func prepareStaging(
    _ staging: URL, file: URL
  ) async throws
    -> FileHandle
  {
    let manager = FileManager.default
    try? manager.removeItem(at: staging)
    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
    guard manager.createFile(atPath: file.path, contents: nil) else {
      throw DuckDBPluginError.io("cannot create \(file.lastPathComponent)")
    }
    return try FileHandle(forWritingTo: file)
  }

  /// Atomically renames the verified file over `target` and excludes it from backups. Once the
  /// rename succeeds the plugin is installed, so later failures are logged, not thrown.
  @concurrent private static func commit(_ staged: URL, to target: URL) async throws -> Int64 {
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let stagedSize = fileSize(staged)
    guard rename(staged.path, target.path) == 0 else {
      throw DuckDBPluginError.io(String(cString: strerror(errno)))
    }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var installed = target
    do {
      try installed.setResourceValues(values)
    } catch {
      let message = "DuckDB plugin: cannot exclude from backup: \(error.localizedDescription)"
      await AppLogger.shared.warning(message, category: "Plugins")
    }
    if let size = fileSize(target) { return size }
    await AppLogger.shared.warning(
      "DuckDB plugin: cannot read installed size; using staged size", category: "Plugins")
    return stagedSize ?? 0
  }

  private nonisolated static func fileSize(_ url: URL) -> Int64? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value
  }

  /// Size of the file at `url` when it hashes to the catalog SHA-256; nil otherwise.
  @concurrent private static func verifiedSize(
    of url: URL, catalog: DuckDBPluginCatalog
  ) async -> Int64? {
    guard
      let sha = try? await PluginIntegrity.sha256(of: url, maxSize: catalog.maxSize),
      sha == catalog.sha256
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
    for name in names where name != version && DuckDBPluginCatalog.isValidVersion(name) {
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
  private var library: DuckDBLibrary?
  private let flagLock = NSLock()
  private var loaded = false

  var isLoaded: Bool { flagLock.withLock { loaded } }

  func load(_ make: () throws -> DuckDBLibrary) throws -> DuckDBLibrary {
    try loadLock.withLock {
      if let library { return library }
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
      fail(DuckDBPluginError.httpStatus(status), dataTask)
      completionHandler(.cancel)
    } else if response.expectedContentLength > maxSize {
      fail(DuckDBPluginError.tooLarge, dataTask)
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
      fail(DuckDBPluginError.tooLarge, dataTask)
      return
    }
    do {
      try file.write(contentsOf: data)
    } catch {
      fail(DuckDBPluginError.io(error.localizedDescription), dataTask)
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
      fail(DuckDBPluginError.insecureRedirect, task)
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
