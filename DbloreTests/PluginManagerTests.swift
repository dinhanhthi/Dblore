import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite(.serialized)
struct PluginManagerTests {
  private static let payload = Data("pretend this is libduckdb".utf8)

  private static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func catalog(
    sha256: String = hex(payload), maxSize: Int64 = 1024
  )
    -> PluginCatalogEntry
  {
    PluginCatalogEntry(
      id: "duckdb", version: "1.5.6",
      url: URL(
        string:
          "https://github.com/dinhanhthi/Dblore/releases/download/plugin-duckdb-v1.5.6/libduckdb.dylib"
      )!,
      sha256: sha256, maxSize: maxSize, kind: .library(fileName: "libduckdb.dylib"))
  }

  private static func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("plugin-manager-\(UUID().uuidString)", isDirectory: true)
  }

  /// A manager past its launch check (`.checking` blocks install).
  private static func manager(
    _ catalog: PluginCatalogEntry, root: URL
  ) async -> PluginManager {
    let manager = unchecked(catalog, root: root)
    await manager.refresh()
    return manager
  }

  private static func unchecked(_ catalog: PluginCatalogEntry, root: URL) -> PluginManager {
    PluginManager(entry: catalog, root: root, session: PluginStubURLProtocol.makeSession())
  }

  private static func stagingIsEmpty(_ manager: PluginManager) -> Bool {
    guard let staging = manager.stagingDirectory else { return true }
    let items = try? FileManager.default.contentsOfDirectory(atPath: staging.path)
    return items?.isEmpty ?? true
  }

  private static func installedFileExists(_ manager: PluginManager) -> Bool {
    guard let url = manager.installedURL else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  // MARK: - Install

  @Test func successfulInstallIsVerifiedAndExcludedFromBackup() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    PluginStubURLProtocol.mode = .respond([Self.payload.prefix(10), Self.payload.dropFirst(10)])
    let manager = await Self.manager(Self.catalog(), root: root)

    await manager.install()

    #expect(manager.state == .installed(version: "1.5.6", size: Int64(Self.payload.count)))
    #expect(manager.isInstalled)
    let url = try #require(manager.installedURL)
    #expect(url.path.hasSuffix("/duckdb/1.5.6/libduckdb.dylib"))
    #expect(try Data(contentsOf: url) == Self.payload)
    #expect(
      try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect(Self.stagingIsEmpty(manager))

    // A fresh manager finds the file and checks its SHA-256.
    let fresh = await Self.manager(Self.catalog(), root: root)
    await fresh.refresh()
    #expect(fresh.isInstalled)
  }

  @Test func installRemovesOlderVersionDirectories() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = await Self.manager(Self.catalog(), root: root)
    let directory = try #require(manager.pluginDirectory)
    let old = directory.appendingPathComponent("1.4.0", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: old.appendingPathComponent("libduckdb.dylib"))
    PluginStubURLProtocol.mode = .respond([Self.payload])

    await manager.install()

    #expect(manager.isInstalled)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(Self.installedFileExists(manager))
  }

  @Test func pruningKeepsNonVersionsSymlinksAndTheKeptVersion() throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let plugins = root.appendingPathComponent("duckdb", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    let manager = FileManager.default
    for name in ["1.5.6", "1.4.0", "0.10", "beta", "1.2.x"] {
      try manager.createDirectory(
        at: plugins.appendingPathComponent(name, isDirectory: true),
        withIntermediateDirectories: true)
    }
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
    try manager.createSymbolicLink(
      at: plugins.appendingPathComponent("1.3.0"), withDestinationURL: outside)
    try Data("file".utf8).write(to: plugins.appendingPathComponent("1.3.9"))

    PluginManager.removeOtherVersions(in: plugins, keeping: "1.5.6")

    let left = Set(try manager.contentsOfDirectory(atPath: plugins.path))
    #expect(left == ["1.5.6", "beta", "1.2.x", "1.3.0", "1.3.9"])
    #expect(manager.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))
    // A missing plugin directory is not an error.
    PluginManager.removeOtherVersions(
      in: root.appendingPathComponent("missing", isDirectory: true), keeping: "1.5.6")
  }

  @Test func tamperedInstalledFileIsNotInstalled() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    PluginStubURLProtocol.mode = .respond([Self.payload])
    let manager = await Self.manager(Self.catalog(), root: root)
    await manager.install()
    try Data("swapped".utf8).write(to: try #require(manager.installedURL))

    await manager.refresh()

    #expect(manager.state == .notInstalled)
    // Load hashes again before dlopen, whatever the last refresh saw.
    #expect(throws: PluginLoaderError.integrityMismatch) { _ = try manager.loadDuckDBLibrary() }
  }

  @Test func shaMismatchInstallsNothing() async {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    PluginStubURLProtocol.mode = .respond([Self.payload])
    let manager = await Self.manager(
      Self.catalog(sha256: String(repeating: "0", count: 64)), root: root)

    await manager.install()

    guard case .failed = manager.state else {
      Issue.record("expected failed, got \(manager.state)")
      return
    }
    #expect(!Self.installedFileExists(manager))
    #expect(Self.stagingIsEmpty(manager))
  }

  @Test func oversizeDownloadIsAborted() async {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    PluginStubURLProtocol.mode = .respond([Self.payload])
    let manager = await Self.manager(Self.catalog(maxSize: 8), root: root)

    await manager.install()

    #expect(manager.state == .failed(PluginManagerError.tooLarge.localizedDescription))
    #expect(!Self.installedFileExists(manager))
    #expect(Self.stagingIsEmpty(manager))
  }

  @Test func cancelCleansStaging() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    PluginStubURLProtocol.mode = .hang(Self.payload.prefix(4))
    let manager = await Self.manager(Self.catalog(), root: root)

    let install = Task { await manager.install() }
    // Wait until the staged file holds the first chunk.
    for _ in 0..<200 where Self.stagingIsEmpty(manager) || !manager.isBusy {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!Self.stagingIsEmpty(manager))
    manager.cancel()
    await install.value

    #expect(manager.state == .notInstalled)
    #expect(!manager.isBusy)
    #expect(Self.stagingIsEmpty(manager))
    #expect(!Self.installedFileExists(manager))
  }

  /// Older builds staged `root/.staging/libduckdb-<UUID>.dylib`; a file left by a killed
  /// download is swept on install. Symlinks and other plugins' staging directories stay.
  @Test func installSweepsLegacyStagingFilesOnly() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = FileManager.default
    let legacy = try Self.seed(
      Data("partial".utf8), at: root, ".staging", "libduckdb-\(UUID().uuidString).dylib")
    let outside = try Self.seed(Data("keep".utf8), at: root, "outside.dylib")
    let link = root.appendingPathComponent(".staging/link.dylib")
    try manager.createSymbolicLink(at: link, withDestinationURL: outside)
    let other = try Self.seed(Data("other".utf8), at: root, ".staging", "fake-plugin", "x.dylib")
    PluginStubURLProtocol.mode = .respond([Self.payload])
    let plugin = await Self.manager(Self.catalog(), root: root)

    await plugin.install()

    #expect(plugin.isInstalled, "\(plugin.state)")
    #expect(!manager.fileExists(atPath: legacy.path))
    #expect((try? manager.destinationOfSymbolicLink(atPath: link.path)) == outside.path)
    #expect(try Data(contentsOf: outside) == Data("keep".utf8))
    #expect(try Data(contentsOf: other) == Data("other".utf8))
  }

  // MARK: - Launch check

  @Test func freshManagerIsCheckingAndBusyUntilRefresh() async {
    let manager = Self.unchecked(Self.catalog(), root: Self.tempRoot())
    #expect(manager.state == .checking)
    #expect(manager.isBusy)
    #expect(!manager.isInstalled)
    #expect(!manager.isInstalledOrPending, "no file on disk")

    await manager.install()
    #expect(manager.state == .checking, "install is ignored while checking")

    await manager.refresh()
    #expect(manager.state == .notInstalled)
    #expect(!manager.isBusy)
  }

  @Test func presentFileCountsAsPendingWhileChecking() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    PluginStubURLProtocol.mode = .respond([Self.payload])
    await Self.manager(Self.catalog(), root: root).install()

    let fresh = Self.unchecked(Self.catalog(), root: root)
    #expect(fresh.state == .checking)
    #expect(fresh.isInstalledOrPending)
    #expect(!fresh.isInstalled)

    await fresh.refresh()
    #expect(fresh.isInstalled)
    #expect(fresh.isInstalledOrPending)
  }

  @Test func connectDuringLaunchCheckWaitsForIt() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    PluginStubURLProtocol.mode = .respond([Self.payload])
    await Self.manager(Self.catalog(), root: root).install()

    let fresh = Self.unchecked(Self.catalog(), root: root)
    fresh.startLaunchCheck()
    #expect(fresh.state == .checking)
    #expect(await fresh.isInstalledAfterLaunchCheck(), "a connect at launch must not see no plugin")
  }

  /// An entry that would not pass the catalog rules never yields a path (staging included), so
  /// nothing is written or deleted under the plugin root.
  @Test(arguments: [
    PluginCatalogEntry(
      id: "..", version: "1.5.6", url: URL(string: "https://github.com/a/b")!,
      sha256: String(repeating: "0", count: 64), maxSize: 1024,
      kind: .library(fileName: "libduckdb.dylib")),
    PluginCatalogEntry(
      id: "duckdb", version: "../..", url: URL(string: "https://github.com/a/b")!,
      sha256: String(repeating: "0", count: 64), maxSize: 1024,
      kind: .library(fileName: "libduckdb.dylib")),
    PluginCatalogEntry(
      id: "duckdb", version: "1.5.6", url: URL(string: "https://github.com/a/b")!,
      sha256: String(repeating: "0", count: 64), maxSize: 1024,
      kind: .library(fileName: "../libduckdb.dylib")),
    PluginCatalogEntry(
      id: "local-ai", version: "1.0.0", url: URL(string: "https://github.com/a/b")!,
      sha256: String(repeating: "0", count: 64), maxSize: 1024,
      kind: .bundle(
        name: "../DbloreLocalAI.bundle", identifier: "ace.thi.Dblore.LocalAI",
        cdhash: String(repeating: "0", count: 40))),
  ])
  func invalidEntryHasNoPathAndInstallsNothing(_ entry: PluginCatalogEntry) async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = try Self.seed(Data("keep".utf8), at: root, "sentinel.txt")
    PluginStubURLProtocol.requestCount = 0
    let manager = Self.unchecked(entry, root: root)
    #expect(manager.installedURL == nil)
    #expect(manager.pluginDirectory == nil)
    #expect(manager.stagingDirectory == nil)

    await manager.refresh()
    #expect(manager.state == .notInstalled)
    await manager.install()
    #expect(manager.state == .failed(PluginManagerError.catalogUnavailable.localizedDescription))
    await manager.remove()
    #expect(throws: PluginManagerError.catalogUnavailable) { _ = try manager.loadDuckDBLibrary() }

    #expect(PluginStubURLProtocol.requestCount == 0)
    #expect(Self.contents(root) == ["sentinel.txt"])
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
  }

  @Test nonisolated func isLoadedDoesNotWaitForALoadInProgress() {
    struct Stop: Error {}
    final class Bound: Sendable {}
    let cache = LibraryCache()
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let loader = Thread {
      _ = try? cache.load { () throws -> Bound in
        started.signal()
        release.wait()
        throw Stop()
      }
    }
    loader.start()
    started.wait()
    defer { release.signal() }

    let answered = DispatchSemaphore(value: 0)
    Thread {
      _ = cache.isLoaded
      answered.signal()
    }.start()
    #expect(answered.wait(timeout: .now() + 2) == .success, "isLoaded blocked on the load lock")
    #expect(!cache.isLoaded)
  }

  // MARK: - Remove and load

  @Test func removeDeletesInstalledFile() async {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    PluginStubURLProtocol.mode = .respond([Self.payload])
    let manager = await Self.manager(Self.catalog(), root: root)
    await manager.install()
    #expect(manager.isInstalled)

    await manager.remove()

    #expect(manager.state == .notInstalled)
    #expect(!Self.installedFileExists(manager))
    #expect(!manager.requiresRestartToUnload)
  }

  @Test func loadWithoutInstallThrowsNotInstalled() async {
    let manager = await Self.manager(Self.catalog(), root: Self.tempRoot())
    #expect(throws: PluginManagerError.notInstalled) { _ = try manager.loadDuckDBLibrary() }
  }

  @Test func unsignedInstalledFileIsRefusedBeforeDlopen() async throws {
    // dlopen of this non-dylib would throw loadFailed; teamIDMismatch means it never ran.
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    PluginStubURLProtocol.mode = .respond([Self.payload])
    let manager = await Self.manager(Self.catalog(), root: root)
    await manager.install()

    #expect(throws: PluginLoaderError.teamIDMismatch(expected: "86H6CNLN4C", actual: nil)) {
      _ = try manager.loadDuckDBLibrary()
    }
  }

  // MARK: - Install paths: several plugins under one root

  private static let fakePayload = Data("pretend this is another plugin".utf8)

  private static func fakeEntry() -> PluginCatalogEntry {
    PluginCatalogEntry(
      id: "fake-plugin", version: "0.1",
      url: URL(
        string:
          "https://github.com/dinhanhthi/Dblore/releases/download/plugin-fake-plugin-v0.1/libfake.dylib"
      )!,
      sha256: hex(fakePayload), maxSize: 1024, kind: .library(fileName: "libfake.dylib"))
  }

  /// Writes `data` at `root/<components...>`, creating the directories.
  private static func seed(_ data: Data, at root: URL, _ components: String...) throws -> URL {
    let url = components.reduce(root) { $0.appendingPathComponent($1) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
  }

  private static func contents(_ directory: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
  }

  @Test func dylibAtTodaysPathReadsAsInstalledWithoutDownload() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // The layout every earlier build installed: Plugins/duckdb/<version>/libduckdb.dylib.
    let existing = try Self.seed(Self.payload, at: root, "duckdb", "1.5.6", "libduckdb.dylib")
    PluginStubURLProtocol.requestCount = 0

    let manager = await Self.manager(Self.catalog(), root: root)

    #expect(manager.state == .installed(version: "1.5.6", size: Int64(Self.payload.count)))
    #expect(manager.installedURL?.path == existing.path)
    #expect(PluginStubURLProtocol.requestCount == 0, "no download")
    // The default root is Application Support/Dblore/Plugins, as before.
    let support = try #require(
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    #expect(PluginManager.defaultRoot.path == support.path + "/Dblore/Plugins")
  }

  @Test func secondEntryInstallsUnderItsOwnDirectoryOnly() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let duckDBFile = try Self.seed(Self.payload, at: root, "duckdb", "1.5.6", "libduckdb.dylib")
    _ = try Self.seed(Data("old".utf8), at: root, "duckdb", "1.4.0", "libduckdb.dylib")
    let registry = PluginRegistry(
      entries: [Self.catalog(), Self.fakeEntry()], root: root,
      session: PluginStubURLProtocol.makeSession())
    let fake = try #require(registry.manager(id: "fake-plugin"))
    let duckDB = try #require(registry.manager(id: "duckdb"))
    await fake.refresh()
    await duckDB.refresh()
    PluginStubURLProtocol.mode = .respond([Self.fakePayload])

    await fake.install()

    #expect(fake.isInstalled, "\(fake.state)")
    let installed = try #require(fake.installedURL)
    #expect(installed.path == root.path + "/fake-plugin/0.1/libfake.dylib")
    #expect(try Data(contentsOf: installed) == Self.fakePayload)
    // The DuckDB directory, including its older version, is left as it was.
    #expect(Self.contents(root.appendingPathComponent("duckdb")) == ["1.5.6", "1.4.0"])
    #expect(try Data(contentsOf: duckDBFile) == Self.payload)
    #expect(duckDB.isInstalled)
  }

  @Test func removingOnePluginLeavesTheOther() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Self.seed(Self.payload, at: root, "duckdb", "1.5.6", "libduckdb.dylib")
    _ = try Self.seed(Self.fakePayload, at: root, "fake-plugin", "0.1", "libfake.dylib")
    let registry = PluginRegistry(
      entries: [Self.catalog(), Self.fakeEntry()], root: root,
      session: PluginStubURLProtocol.makeSession())
    let fake = try #require(registry.manager(id: "fake-plugin"))
    let duckDB = try #require(registry.manager(id: "duckdb"))
    await fake.refresh()
    await duckDB.refresh()
    #expect(fake.isInstalled && duckDB.isInstalled)

    await duckDB.remove()

    #expect(duckDB.state == .notInstalled)
    #expect(Self.contents(root) == ["fake-plugin"])
    await fake.refresh()
    #expect(fake.isInstalled)

    await fake.remove()
    #expect(Self.contents(root).isEmpty)
  }

  // MARK: - Bundle plugins (a zipped loadable bundle)

  private static let bundleIdentifier = "ace.thi.Dblore.test.X"

  /// The zips the fixture builds: `X.bundle` zipped with `--keepParent` as the release script
  /// zips the plugin, or with a second top-level entry, or with a symlink inside the bundle, or
  /// with a 9 MiB main executable of zeros (a few KB zipped) that unpacks past 8 × the size cap.
  enum BundleZip: Sendable {
    case wellFormed, extraTopLevelEntry, symlinkInside, oversizedWhenUnpacked
  }

  /// What a fake verifier was given, from any thread.
  private nonisolated final class VerifierLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(bundle: URL, cdhash: String)] = []

    func record(_ bundle: URL, _ cdhash: String) {
      lock.withLock { calls.append((bundle, cdhash)) }
    }
    var all: [(bundle: URL, cdhash: String)] { lock.withLock { calls } }
  }

  private static func bundleEntry(zip: Data) -> PluginCatalogEntry {
    PluginCatalogEntry(
      id: "test-bundle", version: "1.0.0",
      url: URL(
        string:
          "https://github.com/dinhanhthi/Dblore/releases/download/plugin-test-bundle-v1.0.0/X.zip"
      )!,
      sha256: hex(zip), maxSize: 1 << 20,
      kind: .bundle(
        name: "X.bundle", identifier: bundleIdentifier, cdhash: String(repeating: "a", count: 40)))
  }

  /// A manager past its launch check, with `verify` as its bundle verifier.
  private static func bundleManager(
    _ entry: PluginCatalogEntry, root: URL,
    verify: @escaping PluginManager.BundleVerifier = { _, _ in }
  ) async -> PluginManager {
    let manager = PluginManager(
      entry: entry, root: root, session: PluginStubURLProtocol.makeSession(),
      verifyBundle: verify)
    await manager.refresh()
    return manager
  }

  private static func ditto(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
  }

  /// A minimal `X.bundle` (Info.plist for the test entry, a regular main executable) zipped with
  /// `ditto -c -k --keepParent` in a temporary folder.
  private static func zip(_ kind: BundleZip) throws -> Data {
    let dir = tempRoot()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source", isDirectory: true)
    let bundle = source.appendingPathComponent("X.bundle", isDirectory: true)
    let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
    let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "CFBundleExecutable": "X", "CFBundleIdentifier": bundleIdentifier,
      "CFBundleShortVersionString": "1.0.0", "CFBundlePackageType": "BNDL",
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    try Data("not really code".utf8).write(to: macOS.appendingPathComponent("X"))
    let zip = dir.appendingPathComponent("X.zip")
    switch kind {
    case .wellFormed:
      try ditto(["-c", "-k", "--keepParent", bundle.path, zip.path])
    case .extraTopLevelEntry:
      try Data("extra".utf8).write(to: source.appendingPathComponent("extra.txt"))
      try ditto(["-c", "-k", source.path, zip.path])
    case .symlinkInside:
      try FileManager.default.createSymbolicLink(
        atPath: contents.appendingPathComponent("Resources").path, withDestinationPath: "/")
      try ditto(["-c", "-k", "--keepParent", bundle.path, zip.path])
    case .oversizedWhenUnpacked:
      try Data(count: 9 << 20).write(to: macOS.appendingPathComponent("X"))
      try ditto(["-c", "-k", "--keepParent", bundle.path, zip.path])
    }
    return try Data(contentsOf: zip)
  }

  /// Guards the bundle install path and its launch check: a well-formed zip is unpacked and
  /// verified in staging (with the entry's cdhash), then moved to `<id>/<version>/X.bundle`,
  /// excluded from backups, and a fresh manager's cheap launch check reads it as installed, but
  /// not once its Info.plist names another version. Also guards the restart rule: after the bundle
  /// was loaded, a reinstall asks for a restart, and so does a Remove alone (its code stays loaded
  /// and `Bundle` keeps the image per path), and Remove awaits `beforeRemove` before deleting.
  @Test func wellFormedBundleZipInstallsAndPassesTheLaunchCheck() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = try Self.zip(.wellFormed)
    let entry = Self.bundleEntry(zip: zip)
    let log = VerifierLog()
    let manager = await Self.bundleManager(entry, root: root) { log.record($0, $1) }
    let staging = try #require(manager.stagingDirectory)
    _ = try Self.seed(Data("old".utf8), at: root, "test-bundle", "0.9.0", "X.bundle", "x")
    PluginStubURLProtocol.respond(with: zip)

    await manager.install()

    #expect(manager.isInstalled, "\(manager.state)")
    let url = try #require(manager.installedURL)
    #expect(url.path == root.path + "/test-bundle/1.0.0/X.bundle")
    #expect(FileManager.default.fileExists(atPath: url.path + "/Contents/MacOS/X"))
    #expect(
      try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    let calls = log.all
    #expect(calls.count == 1)
    #expect(calls.first?.bundle.path.hasPrefix(staging.path + "/") == true, "verified before move")
    #expect(calls.first?.bundle.lastPathComponent == "X.bundle")
    #expect(calls.first?.cdhash == String(repeating: "a", count: 40))
    #expect(Self.contents(root.appendingPathComponent("test-bundle")) == ["1.0.0"], "pruned")
    #expect(Self.stagingIsEmpty(manager))

    let fresh = await Self.bundleManager(entry, root: root)
    #expect(fresh.isInstalled, "\(fresh.state)")

    // Loaded, then reinstalled over the existing bundle: the new files wait for a restart.
    manager.markBundleLoaded()
    await manager.install()
    #expect(manager.isInstalled, "\(manager.state)")
    #expect(manager.requiresRestartToUnload)
    #expect(Self.stagingIsEmpty(manager))

    var plist = try #require(
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), format: nil)
        as? [String: Any])
    plist["CFBundleShortVersionString"] = "2.0.0"
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: url.appendingPathComponent("Contents/Info.plist"))
    await fresh.refresh()
    #expect(fresh.state == .notInstalled, "a bundle of another version is not this plugin")

    var filesAtHook: Bool?
    manager.beforeRemove = { filesAtHook = FileManager.default.fileExists(atPath: url.path) }
    await manager.remove()
    #expect(filesAtHook == true, "the hook runs before the files are deleted")
    #expect(manager.state == .notInstalled)
    #expect(!FileManager.default.fileExists(atPath: root.path + "/test-bundle"))

    // Installed, loaded and never reinstalled: Remove alone asks for a restart.
    let loaded = await Self.bundleManager(entry, root: root)
    await loaded.install()
    #expect(loaded.isInstalled, "\(loaded.state)")
    loaded.markBundleLoaded()
    #expect(!loaded.requiresRestartToUnload)
    await loaded.remove()
    #expect(loaded.state == .notInstalled)
    #expect(loaded.requiresRestartToUnload)
  }

  /// Guards the archive layout check: a zip whose SHA-256 matches but holds a second top-level
  /// entry, or a symlink anywhere in the bundle, or unpacks to more than 8 × the entry's size cap,
  /// installs nothing and leaves the previous install in place. The verifier accepts, so the
  /// layout check alone refuses it.
  @Test(arguments: [BundleZip.extraTopLevelEntry, .symlinkInside, .oversizedWhenUnpacked])
  func badlyLaidOutBundleZipInstallsNothing(_ kind: BundleZip) async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let good = try Self.zip(.wellFormed)
    PluginStubURLProtocol.respond(with: good)
    await Self.bundleManager(Self.bundleEntry(zip: good), root: root).install()
    let previous = root.appendingPathComponent("test-bundle/1.0.0/X.bundle/Contents/MacOS/X")
    #expect(FileManager.default.fileExists(atPath: previous.path))
    let bad = try Self.zip(kind)
    let manager = await Self.bundleManager(Self.bundleEntry(zip: bad), root: root)
    PluginStubURLProtocol.respond(with: bad)

    await manager.install()

    #expect(manager.state == .failed(PluginManagerError.invalidArchive.localizedDescription))
    #expect(try Data(contentsOf: previous) == Data("not really code".utf8))
    #expect(
      Self.contents(root.appendingPathComponent("test-bundle/1.0.0/X.bundle")) == ["Contents"])
    #expect(Self.stagingIsEmpty(manager))
    #expect(await Self.bundleManager(Self.bundleEntry(zip: good), root: root).isInstalled)
  }

  /// Guards that the bundle verifier (Team ID and pinned cdhash in production) gates the install:
  /// when it refuses, nothing is installed and staging is cleaned.
  @Test func bundleRefusedByTheVerifierInstallsNothing() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = try Self.zip(.wellFormed)
    let manager = await Self.bundleManager(Self.bundleEntry(zip: zip), root: root) { _, _ in
      throw PluginLoaderError.integrityMismatch
    }
    PluginStubURLProtocol.respond(with: zip)

    await manager.install()

    #expect(manager.state == .failed(PluginManagerError.untrustedBundle.localizedDescription))
    #expect(!Self.installedFileExists(manager))
    #expect(!FileManager.default.fileExists(atPath: root.path + "/test-bundle"))
    #expect(Self.stagingIsEmpty(manager))
  }

  // MARK: - Gated: real .plugin-dev artifacts (declared in load order)

  private static let pluginDev = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".plugin-dev", isDirectory: true)

  /// A plugin root in the container's Application Support, where the real one lives.
  private static func containerRoot() throws -> URL {
    let support = try #require(
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    return support.appendingPathComponent("Dblore/Plugins/duckdb-test/\(UUID().uuidString)")
  }

  /// Installs `artifact` through the download path (stubbed) under a container root.
  private static func installArtifact(_ name: String) async throws -> (PluginManager, URL) {
    let data = try Data(contentsOf: pluginDev.appendingPathComponent(name))
    let root = try containerRoot()
    PluginStubURLProtocol.respond(with: data)
    let manager = await Self.manager(
      Self.catalog(
        sha256: hex(data),
        maxSize: try #require(PluginCatalog.bundled().entry(id: "duckdb")).maxSize),
      root: root)
    await manager.install()
    #expect(manager.isInstalled, "\(manager.state)")
    return (manager, root)
  }

  @Test(.requiresDuckDBPlugin)
  func adhocInstalledCopyIsRefusedByTeamIDBeforeDlopen() async throws {
    let (manager, root) = try await Self.installArtifact("libduckdb-adhoc.dylib")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try #require(manager.installedURL)

    #expect(throws: PluginLoaderError.teamIDMismatch(expected: "86H6CNLN4C", actual: nil)) {
      _ = try manager.loadDuckDBLibrary()
    }
    #expect(dlopen(url.path, RTLD_NOW | RTLD_NOLOAD) == nil, "ad-hoc copy must not be loaded")
  }

  @Test(.requiresDuckDBPlugin)
  func notarizedInstalledCopyLoadsAndRunsQuery() async throws {
    let (manager, root) = try await Self.installArtifact("libduckdb.dylib")
    defer { try? FileManager.default.removeItem(at: root) }

    let library = try manager.loadDuckDBLibrary()
    #expect(try manager.loadDuckDBLibrary() === library, "cached once per manager")

    var database: OpaquePointer?
    var connection: OpaquePointer?
    #expect(library.open(nil, &database) == DuckDBState.success)
    defer { library.close(&database) }
    #expect(library.connect(database, &connection) == DuckDBState.success)
    defer { library.disconnect(&connection) }
    var result = DuckDBResult()
    #expect(library.query(connection, "SELECT 42", &result) == DuckDBState.success)
    defer { library.destroyResult(&result) }
    #expect(library.valueInt64(&result, 0, 0) == 42)

    await manager.remove()
    #expect(manager.requiresRestartToUnload)
  }
}
