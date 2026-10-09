// DuckDBFileQueryTests.swift
// "Query Parquet/CSV File...": palette visibility, the inserted SQL (function, escaping,
// canonical path), the picked-file access list, and (gated) a real DuckDB session that reads
// the picked files and nothing else.

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDBFileQueryTests")
@MainActor
struct DuckDBFileQueryTests {
  private static let actionID = "query-duckdb-file"

  @Test("The action is listed only for a DuckDB workspace, connected or not")
  func actionVisibleOnlyForDuckDB() {
    let none = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    let postgres = WorkspaceManager(
      workspace: Workspace(connectionConfig: ConnectionConfig(host: "db", database: "app")),
      restoreTabs: false)
    let sqlite = WorkspaceManager(
      workspace: Workspace(
        connectionConfig: ConnectionConfig(databaseType: .sqlite, database: "/tmp/x.sqlite")),
      restoreTabs: false)
    for manager in [none, postgres, sqlite] {
      #expect(!manager.paletteSources().actions.contains { $0.id == Self.actionID })
      #expect(!manager.perform(.action(id: Self.actionID, title: "")))
    }

    let duckDB = WorkspaceManager(
      workspace: Workspace(
        connectionConfig: ConnectionConfig(
          databaseType: .duckdb, database: DuckDBSession.inMemoryPath)),
      restoreTabs: false)
    let action = duckDB.paletteSources().actions.first { $0.id == Self.actionID }
    #expect(action?.title == "Query Parquet/CSV File...")
  }

  @Test(
    "Parquet maps to read_parquet, anything else to read_csv",
    arguments: [
      ("parquet", "read_parquet"), ("PARQUET", "read_parquet"), ("csv", "read_csv"),
      ("tsv", "read_csv"), ("", "read_csv"),
    ])
  func readFunction(pathExtension: String, function: String) {
    #expect(DuckDBFileQuery.readFunction(forExtension: pathExtension) == function)
  }

  @Test(
    "The path is one DuckDB string literal",
    arguments: [
      ("/data/a.csv", "'/data/a.csv'"),
      ("/data/it's \"x\".csv", "'/data/it''s \"x\".csv'"),
      ("/my files/a b.csv", "'/my files/a b.csv'"),
      ("/données/日本 é.csv", "'/données/日本 é.csv'"),
      ("/data/back\\slash.csv", "'/data/back\\slash.csv'"),
    ])
  func sqlQuotesPath(path: String, literal: String) throws {
    #expect(
      try DuckDBFileQuery.sql(path: path, function: "read_csv")
        == "SELECT * FROM read_csv(\(literal)) LIMIT 100;")
  }

  @Test(
    "A path with NUL or a line break is refused",
    arguments: ["/data/a\0b.csv", "/data/a\nb.csv", "/data/a\rb.csv", "/data/a\r\nb.csv"])
  func sqlRejectsControlCharacters(path: String) {
    #expect(throws: DuckDBFileQuery.Failure.unsupportedPath) {
      try DuckDBFileQuery.sql(path: path, function: "read_csv")
    }
  }

  @Test("The canonical path resolves linked files and folders")
  func canonicalPathResolvesSymlinks() throws {
    let folder = try Self.makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("data.csv")
    try Data("a\n1\n".utf8).write(to: file)
    let link = folder.appendingPathComponent("link.csv")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    let alias = folder.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)

    // Through a linked folder and a linked file
    let canonical = try DuckDBFileQuery.canonicalPath(of: alias.appendingPathComponent("link.csv"))
    #expect(canonical.hasSuffix("/data.csv"))
    #expect(!canonical.contains("/alias/"))
    let type = try FileManager.default.attributesOfItem(atPath: canonical)[.type]
    #expect(type as? FileAttributeType == .typeRegular)
    #expect(try DuckDBFileQuery.canonicalPath(of: file) == canonical)
    #expect(throws: DuckDBFileQuery.Failure.self) {
      try DuckDBFileQuery.canonicalPath(of: folder.appendingPathComponent("missing.csv"))
    }
  }

  @Test("Picking the same file twice holds one access; disconnect releases every file")
  func accessListDedupesAndReleases() async {
    let counter = AccessCounter()
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.accessHooks.startAccess = { url in
      SecurityScopedAccessToken(
        url: url,
        start: { _ in
          counter.started += 1
          return true
        },
        stop: { _ in counter.stopped += 1 })
    }
    let url = URL(fileURLWithPath: "/data/b.csv")

    #expect(manager.addDuckDBFileAccess(url, path: "/data/b.csv"))
    #expect(!manager.addDuckDBFileAccess(url, path: "/data/b.csv"))
    #expect(manager.addDuckDBFileAccess(url, path: "/data/a.parquet"))
    #expect(manager.duckDBAllowedPaths == ["/data/a.parquet", "/data/b.csv"])
    #expect(counter.started == 2)

    await manager.performDisconnect()
    #expect(manager.duckDBAllowedPaths.isEmpty)
    #expect(counter.stopped == 2)
  }

  static func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-duckdb-files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
}

private nonisolated final class AccessCounter: @unchecked Sendable {
  var started = 0
  var stopped = 0
}

@MainActor
private final class PickState {
  var picked: URL
  var prompts = 0

  init(picked: URL) { self.picked = picked }
}

/// Nested so `-only-testing:DbloreTests/DuckDBFileQueryTests` runs it when the gate is on.
extension DuckDBFileQueryTests {
  @Suite("Picked files through a real DuckDB session", .requiresDuckDBPlugin, .serialized)
  @MainActor
  struct Integration {
    private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
    private let inMemory = ConnectionConfig(
      databaseType: .duckdb, database: DuckDBSession.inMemoryPath, sslMode: .disable,
      safeMode: .silent, protectedMode: false)

