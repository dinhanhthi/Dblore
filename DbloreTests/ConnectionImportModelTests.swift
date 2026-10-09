// ConnectionImportModelTests.swift
// Unit tests for the connection import preview model. Importers, history and save are injected,
// so no test touches the real Keychain or UserDefaults.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Connection import model")
struct ConnectionImportModelTests {

  // MARK: - Fixtures

  private typealias ImportResult = (connections: [ImportedConnection], warnings: [String])

  private static func imported(
    _ name: String, host: String = "db.example", database: String = "app",
    password: String? = nil
  ) -> ImportedConnection {
    ImportedConnection(
      config: ConnectionConfig(
        host: host, port: 5432, database: database, username: "ada", rememberConnection: false,
        name: name),
      password: password, source: .uri)
  }

  private static func entry(database: String) -> ConnectionHistoryEntry {
    ConnectionHistoryEntry(
      config: ConnectionConfig(
        host: "db.example", port: 5432, database: database, username: "ada",
        rememberConnection: true))
  }

  private static func model(
    result: ImportResult = ([], []), history: [ConnectionHistoryEntry] = [],
    extraSavedKeys: Set<String> = [],
    save: @escaping @MainActor ([ImportedConnection]) -> BulkSaveReport = { _ in .init() }
  ) -> ConnectionImportModel {
    ConnectionImportModel(
      importFile: { _, _ in result }, importText: { _, _ in result },
      loadHistory: { history },
      loadSavedKeys: { Set(history.map(\.keychainKey)).union(extraSavedKeys) }, save: save)
  }

  /// A model reading files with the production importers, without saved history.
  private static func productionModel() -> ConnectionImportModel {
    ConnectionImportModel(loadHistory: { [] }, loadSavedKeys: { [] }, save: { _ in .init() })
  }

  /// Blocks the first file import until released, so a test can overlap two loads.
  private final class Gate: @unchecked Sendable {
    private let release = DispatchSemaphore(value: 0)
    func wait() { release.wait() }
    func open() { release.signal() }
  }

  /// A model whose file import blocks on `gate` and returns `file`; text import returns `text`.
  private static func gatedModel(
    gate: Gate, file: ImportResult, text: ImportResult
  ) -> ConnectionImportModel {
    ConnectionImportModel(
      importFile: { _, _ in
        gate.wait()
        return file
      },
      importText: { _, _ in text },
      loadHistory: { [] }, loadSavedKeys: { [] }, save: { _ in .init() })
  }

  /// Starts a file load and returns once it is in flight.
  private static func startBlockedLoad(_ model: ConnectionImportModel) async -> Task<Void, Never> {
    let task = Task { await model.load(url: URL(fileURLWithPath: "/tmp/none")) }
    while !model.isLoading { await Task.yield() }
    return task
  }

  /// A temporary folder removed on deinit.
  private final class Folder {
    let url: URL
    init() throws {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("connection-import-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ text: String, to name: String) throws {
      try write(Data(text.utf8), to: name)
    }

    func write(_ data: Data, to name: String) throws {
      try data.write(to: url.appendingPathComponent(name))
    }
  }

  /// Records values from a `@Sendable` closure.
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func append(_ value: Bool) { lock.withLock { values.append(value) } }
    var all: [Bool] { lock.withLock { values } }
  }

  // MARK: - Loading

  @Test("A DBeaver folder without saved passwords gives rows without a password")
  func dbeaverWithoutSecrets() async throws {
    let folder = try Folder()
    try folder.write(
      """
      {"folders": {}, "connections": {"postgres-jdbc-1": {"provider": "postgresql",
      "driver": "postgres-jdbc", "name": "Prod", "configuration": {"host": "db.example.com",
      "port": "5433", "database": "sales", "user": "alice", "auth-model": "native"}}}}
      """, to: "data-sources.json")
    let model = Self.productionModel()
    model.source = .dbeaver

    await model.load(url: folder.url)

    #expect(model.errorMessage == nil)
    #expect(!model.isLoading)
    let row = try #require(model.rows.first)
    #expect(model.rows.count == 1)
    #expect(row.name == "Prod")
    #expect(row.address == "db.example.com:5433/sales")
    #expect(row.user == "alice")
    #expect(row.engine == "PostgreSQL")
    #expect(!row.hasPassword)
    #expect(!row.hasSSH)
    #expect(row.isSelected)
  }

  @Test("The importer runs off the main thread")
  func loadsOffMain() async {
    let recorder = Recorder()
    let model = ConnectionImportModel(
      importFile: { _, _ in
        recorder.append(Thread.isMainThread)
        return ([], [])
      },
      importText: { _, _ in
        recorder.append(Thread.isMainThread)
        return ([], [])
      },
      loadHistory: { [] }, loadSavedKeys: { [] }, save: { _ in .init() })

    await model.load(url: URL(fileURLWithPath: "/tmp/none"))
    await model.loadText("postgresql://a@b/c")

    #expect(recorder.all == [false, false])
  }

