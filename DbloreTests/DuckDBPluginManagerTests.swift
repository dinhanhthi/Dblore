import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Dblore

/// URLProtocol stub for plugin downloads. State is static, so the suite is `.serialized`; no
/// other suite registers this class.
private final class PluginStubURLProtocol: URLProtocol, @unchecked Sendable {
  enum Mode {
    /// Status 200 with these chunks, then finish.
    case respond([Data])
    /// Status 200, one chunk, then never finish until the task is cancelled.
    case hang(Data)
  }

  private nonisolated(unsafe) static var storedMode: Mode = .respond([])
  private static let lock = NSLock()

  static var mode: Mode {
    get { lock.withLock { storedMode } }
    set { lock.withLock { storedMode = newValue } }
  }

  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PluginStubURLProtocol.self]
    return URLSession(configuration: config)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    switch Self.mode {
    case .respond(let chunks):
      for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
      client?.urlProtocolDidFinishLoading(self)
    case .hang(let chunk):
      client?.urlProtocol(self, didLoad: chunk)
    }
  }

  override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct DuckDBPluginManagerTests {
  private static let payload = Data("pretend this is libduckdb".utf8)

  private static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func catalog(
    sha256: String = hex(payload), maxSize: Int64 = 1024
  )
    -> DuckDBPluginCatalog
  {
    DuckDBPluginCatalog(
      version: "1.5.6",
      url: URL(
        string:
          "https://github.com/dinhanhthi/Dblore/releases/download/plugin-duckdb-v1.5.6/libduckdb.dylib"
      )!,
      sha256: sha256, maxSize: maxSize)
  }

  private static func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("plugin-manager-\(UUID().uuidString)", isDirectory: true)
  }

  /// A manager past its launch check (`.checking` blocks install).
  private static func manager(
    _ catalog: DuckDBPluginCatalog, root: URL
  ) async -> DuckDBPluginManager {
    let manager = unchecked(catalog, root: root)
    await manager.refresh()
    return manager
  }

  private static func unchecked(_ catalog: DuckDBPluginCatalog?, root: URL) -> DuckDBPluginManager {
    DuckDBPluginManager(catalog: catalog, root: root, session: PluginStubURLProtocol.makeSession())
  }

  private static func stagingIsEmpty(_ manager: DuckDBPluginManager) -> Bool {
    let items = try? FileManager.default.contentsOfDirectory(atPath: manager.stagingDirectory.path)
    return items?.isEmpty ?? true
  }

  private static func installedFileExists(_ manager: DuckDBPluginManager) -> Bool {
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
    let old = manager.pluginDirectory.appendingPathComponent("1.4.0", isDirectory: true)
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

    DuckDBPluginManager.removeOtherVersions(in: plugins, keeping: "1.5.6")

    let left = Set(try manager.contentsOfDirectory(atPath: plugins.path))
    #expect(left == ["1.5.6", "beta", "1.2.x", "1.3.0", "1.3.9"])
    #expect(manager.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))
    // A missing plugin directory is not an error.
    DuckDBPluginManager.removeOtherVersions(
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

    #expect(manager.state == .failed(DuckDBPluginError.tooLarge.localizedDescription))
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

  @Test func refreshWithoutCatalogEndsChecking() async {
    let manager = Self.unchecked(nil, root: Self.tempRoot())
    await manager.refresh()
    #expect(manager.state == .notInstalled)
  }

  @Test nonisolated func isLoadedDoesNotWaitForALoadInProgress() {
    struct Stop: Error {}
    let cache = LibraryCache()
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let loader = Thread {
      _ = try? cache.load {
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
    #expect(throws: DuckDBPluginError.notInstalled) { _ = try manager.loadLibrary() }
  }

  @Test func unsignedInstalledFileIsRefusedBeforeDlopen() async throws {
    // dlopen of this non-dylib would throw loadFailed; teamIDMismatch means it never ran.
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    PluginStubURLProtocol.mode = .respond([Self.payload])
    let manager = await Self.manager(Self.catalog(), root: root)
    await manager.install()

    #expect(throws: DuckDBLibraryError.teamIDMismatch(expected: "86H6CNLN4C", actual: nil)) {
      _ = try manager.loadLibrary()
    }
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
  private static func installArtifact(_ name: String) async throws -> (DuckDBPluginManager, URL) {
    let data = try Data(contentsOf: pluginDev.appendingPathComponent(name))
    let root = try containerRoot()
    let chunk = 1 << 20
    PluginStubURLProtocol.mode = .respond(
      stride(from: 0, to: data.count, by: chunk).map {
        data.subdata(in: $0..<min($0 + chunk, data.count))
      })
    let manager = await Self.manager(
      Self.catalog(sha256: hex(data), maxSize: try DuckDBPluginCatalog.bundled().maxSize),
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

    #expect(throws: DuckDBLibraryError.teamIDMismatch(expected: "86H6CNLN4C", actual: nil)) {
      _ = try manager.loadLibrary()
    }
    #expect(dlopen(url.path, RTLD_NOW | RTLD_NOLOAD) == nil, "ad-hoc copy must not be loaded")
  }

  @Test(.requiresDuckDBPlugin)
  func notarizedInstalledCopyLoadsAndRunsQuery() async throws {
    let (manager, root) = try await Self.installArtifact("libduckdb.dylib")
    defer { try? FileManager.default.removeItem(at: root) }

    let library = try manager.loadLibrary()
    #expect(try manager.loadLibrary() === library, "cached once per manager")

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
