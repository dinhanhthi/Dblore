import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Dblore

/// Unit checks that need no plugin artifact.
@Suite struct DuckDBLibraryUnitTests {
  private static let anySHA256 = String(repeating: "0", count: 64)

  /// A non-dylib file in the temporary directory; dlopen of it always fails.
  private static func junkFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("duckdb-junk-\(UUID().uuidString).dylib")
    try Data("not a dylib".utf8).write(to: url)
    return url
  }

  @Test func loadingMissingFileThrowsLoadFailedWithPath() {
    let url = URL(fileURLWithPath: "/nonexistent/dblore/libduckdb.dylib")
    #expect {
      _ = try DuckDBLibrary.load(at: url, expectedSHA256: Self.anySHA256, expectedVersion: "1.5.6")
    } throws: { error in
      guard case DuckDBLibraryError.loadFailed(let message) = error else { return false }
      return message.contains("/nonexistent/dblore/libduckdb.dylib")
    }
  }

  @Test func relativePathIsRejected() throws {
    let url = try #require(URL(string: "file:libduckdb.dylib"))
    #expect(throws: DuckDBLibraryError.invalidPath("libduckdb.dylib")) {
      _ = try DuckDBLibrary.load(at: url, expectedSHA256: Self.anySHA256, expectedVersion: "1.5.6")
    }
  }

  @Test func wrongHashIsRejectedBeforeDlopen() throws {
    // dlopen of this file would fail with loadFailed; integrityMismatch means it never ran.
    let url = try Self.junkFile()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: DuckDBLibraryError.integrityMismatch) {
      _ = try DuckDBLibrary.load(at: url, expectedSHA256: Self.anySHA256, expectedVersion: "1.5.6")
    }
  }

  @Test func matchingHashReachesDlopen() throws {
    let url = try Self.junkFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let digest = SHA256.hash(data: try Data(contentsOf: url))
    let hex = digest.map { String(format: "%02X", $0) }.joined()  // case-insensitive
    #expect {
      _ = try DuckDBLibrary.load(at: url, expectedSHA256: hex, expectedVersion: "1.5.6")
    } throws: { error in
      guard case DuckDBLibraryError.loadFailed = error else { return false }
      return true
    }
  }

  @Test func resultLayoutMatchesDuckDBHeader() {
    // struct duckdb_result: 3 x idx_t, duckdb_column *, char *, void *.
    #expect(MemoryLayout<DuckDBResult>.size == 48)
    #expect(MemoryLayout<DuckDBResult>.stride == 48)
    #expect(MemoryLayout<DuckDBResult>.alignment == 8)
  }
}

/// Spike for task 2.5: dlopen of the re-signed libduckdb from the sandboxed,
/// hardened-runtime test host. Cases (d) and (f) only record what happens.
/// Files the sandboxed app writes are auto-quarantined and the sandbox cannot
/// strip the xattr, so container loads need a notarized artifact.
@Suite(.requiresDuckDBPlugin, .serialized)
struct DuckDBLibraryTests {
  private struct Catalog: Decodable {
    let version: String
    let sha256: String
    let path: String
    let adhocPath: String
    let notarized: Bool
  }