    private func makeConnectionManager() -> DatabaseConnectionManager {
      DatabaseConnectionManager(
        sessionFactory: AppDatabaseSessionFactory(duckDBLibraryLoader: {
          { try DuckDBTestPlugin.library() }
        }))
    }

    /// A CSV, a Parquet written by DuckDB itself (COPY to a granted path), and a sibling CSV.
    private func makeFiles(in folder: URL) async throws -> (csv: URL, parquet: URL, sibling: URL) {
      let csv = folder.appendingPathComponent("people's data.csv")
      try Data("id,name\n1,Ana\n2,Bé\n".utf8).write(to: csv)
      let sibling = folder.appendingPathComponent("secret.csv")
      try Data("id\n9\n".utf8).write(to: sibling)
      let parquet = folder.appendingPathComponent("numbers.parquet")
      let target = try DuckDBFileQuery.canonicalPath(of: folder) + "/numbers.parquet"
      let writer = makeConnectionManager()
      try await writer.connect(config: inMemory, extraAllowedPaths: [target])
      _ = try await writer.execute(
        userSQL: "COPY (SELECT range AS n FROM range(3)) TO "
          + "\(SQLDialect.duckdb.literal(.string(target))) (FORMAT PARQUET)",
        policy: open)
      await writer.disconnect()
      return (csv, parquet, sibling)
    }

    private func query(
      _ url: URL, on manager: DatabaseConnectionManager
    ) async throws
      -> [[CellValue]]
    {
      let sql = try DuckDBFileQuery.sql(
        path: DuckDBFileQuery.canonicalPath(of: url),
        function: DuckDBFileQuery.readFunction(forExtension: url.pathExtension))
      return try await manager.execute(userSQL: sql, policy: open).rows
    }

    @Test("A session opened with the picked paths reads them and refuses a sibling")
    func factoryReadsPickedFiles() async throws {
      let folder = try DuckDBFileQueryTests.makeFolder()
      defer { try? FileManager.default.removeItem(at: folder) }
      let files = try await makeFiles(in: folder)
      let paths = try [files.csv, files.parquet].map(DuckDBFileQuery.canonicalPath(of:))

      let reader = makeConnectionManager()
      try await reader.connect(config: inMemory, extraAllowedPaths: paths)
      defer { Task { await reader.disconnect() } }
      #expect(
        try await query(files.csv, on: reader) == [
          [.int(1), .string("Ana")], [.int(2), .string("Bé")],
        ])
      #expect(try await query(files.parquet, on: reader) == [[.int(0)], [.int(1)], [.int(2)]])
      await #expect(throws: (any Error).self) {
        _ = try await query(files.sibling, on: reader)
      }
    }

    @Test("The workspace action reconnects with each new file and keeps earlier ones")
    func workspaceActionGrantsFiles() async throws {
      let folder = try DuckDBFileQueryTests.makeFolder()
      defer { try? FileManager.default.removeItem(at: folder) }
      let files = try await makeFiles(in: folder)
      let connection = makeConnectionManager()
      let manager = WorkspaceManager(
        workspace: Workspace(connectionConfig: inMemory), restoreTabs: false,
        connectionManager: connection)
      defer { Task { await manager.performDisconnect() } }
      try await manager.connect(config: inMemory)
      let state = PickState(picked: files.csv)
      manager.duckDBReconnectPrompt = {
        state.prompts += 1
        return true
      }
      manager.accessHooks.chooseDataFile = { _ in state.picked }

      let csvSQL = try #require(await manager.queryDuckDBFile())
      let csvPath = try DuckDBFileQuery.canonicalPath(of: files.csv)
      #expect(csvSQL.hasPrefix("SELECT * FROM read_csv('"))
      #expect(manager.duckDBAllowedPaths == [csvPath])
      #expect(csvSQL.contains("people''s data.csv"))
      #expect(state.prompts == 1)
      #expect(manager.connectionState == .connected)
      #expect(try await connection.execute(userSQL: csvSQL, policy: open).rows.count == 2)

      // Same file again: no prompt, no reconnect
      let epoch = await connection.connectionEpoch
      #expect(await manager.queryDuckDBFile() == csvSQL)
      #expect(state.prompts == 1)
      #expect(await connection.connectionEpoch == epoch)

      state.picked = files.parquet
      let parquetSQL = try #require(await manager.queryDuckDBFile())
      #expect(parquetSQL.hasPrefix("SELECT * FROM read_parquet("))
      #expect(state.prompts == 2)
      #expect(await connection.duckDBAllowedPaths == manager.duckDBAllowedPaths)
      #expect(manager.duckDBAllowedPaths.count == 2)
      #expect(try await connection.execute(userSQL: parquetSQL, policy: open).rows.count == 3)
      #expect(try await connection.execute(userSQL: csvSQL, policy: open).rows.count == 2)
      await #expect(throws: (any Error).self) {
        _ = try await query(files.sibling, on: connection)
      }

      // Declining the in-memory prompt changes nothing
      manager.duckDBReconnectPrompt = { false }
      state.picked = files.sibling
      #expect(await manager.queryDuckDBFile() == nil)
      #expect(manager.duckDBAllowedPaths.count == 2)

      await manager.performDisconnect()
      #expect(manager.duckDBAllowedPaths.isEmpty)
    }
  }
}
