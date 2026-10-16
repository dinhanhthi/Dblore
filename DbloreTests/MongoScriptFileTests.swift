// MongoScriptFileTests.swift
// Script files follow the workspace connection: a MongoDB workspace makes and opens ".js"
// queries ("New Query"), other connections make and open ".sql" files ("New SQL File"). A
// user-initiated open of the other kind is refused and adds no tab; a restore open (the
// default) never refuses, so saved tabs keep opening. A workspace with no connection accepts
// both. Temp files only; recents use an injected suite, never the user's defaults.

import Foundation
import Testing

@testable import Dblore

@Suite("Mongo script files")
@MainActor
struct MongoScriptFileTests {
  private static let mongo = ConnectionConfig(
    databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
    sslMode: .disable)
  private static let postgres = ConnectionConfig(
    databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
    sslMode: .disable)

  /// Temp folder with a "query.js" and a "query.sql"
  private static func makeFiles() throws -> (folder: URL, js: URL, sql: URL) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("mongo-script-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let js = folder.appendingPathComponent("query.js")
    try Data("db.users.find({})".utf8).write(to: js)
    let sql = folder.appendingPathComponent("query.sql")
    try Data("select 1".utf8).write(to: sql)
    return (folder, js, sql)
  }

  private static func manager(
    _ config: ConnectionConfig?
  ) throws -> (WorkspaceManager, UserDefaults, String) {
    let name = "MongoScriptFileTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    manager.recents = RecentManager(defaults: suite)
    var hooks = SecurityScopedAccessHooks()
    hooks.resolve = { _ in throw CocoaError(.fileNoSuchFile) }
    hooks.makeBookmark = { _ in nil }
    manager.accessHooks = hooks
    return (manager, suite, name)
  }

  @Test("A MongoDB workspace makes Untitled.js, refuses a user .sql open and restores a .sql")
  func mongoWorkspace() async throws {
    let (folder, js, sql) = try Self.makeFiles()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager(Self.mongo)
    defer { suite.removePersistentDomain(forName: name) }

    #expect(manager.isMongoWorkspace)
    #expect(manager.newScriptLabel == "New Query")
    manager.newSQLFile()
    #expect(manager.tabs.map(\.title) == ["Untitled.js"])
    #expect(manager.tabs.first?.documentType == .sqlFile)

    // Refuse before the restore open: an already open URL returns early without any check
    await #expect(throws: (any Error).self) {
      try await manager.openFile(url: sql, checksScriptKind: true)
    }
    #expect(manager.tabs.count == 1)

    try await manager.openFile(url: js, checksScriptKind: true)
    try await manager.openFile(url: sql)
    #expect(manager.tabs.map(\.fileURL) == [nil, js, sql])
    #expect(manager.tabs.dropFirst().allSatisfy { $0.documentType == .sqlFile })
  }

  @Test("A PostgreSQL workspace makes Untitled.sql and refuses a user .js open")
  func postgresWorkspace() async throws {
    let (folder, js, sql) = try Self.makeFiles()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager(Self.postgres)
    defer { suite.removePersistentDomain(forName: name) }

    #expect(!manager.isMongoWorkspace)
    #expect(manager.newScriptLabel == "New SQL File")
    manager.newSQLFile()
    #expect(manager.tabs.map(\.title) == ["Untitled.sql"])

    await #expect(throws: (any Error).self) {
      try await manager.openFile(url: js, checksScriptKind: true)
    }
    #expect(manager.tabs.count == 1)

    try await manager.openFile(url: sql, checksScriptKind: true)
    #expect(manager.tabs.map(\.fileURL) == [nil, sql])
  }

  @Test("A workspace with no connection opens both .js and .sql")
  func noConnectionWorkspace() async throws {
    let (folder, js, sql) = try Self.makeFiles()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager(nil)
    defer { suite.removePersistentDomain(forName: name) }

    try await manager.openFile(url: js, checksScriptKind: true)
    try await manager.openFile(url: sql, checksScriptKind: true)
    #expect(manager.tabs.map(\.fileURL) == [js, sql])
  }

  @Test("Script helpers pick the extension and the refusal from the connection type")
  func scriptHelpers() {
    let js = URL(fileURLWithPath: "/tmp/q.js")
    let sql = URL(fileURLWithPath: "/tmp/q.sql")
    #expect(TabDocumentType.from(url: js) == .sqlFile)
    #expect(TabDocumentType.from(url: URL(fileURLWithPath: "/tmp/Q.JS")) == .sqlFile)

    #expect(TabDocumentType.scriptExtension(for: .mongodb) == "js")
    #expect(TabDocumentType.scriptExtension(for: .postgresql) == "sql")
    #expect(TabDocumentType.scriptExtension(for: nil) == "sql")

    #expect(TabDocumentType.scriptKindRefusal(for: sql, databaseType: .mongodb) != nil)
    #expect(TabDocumentType.scriptKindRefusal(for: js, databaseType: .mongodb) == nil)
    #expect(TabDocumentType.scriptKindRefusal(for: js, databaseType: .postgresql) != nil)
    #expect(TabDocumentType.scriptKindRefusal(for: sql, databaseType: .postgresql) == nil)
    #expect(TabDocumentType.scriptKindRefusal(for: js, databaseType: nil) == nil)
    #expect(TabDocumentType.scriptKindRefusal(for: sql, databaseType: nil) == nil)
    #expect(RecentManager.isRecentDocument(js))
  }
}
