import Foundation
import Testing

@testable import Dblore

@Suite struct PluginCatalogTests {
  private static let validSHA = String(repeating: "ab", count: 32)
  private static let validURL =
    "https://github.com/dinhanhthi/Dblore/releases/download/plugin-duckdb-v1.5.6/libduckdb.dylib"

  private static func entry(
    id: String = "duckdb",
    version: String = "1.5.6",
    url: String = validURL,
    sha256: String = validSHA,
    maxSize: Int64 = 1024,
    libraryFileName: String = "libduckdb.dylib"
  ) -> [String: Any] {
    [
      "id": id, "version": version, "url": url, "sha256": sha256, "maxSize": maxSize,
      "libraryFileName": libraryFileName,
    ]
  }

  private static func json(schemaVersion: Int = 2, plugins: [[String: Any]] = [entry()]) -> Data {
    try! JSONSerialization.data(
      withJSONObject: ["schemaVersion": schemaVersion, "plugins": plugins])
  }

  private static func json(_ entry: [String: Any]) -> Data { json(plugins: [entry]) }

  // MARK: - Bundled and valid

  @Test func bundledCatalogPinsTheDuckDBPlugin() throws {
    let catalog = try PluginCatalog.bundled()
    #expect(catalog.schemaVersion == 2)
    #expect(catalog.plugins.map(\.id) == ["duckdb"])
    let duckdb = try #require(catalog.entry(id: "duckdb"))
    #expect(duckdb.version == "1.5.6")
    #expect(duckdb.url.absoluteString == Self.validURL)
    #expect(duckdb.sha256 == "98065fe243933fe5f17831a7b960f243ef7a370b0318066e8710d661bf71b878")
    #expect(duckdb.maxSize == 134_217_728)
    #expect(duckdb.libraryFileName == "libduckdb.dylib")
  }

  @Test func validCatalogDecodesEveryEntry() throws {
    let other = Self.entry(
      id: "my-plugin-2", version: "0.1",
      url:
        "https://github.com/dinhanhthi/Dblore/releases/download/plugin-my-plugin-2-v0.1/libother.dylib",
      maxSize: 268_435_456, libraryFileName: "libother.dylib")
    let catalog = try PluginCatalog.decode(Self.json(plugins: [Self.entry(), other]))
    #expect(catalog.plugins.map(\.id) == ["duckdb", "my-plugin-2"])
    #expect(catalog.entry(id: "my-plugin-2")?.maxSize == 268_435_456)
    #expect(catalog.entry(id: "missing") == nil)
  }

  // MARK: - Strict validation (the whole catalog fails closed)

  private static func url(_ suffix: String) -> [String: Any] {
    entry(url: "https://github.com/dinhanhthi/Dblore/releases/download/" + suffix)
  }

