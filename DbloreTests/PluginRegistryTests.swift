import Foundation
import Testing

@testable import Dblore

/// Settings > Plugins shows one row per registry manager, so the registry must follow the catalog.
@MainActor
@Suite
struct PluginRegistryTests {
  private static func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("plugin-registry-\(UUID().uuidString)", isDirectory: true)
  }

  private static func entry(id: String, version: String, library: String) -> PluginCatalogEntry {
    PluginCatalogEntry(
      id: id, version: version,
      url: URL(
        string:
          "https://github.com/dinhanhthi/Dblore/releases/download/plugin-\(id)-v\(version)/\(library)"
      )!,
      sha256: String(repeating: "a", count: 64), maxSize: 1024, kind: .library(fileName: library))
  }

  @Test func catalogWithTwoEntriesGivesTwoManagersInCatalogOrder() throws {
    let root = Self.tempRoot()
    let entries = [
      Self.entry(id: "zeta", version: "0.1", library: "libzeta.dylib"),
      Self.entry(id: "duckdb", version: "1.5.6", library: "libduckdb.dylib"),
    ]

    let registry = PluginRegistry(
      catalog: { PluginCatalog(schemaVersion: 3, plugins: entries) }, root: root,
      session: PluginManager.downloadSession())

    #expect(registry.managers.map(\.entry.id) == ["zeta", "duckdb"])
    #expect(try #require(registry.manager(id: "duckdb")).entry == entries[1])
    #expect(
      try #require(registry.manager(id: "zeta")).installedURL?.path
        == root.path + "/zeta/0.1/libzeta.dylib")
    #expect(registry.manager(id: "missing") == nil)
  }

  @Test func catalogThatFailsToLoadGivesNoManagers() {
    let registry = PluginRegistry(
      catalog: { try PluginCatalog.decode(Data(#"{"schemaVersion": 1, "plugins": []}"#.utf8)) },
      root: Self.tempRoot(), session: PluginManager.downloadSession())

    #expect(registry.managers.isEmpty)
    #expect(registry.manager(id: "duckdb") == nil)
  }
}
