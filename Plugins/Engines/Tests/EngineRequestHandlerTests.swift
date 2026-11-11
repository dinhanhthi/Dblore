// EngineRequestHandlerTests.swift
// The protocol v1 request-to-event mapping of the shared handler, driven with a scripted driver
// (no database, no network): rows only on credit, oversized cells as chunks, cancel routing,
// and the unsupported answers of a connection without binds, settings or catalog.

import Foundation
import Testing

// MARK: - Fakes

/// A connection that answers every statement with `columns` and `rows`; `blocksAfter` rows in,
/// `nextRow` waits until interrupted and then fails, as a server statement would
nonisolated private final class ScriptedConnection: EngineConnection, @unchecked Sendable {
  let columns: [EngineEvent.Column]
  let rows: [[EngineCell]]
  let blocksAfter: Int?
  private let condition = NSCondition()
  private var interrupted = false
  private var next = 0
  private(set) var interrupts = 0
  private(set) var statements: [(sql: String, binds: [String?])] = []

  init(columns: [EngineEvent.Column], rows: [[EngineCell]], blocksAfter: Int? = nil) {
    self.columns = columns
    self.rows = rows
    self.blocksAfter = blocksAfter
  }

  var serverVersion: String { "scripted" }

  func interrupt() {
    condition.withLock {
      interrupted = true
      interrupts += 1
      condition.broadcast()
    }
  }

  func resetInterrupt() { condition.withLock { interrupted = false } }

  func execute(_ sql: String) throws {
    condition.withLock {
      statements.append((sql, []))
      next = -1
    }
  }

  func nextResult() throws -> [EngineEvent.Column]? {
    condition.withLock {
      guard next == -1 else { return nil }
      next = 0
      return columns
    }
  }

  func nextRow() throws -> [EngineCell]? {
    condition.lock()
    defer { condition.unlock() }
    if let blocksAfter, next >= blocksAfter {
      while !interrupted { condition.wait() }
      throw EngineFailure(code: .query, message: "interrupted")
    }
    guard next >= 0, next < rows.count else { return nil }
    defer { next += 1 }
    return rows[next]
  }

  var affectedRows: Int? { nil }
  func discardResults() {}
  var isLost: Bool { false }
  func close() {}
}

nonisolated private struct ScriptedDriver: EngineDriver {
  let connection: any EngineConnection
  var engine: String { "scripted" }
  var queryLanguage: String { "sql" }
  var libraries: [String: String] { [:] }
  func connect(_ open: EngineRequest.Open) throws -> any EngineConnection { connection }
}

/// Every event the handler emitted, in order (shared with ClickHouseDriverTests)
nonisolated final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [EngineEvent] = []

  var sink: EventSink {
    EventSink { [self] data in
      guard let event = try? EnginePluginProtocol.decodeEvent(data) else { return }
      lock.withLock { events.append(event) }
    }
  }

  func kinds(_ id: String) -> [EngineEvent.Kind] {
    lock.withLock { events.filter { $0.id == id }.map(\.kind) }
  }

  func rowsEvents(_ id: String) -> Int {
    kinds(id).filter { if case .rows = $0 { true } else { false } }.count
  }

  func isFinished(_ id: String) -> Bool {
    kinds(id).contains {
      switch $0 {
      case .opened, .done, .cancelled, .error, .settingsApplied, .catalog: true
      default: false
      }
    }
  }
}

// MARK: - Helpers

nonisolated private struct Harness {
  let handler: EngineRequestHandler
  let log = EventLog()

  init(_ connection: any EngineConnection) {
    handler = EngineRequestHandler(driver: ScriptedDriver(connection: connection))
  }

  func send(_ id: String, _ kind: EngineRequest.Kind, connection: Int? = 1) throws {
    let data = try EnginePluginProtocol.encodeRequest(
      EngineRequest(id: id, connection: connection, kind: kind))
    handler.receive(data, sink: log.sink)
  }

  func open() async throws {
    try send(
      "open",
      .open(
        .init(
          host: "localhost", port: 1, tlsServerName: "localhost", database: "", username: "",
          password: "", tls: .init(mode: .off), timeoutSeconds: 5, readOnly: false, options: [:]
        )))
    try await waitUntil { log.isFinished("open") }
    #expect(log.kinds("open") == [.opened(serverVersion: "scripted")])
  }

  func query(_ id: String, binds: [String?] = []) throws {
    try send(id, .query(.init(sql: "SELECT", binds: binds, language: "sql", batchRows: 1)))
  }
}

/// Polls `condition` for up to 5 s
nonisolated func waitUntil(_ condition: () -> Bool) async throws {
  for _ in 0..<500 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("timed out")
}

// MARK: - Tests

@Suite struct EngineRequestHandlerTests {

  @Test func rowsGoOnlyOnCredit() async throws {
    let rows = (0..<6).map { [EngineCell.int($0)] }
    let harness = Harness(ScriptedConnection(columns: [.init(name: "n", type: "int")], rows: rows))
    try await harness.open()
    try harness.query("q")

    // Two `rows` events ahead of any `more`, then nothing more
    try await waitUntil { harness.log.rowsEvents("q") == 2 }
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.log.rowsEvents("q") == 2)
    #expect(!harness.log.isFinished("q"))

