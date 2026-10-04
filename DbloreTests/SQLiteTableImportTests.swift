import Foundation
import Testing

@testable import Dblore

@Suite("SQLite table import", .serialized)
@MainActor
struct SQLiteTableImportTests {
  private func withDatabase(
    protectedMode: Bool = false, protectionLevel: ConnectionProtectionLevel = .none,
    _ body: (DatabaseConnectionManager, NotebookViewModel) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
      }
    }
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path,
      username: "", rememberConnection: false, protectionLevel: protectionLevel,
      safeMode: .silent, protectedMode: protectedMode)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    do {
      try await body(manager, viewModel)
    } catch {
      await finish(manager)
      throw error
    }
    await finish(manager)
  }

  private func finish(_ manager: DatabaseConnectionManager) async {
    if await !manager.transactionSnapshot().isIdle {
      try? await manager.rollbackAppTransaction()
    }
    await manager.disconnect()
  }

  private static func model(
    _ text: String, extension fileExtension: String
  ) async throws -> TableImportModel {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-\(UUID().uuidString).\(fileExtension)")
    try Data(text.utf8).write(to: url)
    let model = TableImportModel()
    await model.loadFile(url)
    return model
  }

  @Test("CSV creates a table with integer booleans", .timeLimit(.minutes(1)))
  func newTableCSV() async throws {
    try await withDatabase { manager, viewModel in
      let model = try await Self.model("name,active\nAda,true\nBob,false\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .new(schema: nil, table: "people")
      #expect(await model.submit(to: viewModel))
      let result = try await manager.executeInternal(
        "SELECT name, active, typeof(active) FROM people ORDER BY name")
      #expect(
        result.rows == [
          [.string("Ada"), .int(1), .string("integer")],
          [.string("Bob"), .int(0), .string("integer")],
        ])
    }
  }

  @Test("JSON appends to an existing table", .timeLimit(.minutes(1)))
  func existingTableJSON() async throws {
    try await withDatabase { manager, viewModel in
      _ = try await manager.executeInternal("CREATE TABLE people (id INTEGER, name TEXT)")
      let model = try await Self.model(
        "{\"id\":1,\"name\":\"Ada\"}\n{\"id\":2,\"name\":\"Bob\"}\n", extension: "json")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: "people")
      #expect(await model.submit(to: viewModel))
      let result = try await manager.executeInternal("SELECT id, name FROM people ORDER BY id")
      #expect(result.rows == [[.int(1), .string("Ada")], [.int(2), .string("Bob")]])
    }
  }

  @Test("Protected mode leaves imported rows pending", .timeLimit(.minutes(1)))
  func protectedImport() async throws {
    try await withDatabase(protectedMode: true) { manager, viewModel in
      _ = try await manager.executeInternal("CREATE TABLE people (id INTEGER)")
      let model = try await Self.model("id\n1\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: "people")
      #expect(await model.submit(to: viewModel))
      let snapshot = await manager.transactionSnapshot()
      #expect(!snapshot.isIdle)
      #expect(!snapshot.pending.isEmpty)
      try await manager.rollbackAppTransaction()
      let result = try await manager.executeInternal("SELECT id FROM people")
      #expect(result.rows.isEmpty)
    }
  }

  @Test("Schema-only protection blocks CREATE before execution", .timeLimit(.minutes(1)))
  func schemaOnly() async throws {
    try await withDatabase(protectionLevel: .schemaOnly) { manager, viewModel in
      let model = try await Self.model("id\n1\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .new(schema: nil, table: "people")
      #expect(!(await model.submit(to: viewModel)))
      #expect(model.errorMessage?.contains("Schema change") == true)
      let result = try await manager.executeInternal(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'people'")
      #expect(result.rows.isEmpty)
    }
  }

  @Test("A bad row rolls back the whole import", .timeLimit(.minutes(1)))
  func badRowRollsBack() async throws {
    try await withDatabase { manager, viewModel in
      _ = try await manager.executeInternal("CREATE TABLE people (id INTEGER PRIMARY KEY)")
      let model = try await Self.model("id\n1\n1\n", extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: "people")
      #expect(!(await model.submit(to: viewModel)))
      #expect(model.errorMessage?.contains("Rows 1–2") == true)
      let result = try await manager.executeInternal("SELECT id FROM people")
      #expect(result.rows.isEmpty)
    }
  }

  @Test(
    "Failed import inside a manual transaction leaves no committable rows", .timeLimit(.minutes(1)))
  func badRowInManualTransaction() async throws {
    try await withDatabase { manager, viewModel in
      _ = try await manager.executeInternal("CREATE TABLE people (id INTEGER PRIMARY KEY)")
      let policy = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
      _ = try await manager.execute(userSQL: "BEGIN", policy: policy)
      let input = "id\n" + (1...1000).map(String.init).joined(separator: "\n") + "\n1\n"
      let model = try await Self.model(input, extension: "csv")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: "people")
      #expect(!(await model.submit(to: viewModel)))
      _ = try await manager.execute(userSQL: "COMMIT", policy: policy)
      let result = try await manager.executeInternal("SELECT id FROM people")
      #expect(result.rows.isEmpty)
    }
  }
}
