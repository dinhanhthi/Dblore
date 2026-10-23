// SidebarFolderStoreTests.swift
// Sidebar folders are saved per connection, and saved or imported data is untrusted.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Sidebar folder store")
struct SidebarFolderStoreTests {
  private static func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
    let name = "ace.thi.Dblore.tests.sidebarFolders.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults, name)
  }

  @Test("Folders persist per connection key and do not leak to another connection")
  func perConnection() throws {
    try Self.withDefaults { defaults, _ in
      let app = ConnectionConfig(host: "db.example", port: 5432, database: "app")
      let other = ConnectionConfig(host: "db.example", port: 5432, database: "billing")
      let appKey = SidebarFolderStore.key(for: app)
      #expect(appKey == "PostgreSQL|db.example|5432|app")
      let store = SidebarFolderStore(defaults: defaults)

      let folder = try #require(
        store.createFolder(named: "  Auth  ", schema: "public", for: appKey))
      store.move("public.users", toFolder: folder.id, for: appKey)
      let second = try #require(store.createFolder(named: "Audit", schema: "public", for: appKey))
      // A move takes the member out of its previous folder
      store.move("public.users", toFolder: second.id, for: appKey)
      store.move("public.users", toFolder: folder.id, for: appKey)

      let reopened = SidebarFolderStore(defaults: defaults)
      let saved = reopened.folders(for: appKey)
      #expect(saved.map(\.name) == ["Auth", "Audit"])
      #expect(saved.map(\.members) == [["public.users"], []])
      #expect(reopened.folders(for: SidebarFolderStore.key(for: other)).isEmpty)

      reopened.deleteFolder(id: folder.id, for: appKey)
      #expect(SidebarFolderStore(defaults: defaults).folders(for: appKey).map(\.name) == ["Audit"])
    }
  }

  @Test("Decoding malformed data drops only the bad entries")
  func malformedData() throws {
    let good = UUID()
    let long = UUID()
    let json: [String: Any] = [
      "PostgreSQL|h|5432|app": [
        [
          "id": good.uuidString, "name": "Auth", "schema": "public",
          "members": ["public.users", 7, "public.users", "", "public.roles"],
        ],
        ["id": UUID().uuidString, "name": 42, "schema": "public", "members": []],
        ["id": "not-a-uuid", "name": "Bad id", "schema": "public"],
        ["id": UUID().uuidString, "name": "   ", "schema": "public"],
        "not a folder",
        ["id": long.uuidString, "name": String(repeating: "n", count: 80), "schema": "public"],
        // A repeated id keeps the first folder
        ["id": good.uuidString, "name": "Copy", "schema": "public"],
      ],
      "PostgreSQL|h|5432|other": "not an array",
    ]
    let data = try JSONSerialization.data(withJSONObject: json)

    let decoded = SidebarFolderStore.decode(data)
    #expect(decoded.keys.sorted() == ["PostgreSQL|h|5432|app"])
    let folders = try #require(decoded["PostgreSQL|h|5432|app"])
    #expect(folders.map(\.id) == [good, long])
    #expect(folders[0].members == ["public.users", "public.roles"])
    #expect(folders[1].name == String(repeating: "n", count: SidebarFolderStore.nameLimit))
    #expect(SidebarFolderStore.decode(Data("[1, 2]".utf8)).isEmpty)
    #expect(SidebarFolderStore.decode(Data("not json".utf8)).isEmpty)

    // An imported file is written sanitized
    try Self.withDefaults { defaults, name in
      SidebarFolderStore.replace(data, defaults: defaults, domainName: name)
      let stored = SidebarFolderStore.storedData(defaults: defaults, domainName: name)
      #expect(SidebarFolderStore.decode(stored) == decoded)
      let storedData = try #require(stored)
      let raw = try JSONSerialization.jsonObject(with: storedData) as? [String: [Any]]
      #expect(raw?["PostgreSQL|h|5432|app"]?.count == 2)
    }
  }
}
