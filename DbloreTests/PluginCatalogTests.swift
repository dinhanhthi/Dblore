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
    kind: String? = "library",
    libraryFileName: String = "libduckdb.dylib"
  ) -> [String: Any] {
    var entry: [String: Any] = [
      "id": id, "version": version, "url": url, "sha256": sha256, "maxSize": maxSize,
      "libraryFileName": libraryFileName,
    ]
    entry["kind"] = kind
    return entry
  }

  private static let validCDHash = String(repeating: "c0", count: 20)
  private static let validBundleURL =
    "https://github.com/dinhanhthi/Dblore/releases/download/plugin-local-ai-v1.0.0/DbloreLocalAI.zip"

  private static func bundleEntry(
    url: String = validBundleURL,
    bundleName: String = "DbloreLocalAI.bundle",
    bundleIdentifier: String = "ace.thi.Dblore.LocalAI",
    cdhash: String? = validCDHash
  ) -> [String: Any] {
    var entry: [String: Any] = [
      "id": "local-ai", "version": "1.0.0", "url": url, "sha256": validSHA, "maxSize": 2048,
      "kind": "bundle", "bundleName": bundleName, "bundleIdentifier": bundleIdentifier,
    ]
    entry["cdhash"] = cdhash
    return entry
  }

  private static func json(schemaVersion: Int = 3, plugins: [[String: Any]] = [entry()]) -> Data {
    try! JSONSerialization.data(
      withJSONObject: ["schemaVersion": schemaVersion, "plugins": plugins])
  }

  private static func json(_ entry: [String: Any]) -> Data { json(plugins: [entry]) }

  // MARK: - Bundled and valid

  @Test func bundledCatalogPinsEveryPlugin() throws {
    let catalog = try PluginCatalog.bundled()
    #expect(catalog.schemaVersion == 3)
    #expect(catalog.plugins.map(\.id) == ["duckdb", "local-ai"])
    let duckdb = try #require(catalog.entry(id: "duckdb"))
    #expect(duckdb.version == "1.5.6")
    #expect(duckdb.url.absoluteString == Self.validURL)
    #expect(duckdb.sha256 == "98065fe243933fe5f17831a7b960f243ef7a370b0318066e8710d661bf71b878")
    #expect(duckdb.maxSize == 134_217_728)
    #expect(duckdb.kind == .library(fileName: "libduckdb.dylib"))
    let localAI = try #require(catalog.entry(id: "local-ai"))
    #expect(localAI.version == "1.0.0")
    #expect(localAI.url.absoluteString == Self.validBundleURL)
    #expect(localAI.sha256 == "d87bcf640a6aa36800a010ac91bfbac7222408bddad26901aeb2415a804be574")
    #expect(localAI.maxSize == 12_183_804)
    #expect(
      localAI.kind
        == .bundle(
          name: "DbloreLocalAI.bundle", identifier: "ace.thi.Dblore.LocalAI",
          cdhash: "3ec922c4930ec54ad59d6b92913df9912437acb5"))
  }

  @Test func validCatalogDecodesEveryEntry() throws {
    let other = Self.entry(
      id: "my-plugin-2", version: "0.1",
      url:
        "https://github.com/dinhanhthi/Dblore/releases/download/plugin-my-plugin-2-v0.1/libother.dylib",
      maxSize: 268_435_456, libraryFileName: "libother.dylib")
    let catalog = try PluginCatalog.decode(
      Self.json(plugins: [Self.entry(), other, Self.bundleEntry()]))
    #expect(catalog.plugins.map(\.id) == ["duckdb", "my-plugin-2", "local-ai"])
    #expect(catalog.entry(id: "my-plugin-2")?.maxSize == 268_435_456)
    #expect(catalog.entry(id: "missing") == nil)
    // A bundle keeps every pin: the zip's URL and SHA-256 and the bundle's name, id and cdhash.
    let bundle = try #require(catalog.entry(id: "local-ai"))
    #expect(bundle.version == "1.0.0")
    #expect(bundle.url.absoluteString == Self.validBundleURL)
    #expect(bundle.sha256 == Self.validSHA)
    #expect(bundle.maxSize == 2048)
    #expect(
      bundle.kind
        == .bundle(
          name: "DbloreLocalAI.bundle", identifier: "ace.thi.Dblore.LocalAI",
          cdhash: Self.validCDHash))
  }

  // MARK: - Strict validation (the whole catalog fails closed)

  private static func url(_ suffix: String) -> [String: Any] {
    entry(url: "https://github.com/dinhanhthi/Dblore/releases/download/" + suffix)
  }

  private static func bundleURL(_ suffix: String) -> [String: Any] {
    bundleEntry(url: "https://github.com/dinhanhthi/Dblore/releases/download/" + suffix)
  }

  @Test(arguments: [
    // Schema version and shape: a schema 2 file (entries without a kind) is refused.
    (
      json(schemaVersion: 2, plugins: [entry(kind: nil)]),
      PluginCatalogError.unsupportedSchemaVersion
    ),
    (json(schemaVersion: 4), .unsupportedSchemaVersion),
    (
      try! JSONSerialization.data(withJSONObject: [
        "version": "1.5.6", "url": validURL, "sha256": validSHA, "maxSize": 1024,
      ]),
      .unsupportedSchemaVersion
    ),
    (json(["id": "duckdb", "version": "1.5.6"]), .malformed),
    // Kind: required, and only the kinds this build installs.
    (json(entry(kind: nil)), .malformed),
    (json(entry(kind: "helper")), .unsupportedKind("duckdb")),
    // Ids.
    (json(plugins: [entry(), entry()]), .duplicateID("duckdb")),
    (json(entry(id: "DuckDB")), .invalidID("DuckDB")),
    (json(entry(id: "duck_db")), .invalidID("duck_db")),
    (json(entry(id: "")), .invalidID("")),
    (json(entry(id: "-duckdb")), .invalidID("-duckdb")),
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
    // Bundle: a visible <Name>.bundle, a reverse-DNS id, a 40-hex cdhash pin, asset <Name>.zip.
    (json(bundleEntry(cdhash: nil)), .malformed),
    (json(bundleEntry(bundleName: "DbloreLocalAI.app")), .invalidBundleName("local-ai")),
    (json(bundleEntry(bundleName: "../DbloreLocalAI.bundle")), .invalidBundleName("local-ai")),
    (json(bundleEntry(bundleIdentifier: "LocalAI")), .invalidBundleIdentifier("local-ai")),
    (
      json(bundleEntry(bundleIdentifier: "ace.thi.Dblore/LocalAI")),
      .invalidBundleIdentifier("local-ai")
    ),
    (json(bundleEntry(cdhash: String(validCDHash.dropLast()))), .invalidCDHash("local-ai")),
    (json(bundleEntry(cdhash: validCDHash.uppercased())), .invalidCDHash("local-ai")),
    (json(bundleURL("plugin-local-ai-v1.0.0/DbloreLocalAI.bundle")), .invalidURL("local-ai")),
    (json(bundleURL("plugin-local-ai-v1.0.0/Other.zip")), .invalidURL("local-ai")),
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
