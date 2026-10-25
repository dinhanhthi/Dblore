// PluginManager.swift
// Downloads, verifies, installs, removes and loads one optional plugin pinned by an entry of
// PluginCatalog.json: a library (dlopen'd here) or a zipped loadable bundle (unpacked, its
// signature checked, then installed; loaded by its runtime). `PluginRegistry` holds one manager
// per entry, keyed by id.

import Foundation
import Observation

nonisolated enum PluginState: Equatable, Sendable {
  /// Initial state until the first `refresh()` has checked the installed plugin.
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
  /// A bundle zip holds more than the one bundle, a symlink, or a bundle not laid out as pinned.
  case invalidArchive
  /// The bundle verifier refused the unpacked bundle (Team ID, cdhash or sealed resources).
  case untrustedBundle
  case io(String)

  var errorDescription: String? {
    switch self {
    case .catalogUnavailable: "The plugin catalog entry is missing or invalid."
    case .notInstalled: "The plugin is not installed."
    case .httpStatus(let code): "The download failed (HTTP \(code))."
    case .insecureRedirect: "The download was redirected to a non-HTTPS address."
    case .tooLarge: "The download is larger than expected and was stopped."
    case .integrityMismatch: "The downloaded file does not match the expected checksum."
    case .invalidArchive: "The downloaded plugin archive is not laid out as expected."
    case .untrustedBundle: "The downloaded plugin is not signed as expected."
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
  /// True after Remove while the plugin's code is loaded in this process, or after a reinstall of
  /// a loaded bundle: the loaded code stays until the app quits.
  private(set) var requiresRestartToUnload = false

  nonisolated let entry: PluginCatalogEntry
  nonisolated let root: URL
  /// `root/<id>`, `root/<id>/<version>/<libraryFileName or bundleName>` and
  /// `root/.staging/<id>`; nil when the entry would not pass the catalog rules, and then install,
  /// remove and load do nothing or fail.
  nonisolated private let paths: (directory: URL, installed: URL, staging: URL)?
  private let session: URLSession
  /// The loaded library, or only the loaded flag of a bundle (`markBundleLoaded`).
  private let libraryCache = LibraryCache()
  /// Bumped by install and remove so an older refresh never overwrites their result.
  private var generation = 0
  private var activeTask: URLSessionTask?
  private var cancelRequested = false
  /// Cheap existence check from init, used only while `.checking`.
  @ObservationIgnored private var hasInstalledFile = false
  /// The launch `refresh()`, awaited by connects that start before it ends.
  @ObservationIgnored private var launchCheck: Task<Void, Never>?
  /// Awaited by `remove()` before the plugin's files are deleted, e.g. to stop a loaded bundle's
  /// runtime from taking requests.
  @ObservationIgnored var beforeRemove: (@MainActor () async -> Void)?
  private let verifyBundle: BundleVerifier

  /// Checks an unpacked bundle, still in staging, against the entry's cdhash before it is
  /// installed; throws to refuse it. Runs off the main actor.
  typealias BundleVerifier = @Sendable (_ bundle: URL, _ cdhash: String) throws -> Void

  /// `verifyBundle` defaults to `PluginLoader.verifyBundle` with the app's Team ID: the signature
  /// chains to Apple, carries the pinned cdhash and seals every resource.
  init(
    entry: PluginCatalogEntry,
    root: URL = PluginManager.defaultRoot,
    session: URLSession = PluginManager.downloadSession(),
    verifyBundle: @escaping BundleVerifier = { bundle, cdhash in
      _ = try PluginLoader.verifyBundle(
        at: bundle, expectedTeamID: PluginLoader.teamIdentifier, expectedCDHash: cdhash)
    }
  ) {
    self.entry = entry
    self.root = root
    self.session = session
    self.verifyBundle = verifyBundle
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
  /// build installed DuckDB at, so an existing install is found as is), or
  /// `root/<id>/<version>/<bundleName>` for a bundle.
  nonisolated var installedURL: URL? { paths?.installed }

  /// The paths only when id, version and the library file name or bundle name pass the catalog
  /// rules and each stays one component below its parent (no "." or ".." segment): the name is
  /// the last component and the version directory is its direct parent inside `root/<id>`.
  /// Staging is `root/.staging/<id>`, so an install never empties anything else.
  private nonisolated static func paths(
    for entry: PluginCatalogEntry, root: URL
  ) -> (directory: URL, installed: URL, staging: URL)? {
    let fileName: String
    let isBundle: Bool
    switch entry.kind {
    case .library(let name):
      guard PluginCatalogEntry.isValidLibraryFileName(name) else { return nil }
      (fileName, isBundle) = (name, false)
    case .bundle(let name, _, _):
      guard PluginCatalogEntry.isValidBundleName(name) else { return nil }
      (fileName, isBundle) = (name, true)
    }
    guard PluginCatalogEntry.isValidID(entry.id),
      PluginCatalogEntry.isValidVersion(entry.version)
    else { return nil }
    let directory = root.appendingPathComponent(entry.id, isDirectory: true)
    let versionDirectory = directory.appendingPathComponent(entry.version, isDirectory: true)
    let installed = versionDirectory.appendingPathComponent(fileName, isDirectory: isBundle)
    let staging = root.appendingPathComponent(".staging", isDirectory: true)
      .appendingPathComponent(entry.id, isDirectory: true)
    guard installed.lastPathComponent == fileName,
      installed.standardized.path == installed.path,
      installed.deletingLastPathComponent().path == versionDirectory.path,
      installed.path == versionDirectory.path + "/" + fileName,
      versionDirectory.path == directory.path + "/" + entry.version,
      directory.path == root.path + "/" + entry.id,
      staging.path == root.path + "/.staging/" + entry.id
    else { return nil }
    return (directory, installed, staging)
  }

  // MARK: - Queries

  /// Cached: the plugin passed the last install or launch check (a library's SHA-256, a bundle's
  /// layout).
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

  /// Checks the installed plugin off the main actor (`installedSize`) and publishes
  /// installed/notInstalled.
  func refresh() async {
    guard !isTransferring else { return }
    guard let url = installedURL else {
      if state == .checking { state = .notInstalled }
      return
    }
    let token = generation
    let size = await Self.installedSize(of: url, entry: entry)
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

  /// Downloads into `.staging`, verifies size and SHA-256, then moves the file into place; a
  /// bundle zip is first unpacked and checked in staging (`installBundle`). Ignored while busy.
  /// Nothing is installed unless every check passes.
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
    let staged = staging.appendingPathComponent("\(UUID().uuidString)-\(entry.kind.assetName)")
    do {
      let file = try await Self.prepareStaging(staging, file: staged)
      try checkCancelled()
      #if DEBUG
        // DEBUG-only QA seam for installing an unpublished plugin: `-DbloreDevPluginDir <dir>`
        // copies the asset from `<dir>` when it is there instead of downloading it; every check
        // below still runs.
        if let source = Self.devPluginAsset(entry.kind.assetName) {
          try await Self.copyDevAsset(source, into: file)
        } else {
          try await download(entry: entry, into: file)
        }
      #else
        try await download(entry: entry, into: file)
      #endif
      try checkCancelled()
      state = .verifying
      let sha = try await PluginIntegrity.sha256(of: staged, maxSize: entry.maxSize)
      guard sha == entry.sha256 else { throw PluginManagerError.integrityMismatch }
      try checkCancelled()
      let size: Int64
      switch entry.kind {
      case .library:
        size = try await Self.commit(staged, to: target)
      case .bundle(let name, let identifier, let cdhash):
        size = try await installBundle(
          zip: staged, staging: staging, to: target, name: name, identifier: identifier,
          cdhash: cdhash)
      }
      await Self.removeDirectory(staging)
      // Loaded code always comes from `entry.version` (the entry is fixed per manager), which is
      // kept anyway; skip pruning while it is loaded to stay safe.
      if !libraryCache.isLoaded {
        await Self.pruneOtherVersions(in: directory, keeping: entry.version)
      }
      state = .installed(version: entry.version, size: size)
      // `Bundle` keeps the image it loaded for this path: the new files need a restart.
      if case .bundle = entry.kind, libraryCache.isLoaded { requiresRestartToUnload = true }
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

  /// Unpacks the verified zip into `staging/<uuid>`, checks its layout and then its signature
  /// (`verifyBundle`) while it is still in staging, and moves the bundle to `target`. Returns its
  /// size.
  private func installBundle(
    zip: URL, staging: URL, to target: URL, name: String, identifier: String, cdhash: String
  ) async throws -> Int64 {
    let (bundle, size) = try await Self.unpack(
      zip, into: staging.appendingPathComponent(UUID().uuidString, isDirectory: true),
      name: name, identifier: identifier, version: entry.version, maxSize: entry.maxSize)
    try checkCancelled()
    try await Self.verify(bundle, cdhash: cdhash, with: verifyBundle)
    try checkCancelled()
    try await Self.commitBundle(
      bundle, to: target, aside: staging.appendingPathComponent("\(UUID().uuidString)-previous"))
    return size
  }

  /// Stops a download or verification; `install()` then deletes the staging directory.
  func cancel() {
    guard isTransferring else { return }
    cancelRequested = true
    activeTask?.cancel()
  }

  /// Awaits `beforeRemove`, then deletes the installed plugin (`root/<id>` only). Loaded code (a
  /// library or a bundle) stays until the app quits, so `requiresRestartToUnload` is set.
  func remove() async {
    guard !isBusy, let directory = pluginDirectory else { return }
    generation += 1
    if let beforeRemove {
      let token = generation
      await beforeRemove()
      // An install or another remove started meanwhile wins.
      guard token == generation, !isBusy else { return }
    }
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
      guard case .library = entry.kind, let url = installedURL else {
        throw PluginManagerError.catalogUnavailable
      }
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw PluginManagerError.notInstalled
      }
      let handle = try PluginLoader.open(
        at: url, expectedSHA256: entry.sha256, expectedTeamID: PluginLoader.teamIdentifier,
        maxSize: entry.maxSize)
      return try bind(handle, entry)
    }
  }

  /// Records that the plugin bundle was loaded into this process (call it right after
  /// `PluginLoader.loadBundle` succeeds, or fails with `bundleLoadFailed`, when part of its code
  /// may be mapped). A later Remove or reinstall then asks for a restart: the loaded code stays
  /// until the app quits, and `Bundle` keeps the loaded image for that path.
  nonisolated func markBundleLoaded() {
    libraryCache.markLoaded()
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

  #if DEBUG
    /// `<dir>/<name>` when the app was launched with `-DbloreDevPluginDir <dir>` and that file
    /// exists (DEBUG-only QA seam); nil otherwise, so a plugin whose asset is not there downloads
    /// as usual. A leading `~` is the user's real home, not the sandbox container, so the VM's
    /// ~/Downloads works under the downloads entitlement.
    private nonisolated static func devPluginAsset(_ name: String) -> URL? {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "-DbloreDevPluginDir"),
        arguments.indices.contains(index + 1)
      else { return nil }
      var path = arguments[index + 1]
      if path == "~" || path.hasPrefix("~/"), let home = getpwuid(getuid())?.pointee.pw_dir {
        path = String(cString: home) + path.dropFirst()
      }
      let asset = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
      return FileManager.default.fileExists(atPath: asset.path) ? asset : nil
    }

    /// Streams `source` into the staged file, as a download writes it, then closes the file.
    @concurrent private static func copyDevAsset(_ source: URL, into file: FileHandle) async throws
    {
      defer { try? file.close() }
      do {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
          try file.write(contentsOf: chunk)
        }
      } catch {
        throw PluginManagerError.io(error.localizedDescription)
      }
    }
  #endif

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
    case is PluginLoaderError: PluginManagerError.untrustedBundle.localizedDescription
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
    await excludeFromBackup(target)
    if let size = fileSize(target) { return size }
    await AppLogger.shared.warning(
      "Plugin \(target.lastPathComponent): cannot read installed size; using staged size",
      category: "Plugins")
    return stagedSize ?? 0
  }

  /// Best effort: excludes the installed plugin from backups; a failure is logged.
  private nonisolated static func excludeFromBackup(_ url: URL) async {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var installed = url
    do {
      try installed.setResourceValues(values)
    } catch {
      let message =
        "Plugin \(url.lastPathComponent): cannot exclude from backup: "
        + error.localizedDescription
      await AppLogger.shared.warning(message, category: "Plugins")
    }
  }

  private nonisolated static func fileSize(_ url: URL) -> Int64? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value
  }

  /// Size of the plugin at `url` when it passes the launch check, nil otherwise: a library hashes
  /// to the entry's SHA-256; a bundle is only laid out as pinned (`laidOutBundleSize`).
  @concurrent private static func installedSize(
    of url: URL, entry: PluginCatalogEntry
  ) async -> Int64? {
    switch entry.kind {
    case .library:
      guard
        let sha = try? await PluginIntegrity.sha256(of: url, maxSize: entry.maxSize),
        sha == entry.sha256
      else { return nil }
      return fileSize(url)
    case .bundle(_, let identifier, _):
      return laidOutBundleSize(at: url, identifier: identifier, version: entry.version)
    }
  }

  /// Unpacks `zip` with `/usr/bin/ditto -x -k` into the new directory `directory`, which must then
  /// hold exactly one entry, `name`, within the unpack ceiling (`fitsUnpackCeiling`, from the
  /// entry's `maxSize`) and laid out as pinned with no symlink anywhere (`laidOutBundleSize`).
  /// Only a zip whose SHA-256 matched the catalog gets here.
  @concurrent private static func unpack(
    _ zip: URL, into directory: URL, name: String, identifier: String, version: String,
    maxSize: Int64
  ) async throws -> (bundle: URL, size: Int64) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let status = try await runDitto(["-x", "-k", zip.path, directory.path])
    guard status == 0 else {
      throw PluginManagerError.io("cannot unpack \(zip.lastPathComponent) (ditto exit \(status))")
    }
    let bundle = directory.appendingPathComponent(name, isDirectory: true)
    let (sizeLimit, overflow) = maxSize.multipliedReportingOverflow(by: 8)
    var budget = (bytes: overflow ? Int64.max : sizeLimit, entries: 10_000)
    guard try FileManager.default.contentsOfDirectory(atPath: directory.path) == [name],
      fitsUnpackCeiling(atPath: bundle.path, budget: &budget),
      let size = laidOutBundleSize(at: bundle, identifier: identifier, version: version)
    else { throw PluginManagerError.invalidArchive }
    return (bundle, size)
  }

  /// Spends `budget` on the tree at `path`: one entry per file or directory, and each regular
  /// file's size in bytes. False as soon as either runs out (the unpacked bundle is refused: at
  /// most 8 × the entry's `maxSize` in 10,000 entries) or a path cannot be read. lstat: no link
  /// is followed; types other than directories and regular files are left to `laidOutBundleSize`.
  private nonisolated static func fitsUnpackCeiling(
    atPath path: String, budget: inout (bytes: Int64, entries: Int)
  ) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    budget.entries -= 1
    guard budget.entries >= 0 else { return false }
    switch info.st_mode & S_IFMT {
    case S_IFREG:
      budget.bytes -= Int64(info.st_size)
      return budget.bytes >= 0
    case S_IFDIR:
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
        return false
      }
      return names.allSatisfy { fitsUnpackCeiling(atPath: path + "/" + $0, budget: &budget) }
    default:
      return true
    }
  }

  /// Runs `/usr/bin/ditto` and returns its exit status, without blocking a thread while it runs.
  private nonisolated static func runDitto(_ arguments: [String]) async throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    defer { withExtendedLifetime(process) {} }
    return try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }

  @concurrent private static func verify(
    _ bundle: URL, cdhash: String, with verifier: BundleVerifier
  ) async throws {
    try verifier(bundle, cdhash)
  }

  /// Renames the checked bundle to `target`. A bundle already there is first renamed to `aside`
  /// (in staging, which the caller deletes), deleted once the new one is in, and put back if the
  /// rename in fails. Once the rename in succeeds the plugin is installed, so later failures are
  /// logged, not thrown.
  @concurrent private static func commitBundle(
    _ bundle: URL, to target: URL, aside: URL
  ) async throws {
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let hadPrevious = fileType(atPath: target.path) != nil
    if hadPrevious, rename(target.path, aside.path) != 0 {
      throw PluginManagerError.io(String(cString: strerror(errno)))
    }
    guard rename(bundle.path, target.path) == 0 else {
      let message = String(cString: strerror(errno))
      if hadPrevious, rename(aside.path, target.path) != 0 {
        // The previous bundle stays in staging, which the caller deletes.
        let reason = String(cString: strerror(errno))
        await AppLogger.shared.error(
          "Plugin \(target.lastPathComponent): cannot put the previous bundle back: \(reason)",
          category: "Plugins")
      }
      throw PluginManagerError.io(message)
    }
    if hadPrevious { try? FileManager.default.removeItem(at: aside) }
    await excludeFromBackup(target)
  }

  /// The summed size of the bundle's files when it is laid out as pinned, nil otherwise: a real
  /// directory with only directories and regular files below it (lstat: no link is followed),
  /// whose `Contents/Info.plist` names `identifier` and `version` and whose main executable
  /// `Contents/MacOS/<CFBundleExecutable>` is a regular file. Cheap: no hashing and no signature
  /// check (`PluginLoader.loadBundle` runs that before loading). Reads the plist directly, never
  /// through `Bundle`, which caches its first instance per path.
  private nonisolated static func laidOutBundleSize(
    at bundle: URL, identifier: String, version: String
  ) -> Int64? {
    let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
    guard fileType(atPath: bundle.path) == S_IFDIR,
      let size = treeSize(atPath: bundle.path),
      let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      info["CFBundleIdentifier"] as? String == identifier,
      info["CFBundleShortVersionString"] as? String == version,
      let executable = info["CFBundleExecutable"] as? String,
      !executable.isEmpty, !executable.contains("/"), executable != ".", executable != "..",
      fileType(atPath: contents.path + "/MacOS/" + executable) == S_IFREG
    else { return nil }
    return size
  }

  /// The file type bits of `path` from lstat (a symlink reports `S_IFLNK`); nil when it fails.
  private nonisolated static func fileType(atPath path: String) -> mode_t? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return info.st_mode & S_IFMT
  }

  /// The summed size of the regular files at and below `path`; nil when anything there is not a
  /// directory or a regular file (a symlink, FIFO, socket or device) or cannot be read.
  private nonisolated static func treeSize(atPath path: String) -> Int64? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    switch info.st_mode & S_IFMT {
    case S_IFREG:
      return Int64(info.st_size)
    case S_IFDIR:
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
        return nil
      }
      var total: Int64 = 0
      for name in names {
        guard let size = treeSize(atPath: path + "/" + name) else { return nil }
        total += size
      }
      return total
    default:
      return nil
    }
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
/// never waits on a load in progress. A plugin bundle is loaded by its runtime and only sets the
/// flag (`markLoaded`).
nonisolated final class LibraryCache: @unchecked Sendable {
  private let loadLock = NSLock()
  private var library: (any AnyObject & Sendable)?
  private let flagLock = NSLock()
  private var loaded = false

  var isLoaded: Bool { flagLock.withLock { loaded } }

  /// Sets `isLoaded` for code loaded outside the cache.
  func markLoaded() { flagLock.withLock { loaded = true } }

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
