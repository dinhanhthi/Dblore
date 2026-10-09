import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Dblore

@Suite struct PluginIntegrityTests {
  private static let validSHA = String(repeating: "ab", count: 32)

  private static func json(
    version: String = "1.5.6",
    url: String =
      "https://github.com/dinhanhthi/Dblore/releases/download/plugin-duckdb-v1.5.6/libduckdb.dylib",
    sha256: String = validSHA,
    maxSize: Int64 = 1024
  ) -> Data {
    let object: [String: Any] = [
      "version": version, "url": url, "sha256": sha256, "maxSize": maxSize,
    ]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  private static func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("plugin-integrity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  // MARK: - Catalog

  @Test func bundledCatalogDecodesAndValidates() throws {
    let catalog = try DuckDBPluginCatalog.bundled()
    #expect(catalog.version == "1.5.6")
    #expect(catalog.url.host == "github.com")
    #expect(catalog.url.path.hasSuffix("/plugin-duckdb-v1.5.6/libduckdb.dylib"))
    #expect(catalog.sha256.count == 64)
    #expect(catalog.maxSize > 117_008_720)
  }

  @Test func validCatalogDecodesWithLowercasedSHA() throws {
    let catalog = try DuckDBPluginCatalog.decode(Self.json(sha256: Self.validSHA.uppercased()))
    #expect(catalog.sha256 == Self.validSHA)
    #expect(catalog.maxSize == 1024)
  }

  @Test(arguments: [
    (json(url: "http://github.com/a/libduckdb.dylib"), DuckDBPluginCatalogError.invalidURL),
    (json(url: "https://example.com/libduckdb.dylib"), .invalidURL),
    (json(url: "https://github.com.evil.io/libduckdb.dylib"), .invalidURL),
    (json(sha256: "abc"), .invalidSHA256),
    (json(sha256: String(repeating: "g", count: 64)), .invalidSHA256),
    (json(version: "../1.5.6"), .invalidVersion),
    (json(version: ""), .invalidVersion),
    (json(maxSize: 0), .invalidMaxSize),
  ])
  func invalidCatalogIsRejected(data: Data, expected: DuckDBPluginCatalogError) {
    #expect(throws: expected) { _ = try DuckDBPluginCatalog.decode(data) }
  }

  // MARK: - Streaming SHA-256

  @Test func streamingHashMatchesOneShot() async throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("blob.bin")
    // Larger than one read chunk so the streaming path loops.
    let data = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try data.write(to: file)
    let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #expect(try await PluginIntegrity.sha256(of: file, maxSize: Int64(data.count)) == expected)
  }

  @Test func fileOverSizeCapIsRejected() async throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("big.bin")
    try Data(count: 11).write(to: file)
    await #expect(throws: PluginIntegrityError.tooLarge) {
      _ = try await PluginIntegrity.sha256(of: file, maxSize: 10)
    }
  }

  @Test func symlinkIsRejected() async throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("real.bin")
    try Data("x".utf8).write(to: target)
    let link = dir.appendingPathComponent("link.bin")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    await #expect(throws: PluginIntegrityError.notRegularFile) {
      _ = try await PluginIntegrity.sha256(of: link, maxSize: 10)
    }
  }

  @Test func directoryIsRejected() async throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    await #expect(throws: PluginIntegrityError.notRegularFile) {
      _ = try await PluginIntegrity.sha256(of: dir, maxSize: 10)
    }
  }

  // MARK: - DuckDBLibrary.load checks before dlopen

  private static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  @Test func libraryLoadRefusesSymlink() throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = Data("not a dylib".utf8)
    let target = dir.appendingPathComponent("real.dylib")
    try data.write(to: target)
    let link = dir.appendingPathComponent("link.dylib")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect {
      _ = try DuckDBLibrary.load(
        at: link, expectedSHA256: Self.hex(data), expectedVersion: "1.5.6")
    } throws: { error in
      guard case DuckDBLibraryError.loadFailed(let message) = error else { return false }
      return message.contains(link.path)
    }
  }

  @Test func libraryLoadRefusesDirectory() throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect {
      _ = try DuckDBLibrary.load(at: dir, expectedSHA256: Self.validSHA, expectedVersion: "1.5.6")
    } throws: { error in
      guard case DuckDBLibraryError.loadFailed(let message) = error else { return false }
      return message.contains("not a regular file")
    }
  }

  @Test func libraryLoadRefusesFileOverSizeCap() throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = Data(count: 11)
    let file = dir.appendingPathComponent("big.dylib")
    try data.write(to: file)
    #expect(throws: DuckDBLibraryError.integrityMismatch) {
      _ = try DuckDBLibrary.load(
        at: file, expectedSHA256: Self.hex(data), expectedVersion: "1.5.6", maxSize: 10)
    }
  }

  // MARK: - Gated: real notarized artifact

  private static let notarizedDylib = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".plugin-dev/libduckdb.dylib")

  @Test(.requiresDuckDBPlugin)
  func validSignatureFromAnotherTeamIsRefusedBeforeDlopen() throws {
    let url = Self.notarizedDylib
    let sha = Self.hex(try Data(contentsOf: url))
    #expect(
      throws: DuckDBLibraryError.teamIDMismatch(expected: "ABCDE12345", actual: "86H6CNLN4C")
    ) {
      _ = try DuckDBLibrary.load(
        at: url, expectedSHA256: sha, expectedVersion: "1.5.6", expectedTeamID: "ABCDE12345")
    }
  }

  @Test(.requiresDuckDBPlugin)
  func malformedTeamIDIsRefusedBeforeDlopen() throws {
    let url = Self.notarizedDylib
    let sha = Self.hex(try Data(contentsOf: url))
    let injected = "86H6CNLN4C\" or anchor apple"
    #expect(
      throws: DuckDBLibraryError.teamIDMismatch(expected: injected, actual: "86H6CNLN4C")
    ) {
      _ = try DuckDBLibrary.load(
        at: url, expectedSHA256: sha, expectedVersion: "1.5.6", expectedTeamID: injected)
    }
  }
}