    // Each `more` lets exactly one more go
    try harness.send("m1", .more(target: "q"), connection: nil)
    try await waitUntil { harness.log.rowsEvents("q") == 3 }
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.log.rowsEvents("q") == 3)

    for index in 0..<3 { try harness.send("m\(index + 2)", .more(target: "q"), connection: nil) }
    try await waitUntil { harness.log.isFinished("q") }
    let kinds = harness.log.kinds("q")
    #expect(kinds.first == .columns([.init(name: "n", type: "int")]))
    #expect(kinds.last == .done(affectedRows: nil, tag: ""))
    let streamed = kinds.flatMap { kind -> [[EngineCell]] in
      if case .rows(let rows) = kind { rows } else { [] }
    }
    #expect(streamed == rows)
  }

  @Test func oversizedCellsArriveAsChunks() async throws {
    let text = String(repeating: "é", count: 400_000) + "\n\u{1}"  // ~800 KiB, escapes too
    let json = "[" + Array(repeating: "\"x\"", count: 200_000).joined(separator: ",") + "]"
    let row: [EngineCell] = [.int(1), .text(text), .json(json)]
    let harness = Harness(
      ScriptedConnection(
        columns: [
          .init(name: "id", type: "int"), .init(name: "t", type: "text"),
          .init(name: "j", type: "json"),
        ], rows: [row]))
    try await harness.open()
    try harness.query("q")
    try await waitUntil { harness.log.isFinished("q") }

    var assembler = EngineChunkAssembler(columnCount: 3)
    var rebuilt: [[EngineCell]] = []
    var chunks = 0
    for kind in harness.log.kinds("q") {
      switch kind {
      case .chunk(let chunk):
        chunks += 1
        try assembler.append(chunk)
      case .rows(let rows):
        #expect(rows == [[.int(1), .chunked, .chunked]])
        rebuilt += try assembler.resolve(rows)
      case .error(let failure): Issue.record("error: \(failure.message)")
      default: break
      }
    }
    #expect(chunks > 2)
    #expect(rebuilt == [row])
    #expect(harness.log.kinds("q").last == .done(affectedRows: nil, tag: ""))
  }

  @Test func chunksWaitForTheirRowsCredit() async throws {
    // Three rows with one big cell each: the third row's chunks need a `more`
    let big = EngineCell.text(String(repeating: "a", count: 600_000))
    let harness = Harness(
      ScriptedConnection(
        columns: [.init(name: "t", type: "text")], rows: [[big], [big], [big]]))
    try await harness.open()
    try harness.query("q")
    try await waitUntil { harness.log.rowsEvents("q") == 2 }
    try await Task.sleep(for: .milliseconds(200))
    let chunksBefore = harness.log.kinds("q").filter {
      if case .chunk = $0 { true } else { false }
    }.count
    try harness.send("m", .more(target: "q"), connection: nil)
    try await waitUntil { harness.log.isFinished("q") }
    let chunksAfter = harness.log.kinds("q").filter {
      if case .chunk = $0 { true } else { false }
    }.count
    #expect(chunksAfter > chunksBefore)
    #expect(harness.log.rowsEvents("q") == 3)
  }

  @Test func cancelReachesTheRunningQuery() async throws {
    let connection = ScriptedConnection(
      columns: [.init(name: "n", type: "int")], rows: [[.int(1)], [.int(2)]], blocksAfter: 1)
    let harness = Harness(connection)
    try await harness.open()
    try harness.query("q")
    // The first row waits in the batch while the statement blocks on the second
    try await waitUntil { harness.log.kinds("q").count == 1 }

    try harness.send("c", .cancel(target: "q"), connection: nil)
    try await waitUntil { harness.log.isFinished("q") }
    #expect(harness.log.kinds("q").last == .cancelled)
    #expect(connection.interrupts == 1)
    // A cancel has no answer of its own
    #expect(harness.log.kinds("c").isEmpty)
  }

  @Test func cancelOfAQueuedQueryAnswersCancelledWithoutRunningIt() async throws {
    let connection = ScriptedConnection(
      columns: [.init(name: "n", type: "int")], rows: [[.int(1)]], blocksAfter: 0)
    let harness = Harness(connection)
    try await harness.open()
    try harness.query("first")
    try harness.query("second")
    // `first` runs (its columns went) and blocks; `second` waits behind it
    try await waitUntil { harness.log.kinds("first").count == 1 }
    try harness.send("c2", .cancel(target: "second"), connection: nil)
    try harness.send("c1", .cancel(target: "first"), connection: nil)
    try await waitUntil { harness.log.isFinished("first") && harness.log.isFinished("second") }
    #expect(harness.log.kinds("second") == [.cancelled])
    #expect(connection.statements.count == 1)
  }

  @Test func withoutThemBindsSettingsAndCatalogAreUnsupported() async throws {
    let harness = Harness(
      ScriptedConnection(columns: [.init(name: "n", type: "int")], rows: [[.int(1)]]))
    try await harness.open()
    try harness.query("q", binds: ["a"])
    try harness.send(
      "s",
      .settings(.init(statementTimeoutSeconds: 1, lockTimeoutSeconds: 0, idleTimeoutSeconds: 0)))
    try harness.send("k", .catalog(.init(read: .tables, args: [:])))
    try await waitUntil {
      ["q", "s", "k"].allSatisfy(harness.log.isFinished)
    }
    for id in ["q", "s", "k"] {
      guard case .error(let failure)? = harness.log.kinds(id).last else {
        Issue.record("\(id) did not fail")
        continue
      }
      #expect(failure.code == .unsupported)
    }
  }
}