  private static let pluginDev = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".plugin-dev", isDirectory: true)

  private static func catalog() throws -> Catalog {
    let data = try Data(contentsOf: pluginDev.appendingPathComponent("dev-catalog.json"))
    return try JSONDecoder().decode(Catalog.self, from: data)
  }

  private static var signedSource: URL { pluginDev.appendingPathComponent("libduckdb.dylib") }
  private static var adhocSource: URL { pluginDev.appendingPathComponent("libduckdb-adhoc.dylib") }

  /// Writes the bytes (not copyItem, which keeps xattrs) into the container's
  /// Application Support, the way a download would land there.
  private static func stage(_ source: URL, as name: String) throws -> URL {
    let support = try #require(
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    let dir =
      support
      .appendingPathComponent("Dblore/Plugins/duckdb-test", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let target = dir.appendingPathComponent(name)
    try Data(contentsOf: source).write(to: target)
    return target
  }

  private static func removeStaged(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  private static func log(_ message: String) {
    print("DUCKDB-SPIKE: \(message)")
    Attachment.record(message, named: "duckdb-spike.txt")
  }

  /// Path of the image dyld actually used for the library's symbols.
  private static func imagePath(of library: DuckDBLibrary) -> String {
    var info = Dl_info()
    let address = unsafeBitCast(library.libraryVersion, to: UnsafeRawPointer.self)
    guard dladdr(address, &info) != 0, let name = info.dli_fname else { return "?" }
    return String(cString: name)
  }

  private static func isAlreadyLoaded(_ url: URL) -> Bool {
    dlopen(url.path, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD) != nil
  }

  private static func quarantine(of url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    let length = getxattr(url.path, "com.apple.quarantine", &buffer, buffer.count - 1, 0, 0)
    guard length >= 0 else { return nil }
    return String(cString: buffer)
  }

  /// Whether the dev artifact is notarized; read synchronously for traits.
  private static let isNotarized = (try? catalog().notarized) ?? false

  /// dlopen of a quarantined, non-notarized dylib makes Gatekeeper show a
  /// "Not Opened" dialog, so tests never load such a file.
  private static func loadUnquarantined(
    _ url: URL, sha256: String? = nil
  ) throws -> DuckDBLibrary {
    if !isNotarized, let value = quarantine(of: url) {
      throw DuckDBLibraryError.loadFailed(
        "refused: \(url.lastPathComponent) quarantined (\(value))")
    }
    return try load(url, sha256: try sha256 ?? catalog().sha256)
  }

  private static func load(_ url: URL, sha256: String) throws -> DuckDBLibrary {
    try DuckDBLibrary.load(at: url, expectedSHA256: sha256, expectedVersion: try catalog().version)
  }

  private static func sha256(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - (e) ad-hoc copy is rejected (declared first so it is the first load)

  @Test func adhocSignedCopyIsRejectedByLibraryValidation() throws {
    // Repo path, not a container copy: container copies are auto-quarantined.
    let url = URL(fileURLWithPath: try Self.catalog().adhocPath)
    if Self.isAlreadyLoaded(url) {
      Self.log("(e) CONFOUNDED: an image with this identity is already loaded")
    }
    do {
      // Hash the ad-hoc file itself so the rejection comes from library validation.
      let library = try Self.loadUnquarantined(url, sha256: try Self.sha256(of: url))
      Issue.record("(e) ad-hoc copy loaded from \(Self.imagePath(of: library))")
    } catch DuckDBLibraryError.loadFailed(let message) {
      Self.log("(e) ad-hoc dlerror: \(message)")
      #expect(!message.hasPrefix("refused:"), "\(message)")
      #expect(!message.contains("system policy"), "\(message)")
      let markers = ["different Team IDs", "library validation", "not valid for use in process"]
      #expect(markers.contains { message.contains($0) }, "\(message)")
    }
  }

  // MARK: - (a) version

  @Test func libraryVersionMatchesCatalog() throws {
    let library = try Self.loadUnquarantined(Self.signedSource)
    let version = library.version
    Self.log("(a) duckdb_library_version = \(version)")
    let normalized = version.hasPrefix("v") ? String(version.dropFirst()) : version
    #expect(normalized == (try Self.catalog().version))
  }

  @Test func unexpectedVersionIsRejectedAfterLoad() throws {
    let url = Self.signedSource
    if !Self.isNotarized, let value = Self.quarantine(of: url) {
      Issue.record("refused: \(url.lastPathComponent) quarantined (\(value))")
      return
    }
    let catalog = try Self.catalog()
    #expect(
      throws: DuckDBLibraryError.versionMismatch(expected: "0.0.0", actual: catalog.version)
    ) {
      _ = try DuckDBLibrary.load(
        at: url, expectedSHA256: catalog.sha256, expectedVersion: "0.0.0")
    }
  }

  // MARK: - (b) in-memory query and extensions

  @Test func inMemorySelectAndBuiltinExtensions() throws {
    let library = try Self.loadUnquarantined(Self.signedSource)
    let db = try DuckDBTestDatabase(library: library, path: ":memory:")
    defer { db.close() }

    #expect(try db.int64("SELECT 42") == 42)
    #expect(try db.rows("SELECT 'duck' || 'db'") == [["duckdb"]])

    let extensions = try db.rows(
      "SELECT extension_name, loaded, installed, install_mode FROM duckdb_extensions() "
        + "ORDER BY extension_name")
    for row in extensions {
      Self.log("(b) extension \(row.map { $0 ?? "NULL" }.joined(separator: " | "))")
    }
    for name in ["parquet", "json"] {
      let row = try #require(
        extensions.first { $0.first == name }, "\(name) missing from duckdb_extensions()")
      #expect(row[1] == "true" || row[2] == "true", "\(name): \(row)")
    }
  }

  // MARK: - (c) sandbox container path (hard gate)

  @Test(
    .disabled(
      if: !isNotarized,
      "container copies are auto-quarantined by the sandbox; needs a notarized artifact (scripts/release-plugin.sh --install-dev with DbloreNotary)"
    ))
  func signedCopyLoadsFromContainerApplicationSupport() throws {
    let staged = try Self.stage(Self.signedSource, as: "libduckdb.dylib")
    defer { Self.removeStaged(staged) }
    Self.log("(c) staged at \(staged.path)")
    Self.log("(c) auto quarantine on app-written file: \(Self.quarantine(of: staged) ?? "none")")
    let status = removexattr(staged.path, "com.apple.quarantine", 0)
    Self.log("(c) removexattr status \(status) errno \(status == 0 ? 0 : errno)")
    Self.log("(c) quarantine after removexattr: \(Self.quarantine(of: staged) ?? "none")")
    let library = try Self.loadUnquarantined(staged)
    Self.log("(c) loaded image \(Self.imagePath(of: library))")
    let db = try DuckDBTestDatabase(library: library, path: nil)
    defer { db.close() }
    #expect(try db.int64("SELECT 40 + 2") == 42)
  }

  // MARK: - (d) quarantined copy (only with a notarized artifact)

  @Test(
    .disabled(
      if: !isNotarized, "triggers Gatekeeper dialog; runs once dev-catalog.json is notarized"))
  func quarantinedCopyOutcomeIsRecorded() throws {
    // Files the sandboxed app writes are auto-quarantined (see case c).
    let staged = try Self.stage(Self.signedSource, as: "libduckdb-quarantined.dylib")
    defer { Self.removeStaged(staged) }
    Self.log("(d) quarantine: \(Self.quarantine(of: staged) ?? "none")")
    do {
      let library = try Self.load(staged, sha256: try Self.catalog().sha256)
      Self.log("(d) quarantined load OK, image \(Self.imagePath(of: library))")
    } catch {
      Self.log("(d) quarantined load failed: \(error)")
    }
  }

  // MARK: - (f) read-only open with a leftover .wal (informational)

  @Test func readOnlyOpenWithLeftoverWALOutcomeIsRecorded() throws {
    let library = try Self.loadUnquarantined(Self.signedSource)

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("duckdb-wal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("spike.duckdb")
    let wal = dir.appendingPathComponent("spike.duckdb.wal")

    let writer = try DuckDBTestDatabase(library: library, path: file.path)
    do {
      _ = try writer.rows("CREATE TABLE t (i INTEGER, s VARCHAR)")
      _ = try writer.rows("INSERT INTO t VALUES (7, 'wal')")
      _ = try writer.rows("PRAGMA disable_checkpoint_on_shutdown")
    } catch {
      Self.log("(f) setup failed: \(error)")
    }
    writer.close()
    let walExists = FileManager.default.fileExists(atPath: wal.path)
    Self.log("(f) .wal present after close: \(walExists)")

    do {
      let reader = try DuckDBTestDatabase(
        library: library, path: file.path, config: ["access_mode": "READ_ONLY"])
      defer { reader.close() }
      let rows = try reader.rows("SELECT i, s FROM t")
      Self.log("(f) read-only rows: \(rows)")
      do {
        _ = try reader.rows("INSERT INTO t VALUES (8, 'x')")
        Self.log("(f) read-only INSERT unexpectedly succeeded")
      } catch {
        Self.log("(f) read-only INSERT rejected: \(error)")
      }
    } catch {
      Self.log("(f) read-only open/read failed: \(error)")
    }
    Self.log(
      "(f) .wal present after read-only session: \(FileManager.default.fileExists(atPath: wal.path))"
    )
  }
}

/// Minimal test-side driver over the raw C API table.
private final class DuckDBTestDatabase {
  struct Failure: Error, CustomStringConvertible { let description: String }

  private let library: DuckDBLibrary
  private var database: OpaquePointer?
  private var connection: OpaquePointer?

  init(library: DuckDBLibrary, path: String?, config options: [String: String] = [:]) throws {
    self.library = library
    var config: OpaquePointer?
    guard library.createConfig(&config) == DuckDBState.success else {
      throw Failure(description: "duckdb_create_config failed")
    }
    defer { library.destroyConfig(&config) }
    for (name, value) in options {
      guard library.setConfig(config, name, value) == DuckDBState.success else {
        throw Failure(description: "duckdb_set_config \(name) failed")
      }
    }
    var error: UnsafeMutablePointer<CChar>?
    if library.openExt(path, &database, config, &error) != DuckDBState.success {
      let message = error.map { String(cString: $0) } ?? "unknown"
      library.free(error)
      throw Failure(description: "duckdb_open_ext: \(message)")
    }
    guard library.connect(database, &connection) == DuckDBState.success else {
      library.close(&database)
      throw Failure(description: "duckdb_connect failed")
    }
  }

  func close() {
    library.disconnect(&connection)
    library.close(&database)
  }

  private func withResult<T>(_ sql: String, _ body: (inout DuckDBResult) -> T) throws -> T {
    var result = DuckDBResult()
    defer { library.destroyResult(&result) }
    if library.query(connection, sql, &result) != DuckDBState.success {
      let message = library.resultError(&result).map { String(cString: $0) } ?? "unknown"
      throw Failure(description: message)
    }
    return body(&result)
  }

  func int64(_ sql: String) throws -> Int64 {
    try withResult(sql) { library.valueInt64(&$0, 0, 0) }
  }

  func rows(_ sql: String) throws -> [[String?]] {
    try withResult(sql) { result in
      let rowCount = library.rowCount(&result)
      let columnCount = library.columnCount(&result)
      return (0..<rowCount).map { row in
        (0..<columnCount).map { column in
          guard let text = library.valueVarchar(&result, column, row) else { return nil }
          defer { library.free(text) }
          return String(cString: text)
        }
      }
    }
  }
}