  @Test("A malformed file gives a plain error without its content")
  func malformedFileError() async throws {
    let folder = try Folder()
    let sentinel = "SENTINEL-not-json-s3cret"
    try folder.write(sentinel, to: "data-sources.json")
    let model = Self.productionModel()
    model.source = .dbeaver

    await model.load(url: folder.url)

    let message = try #require(model.errorMessage)
    #expect(!message.contains(sentinel))
    #expect(!message.contains(folder.url.path))
    #expect(model.rows.isEmpty)
    #expect(!model.isLoading)
  }

  @Test("URI text gives one row and keeps the password out of display strings")
  func uriText() async throws {
    let model = Self.productionModel()
    model.source = .uri

    await model.loadText("postgresql://bob:hunter2@db.example.com:6543/shop")

    let row = try #require(model.rows.first)
    #expect(model.rows.count == 1)
    #expect(row.address == "db.example.com:6543/shop")
    #expect(row.user == "bob")
    #expect(row.hasPassword)
    let display = [row.name, row.address, row.user, row.engine] + row.warnings
    #expect(!display.contains { $0.contains("hunter2") })
  }

  @Test("A malformed URI gives a plain error without the input")
  func malformedURI() async throws {
    let model = Self.productionModel()
    model.source = .uri

    await model.loadText("mysql://bob:hunter2@host/db")

    let message = try #require(model.errorMessage)
    #expect(!message.contains("hunter2"))
    #expect(model.rows.isEmpty)
  }

  @Test("A load that finishes after a newer one is discarded")
  func staleLoadDiscarded() async {
    let gate = Gate()
    let model = Self.gatedModel(
      gate: gate, file: ([Self.imported("Stale")], []),
      text: ([Self.imported("Fresh", database: "fresh")], []))

    let first = await Self.startBlockedLoad(model)
    await model.loadText("postgresql://a@b/c")
    #expect(model.rows.map(\.name) == ["Fresh"])
    #expect(!model.isLoading)

    gate.open()
    await first.value

    #expect(model.rows.map(\.name) == ["Fresh"])
    #expect(!model.isLoading)
  }

  @Test("Reset clears the preview and drops a load in flight")
  func resetDropsInFlightLoad() async {
    let gate = Gate()
    let model = Self.gatedModel(
      gate: gate, file: ([Self.imported("Stale")], ["skipped"]),
      text: ([Self.imported("Shown")], ["note"]))
    await model.loadText("postgresql://a@b/c")
    #expect(model.rows.count == 1)

    let first = await Self.startBlockedLoad(model)
    model.source = .uri
    model.reset()
    #expect(model.rows.isEmpty)
    #expect(model.warnings.isEmpty)
    #expect(!model.isLoading)

    gate.open()
    await first.value

    #expect(model.rows.isEmpty)
    #expect(model.warnings.isEmpty)
    #expect(model.errorMessage == nil)
    #expect(!model.isLoading)
  }

  // MARK: - .pgpass files

  @Test("An oversized .pgpass file is too large to import")
  func pgpassTooLarge() async throws {
    let folder = try Folder()
    try folder.write(
      Data(repeating: 0x61, count: ConnectionImportModel.maxPgpassSize + 1), to: "pgpass")
    let model = Self.productionModel()

    await model.load(url: folder.url.appendingPathComponent("pgpass"))

    #expect(model.errorMessage == "The file is too large to import.")
    #expect(model.rows.isEmpty)
  }

  @Test("A non-UTF-8 .pgpass file is unreadable")
  func pgpassNotUTF8() async throws {
    let folder = try Folder()
    try folder.write(Data([0xFF, 0xFE, 0xFD]), to: "pgpass")
    let model = Self.productionModel()

    await model.load(url: folder.url.appendingPathComponent("pgpass"))

    #expect(model.errorMessage == "The file could not be read.")
    #expect(model.rows.isEmpty)
  }

  @Test("A .pgpass file that cannot be opened is unreadable, not too large")
  func pgpassNoPermission() async throws {
    let folder = try Folder()
    try folder.write("db.example:5432:app:ada:pw\n", to: "pgpass")
    let file = folder.url.appendingPathComponent("pgpass")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    let model = Self.productionModel()

    await model.load(url: file)

    #expect(model.errorMessage == "The file could not be read.")
    #expect(model.rows.isEmpty)
  }

  @Test("A symlinked .pgpass file is rejected")
  func pgpassSymlinkRejected() async throws {
    let folder = try Folder()
    try folder.write("db.example:5432:app:ada:pw\n", to: "pgpass")
    let link = folder.url.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: folder.url.appendingPathComponent("pgpass"))
    let model = Self.productionModel()