  @Test(arguments: [
    // Schema version and shape.
    (json(schemaVersion: 1), PluginCatalogError.unsupportedSchemaVersion),
    (json(schemaVersion: 3), .unsupportedSchemaVersion),
    (
      try! JSONSerialization.data(withJSONObject: [
        "version": "1.5.6", "url": validURL, "sha256": validSHA, "maxSize": 1024,
      ]),
      .unsupportedSchemaVersion
    ),
    (json(["id": "duckdb", "version": "1.5.6"]), .malformed),
    // Ids.
    (json(plugins: [entry(), entry()]), .duplicateID("duckdb")),
    (json(entry(id: "DuckDB")), .invalidID("DuckDB")),
    (json(entry(id: "duck_db")), .invalidID("duck_db")),
    (json(entry(id: "")), .invalidID("")),
    // URL: scheme, host, userinfo, port, query, fragment, encoding, path shape, tag, asset.
    (
      json(
        entry(
          url:
            "http://github.com/dinhanhthi/Dblore/releases/download/plugin-duckdb-v1.5.6/libduckdb.dylib"
        )), .invalidURL("duckdb")
    ),
    (
      json(
        entry(
          url:
            "https://github.com.evil.io/dinhanhthi/Dblore/releases/download/plugin-duckdb-v1.5.6/libduckdb.dylib"
        )), .invalidURL("duckdb")
    ),
    (
      json(
        entry(
          url:
            "https://evil.io@github.com/dinhanhthi/Dblore/releases/download/plugin-duckdb-v1.5.6/libduckdb.dylib"
        )), .invalidURL("duckdb")
    ),
    (
      json(
        entry(
          url:
            "https://github.com@evil.io/dinhanhthi/Dblore/releases/download/plugin-duckdb-v1.5.6/libduckdb.dylib"
        )), .invalidURL("duckdb")
    ),
    (
      json(
        entry(
          url:
            "https://github.com:8443/dinhanhthi/Dblore/releases/download/plugin-duckdb-v1.5.6/libduckdb.dylib"
        )), .invalidURL("duckdb")
    ),
    (
      json(entry(url: validURL + "?x=/plugin-duckdb-v1.5.6/libduckdb.dylib")), .invalidURL("duckdb")
    ),
    (json(entry(url: validURL + "#libduckdb.dylib")), .invalidURL("duckdb")),
    (json(url("plugin-duckdb-v1.5.6/%2e%2e/libduckdb.dylib")), .invalidURL("duckdb")),
    (json(url("plugin-duckdb-v1.5.6/..%2Flibduckdb.dylib")), .invalidURL("duckdb")),
    (
      json(url("plugin-duckdb-v1.5.6/../plugin-duckdb-v1.5.6/libduckdb.dylib")),
      .invalidURL("duckdb")
    ),
    (
      json(
        entry(
          url: "https://github.com/dinhanhthi/Dblore/archive/plugin-duckdb-v1.5.6/libduckdb.dylib")),
      .invalidURL("duckdb")
    ),
    (json(url("plugin-other-v1.5.6/libduckdb.dylib")), .invalidURL("duckdb")),
    (json(url("plugin-duckdb-v1.5.7/libduckdb.dylib")), .invalidURL("duckdb")),
    (json(url("plugin-duckdb-v1.5.6/libother.dylib")), .invalidURL("duckdb")),
    // SHA-256: 64 lowercase hex.
    (json(entry(sha256: "abc")), .invalidSHA256("duckdb")),
    (json(entry(sha256: validSHA.uppercased())), .invalidSHA256("duckdb")),
    (json(entry(sha256: String(repeating: "g", count: 64))), .invalidSHA256("duckdb")),
    // Version (it names a directory).
    (json(entry(version: "../1.5.6")), .invalidVersion("duckdb")),
    (json(entry(version: "")), .invalidVersion("duckdb")),
    // Size cap: positive and at most 256 MiB.
    (json(entry(maxSize: 0)), .invalidMaxSize("duckdb")),
    (json(entry(maxSize: 268_435_457)), .invalidMaxSize("duckdb")),
    // Library file name: a visible .dylib basename.
    (json(entry(libraryFileName: "lib/duckdb.dylib")), .invalidLibraryFileName("duckdb")),
    (json(entry(libraryFileName: "..dylib")), .invalidLibraryFileName("duckdb")),
    (json(entry(libraryFileName: ".libduckdb.dylib")), .invalidLibraryFileName("duckdb")),
    (json(entry(libraryFileName: "libduckdb\u{0}.dylib")), .invalidLibraryFileName("duckdb")),
    (json(entry(libraryFileName: "libduckdb.so")), .invalidLibraryFileName("duckdb")),
    (json(entry(libraryFileName: ".dylib")), .invalidLibraryFileName("duckdb")),
  ])
  func invalidCatalogIsRejected(data: Data, expected: PluginCatalogError) {
    #expect(throws: expected) { _ = try PluginCatalog.decode(data) }
  }

  @Test func oneBadEntryRejectsTheWholeCatalog() {
    let bad = Self.entry(id: "other", sha256: "abc")
    #expect(throws: PluginCatalogError.invalidSHA256("other")) {
      _ = try PluginCatalog.decode(Self.json(plugins: [Self.entry(), bad]))
    }
  }
}