    await model.load(url: folder.url.appendingPathComponent("pgpass"))
    #expect(model.rows.count == 1)

    await model.load(url: link)

    #expect(model.errorMessage == "The file could not be read.")
    #expect(model.rows.isEmpty)
  }

  // MARK: - Duplicates and selection

  @Test("Rows matching saved history are flagged and deselected")
  func duplicatesDeselected() async {
    let model = Self.model(
      result: ([Self.imported("Saved"), Self.imported("New", database: "other")], []),
      history: [Self.entry(database: "app")])

    await model.load(url: URL(fileURLWithPath: "/tmp/none"))

    #expect(model.rows.map(\.duplicateReason) == [.alreadySaved, nil])
    #expect(model.rows.map(\.isSelected) == [false, true])
    #expect(model.selectedCount == 1)
  }

  @Test("A row matching an undecodable saved row is already saved")
  func duplicateOfUndecodableSavedRow() async {
    let model = Self.model(
      result: ([Self.imported("Future")], []), extraSavedKeys: ["db.example:5432:app:ada"])

    await model.load(url: URL(fileURLWithPath: "/tmp/none"))

    #expect(model.rows.map(\.duplicateReason) == [.alreadySaved])
    #expect(model.selectedCount == 0)
  }

  @Test("A repeat within the file is a duplicate in file, the first copy stays selected")
  func duplicateInFile() async {
    let model = Self.model(
      result: (
        [Self.imported("A"), Self.imported("A again"), Self.imported("B", database: "b")], []
      ))

    await model.load(url: URL(fileURLWithPath: "/tmp/none"))

    #expect(model.rows.map(\.duplicateReason) == [nil, .duplicateInFile, nil])
    #expect(model.rows.map(\.isSelected) == [true, false, true])
  }

  @Test("Already saved rows cannot be selected, by toggle or select all")
  func alreadySavedNotSelectable() async {
    let model = Self.model(
      result: ([Self.imported("Saved"), Self.imported("New", database: "other")], []),
      history: [Self.entry(database: "app")])
    await model.load(url: URL(fileURLWithPath: "/tmp/none"))

    model.toggle(model.rows[0].id)
    #expect(model.rows.map(\.isSelected) == [false, true])
    model.selectAll()
    #expect(model.rows.map(\.isSelected) == [false, true])
  }

  @Test("Select all, deselect all and toggle")
  func selection() async throws {
    let model = Self.model(
      result: ([Self.imported("A", database: "a"), Self.imported("B", database: "b")], []))
    await model.load(url: URL(fileURLWithPath: "/tmp/none"))

    model.deselectAll()
    #expect(model.selectedCount == 0)
    let first = try #require(model.rows.first?.id)
    model.toggle(first)
    #expect(model.rows.map(\.isSelected) == [true, false])
    model.toggle(first)
    #expect(model.selectedCount == 0)
    model.selectAll()
    #expect(model.selectedCount == 2)
  }

  @Test("Free slots come from the saved history before any load")
  func freeSlotsBeforeLoad() {
    let model = Self.model(history: (1...48).map { Self.entry(database: "saved\($0)") })

    #expect(model.freeSlots == 2)
  }

  @Test("Selecting more rows than free history slots is over the limit")
  func overLimit() async {
    let history = (1...48).map { Self.entry(database: "saved\($0)") }
    let model = Self.model(
      result: ((1...3).map { Self.imported("n\($0)", database: "new\($0)") }, []),
      history: history)

    await model.load(url: URL(fileURLWithPath: "/tmp/none"))

    #expect(model.freeSlots == 2)
    #expect(model.overLimit)
    model.toggle(model.rows[0].id)
    #expect(!model.overLimit)
  }

  // MARK: - Import

  @Test("Import saves only selected rows and summarizes the report")
  func importSelected() async throws {
    var saved: [ImportedConnection] = []
    let report = BulkSaveReport(
      added: 5, skippedDuplicates: ["x", "y"], failed: [], droppedByLimit: 1)
    let model = Self.model(
      result: (
        [Self.imported("A", database: "a", password: "pw"), Self.imported("B", database: "b")], []
      ),
      save: {
        saved = $0
        return report
      })
    await model.load(url: URL(fileURLWithPath: "/tmp/none"))
    model.toggle(model.rows[1].id)

    let result = await model.importSelected()

    #expect(saved.map(\.config.name) == ["A"])
    #expect(saved.first?.password == "pw")
    #expect(result == report)
    let summary = model.summary(result)
    #expect(
      summary == "Imported 5 connections · 2 duplicates skipped · 1 over the 50-connection limit")
    #expect(!summary.contains("pw"))
    #expect(model.summary(BulkSaveReport(added: 1)) == "Imported 1 connection")
  }
}
