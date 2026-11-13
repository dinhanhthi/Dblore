// EnginePluginSessionTests.swift
// The core side of an engine plugin (`EnginePluginSession` over the runtime and router) against
// `FakeEnginePlugin`: the handshake refusal, pull credit and cancel, connection loss, plugin
// error text, the command tag the transaction code reads, and the argv feature gate.

import Foundation
import Testing

@testable import Dblore

@Suite(.timeLimit(.minutes(1)))
struct EnginePluginSessionTests {
  private static let config = ConnectionConfig(
    host: "db.example.com", port: 1433, database: "app", username: "sa", password: "pw",
    sslMode: .disable, timeoutSeconds: 5)

  private func session(
    _ fake: FakeEnginePlugin, config: ConnectionConfig = Self.config
  ) -> EnginePluginSession {
    EnginePluginSession(
      pluginID: fake.install(), config: config, hostKeyValidator: RejectUnknownSSHHostKeys())
  }

  private func isCancel(of id: String) -> (EngineRequest) -> Bool {
    { $0.kind == .cancel(target: id) }
  }

  private func queryID(_ fake: FakeEnginePlugin) throws -> String {
    try #require(fake.requests.first { if case .query = $0.kind { true } else { false } }).id
  }

  /// Polls `condition` for up to 5 s
  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
  }

  @Test("A plugin speaking another protocol version is refused before any open")
  func protocolMismatchRefused() async throws {
    let fake = FakeEnginePlugin()
    fake.entryProtocol = 2
    let session = session(fake)

    let error = await #expect(throws: DatabaseError.self) { try await session.open() }

    guard case .connectionFailed(let message) = error else {
      Issue.record("Expected connectionFailed, got \(String(describing: error))")
      return
    }
    #expect(message.contains("protocol 2"))
    #expect(fake.requests.isEmpty)
    await session.close()
  }

  @Test("Cancelling the connecting task cancels the open and throws CancellationError")
  func cancelledOpenIsCancelled() async throws {
    let fake = FakeEnginePlugin()
    fake.answersOpen = false
    let session = session(fake)
    let connecting = Task { try await session.open() }
    func openRequest() -> EngineRequest? {
      fake.requests.first { if case .open = $0.kind { true } else { false } }
    }
    try await waitUntil { openRequest() != nil }

    connecting.cancel()

    await #expect(throws: CancellationError.self) { try await connecting.value }
    #expect(fake.requests.contains(where: isCancel(of: try #require(openRequest()).id)))
    await session.close()
  }

  @Test("A read-only protected connection opens read-only on the server")
  func readOnlyProtectionOpensReadOnly() async throws {
    let fake = FakeEnginePlugin()
    let config = ConnectionConfig(
      host: "db.example.com", port: 8443, database: "app", username: "u", password: "pw",
      sslMode: .disable, timeoutSeconds: 5, protectionLevel: .readOnly)
    let session = session(fake, config: config)

    try await session.open()

    let open = fake.requests.lazy.compactMap { request -> EngineRequest.Open? in
      if case .open(let open) = request.kind { open } else { nil }
    }.first
    #expect(try #require(open).readOnly)
    await session.close()
  }

  @Test("Rows arrive only as consumed, and a cancel ends the query with cancelled")
  func rowsOnCreditAndCancel() async throws {
    let fake = FakeEnginePlugin()
    fake.batches = (0..<6).map { batch in (0..<2).map { [.int(batch * 2 + $0)] } }
    fake.batches[0][1] = [.date("2026-01-02T03:04:05.123456Z")]
    let session = session(fake)
    #expect(session.serverVersion == nil)
    try await session.open()
    #expect(session.serverVersion == "fake 1")
    let source = try await session.query("SELECT n FROM t", binds: [])
    var rows = source.rows.makeAsyncIterator()
    func more() -> Int { fake.count { if case .more = $0 { true } else { false } } }

    #expect(source.columns.map(\.name) == ["n"])
    #expect(try await rows.next() == [.int(0)])
    // Microseconds survive the instant text
    let date = try await rows.next()?.first
    #expect(date?.displayString(wallClock: true) == "2026-01-02 03:04:05.123456")
    try await waitUntil { fake.rowsEventsSent == 2 }
    try await Task.sleep(for: .milliseconds(100))
    // Two events arrived, one consumed but its last row not followed yet: no credit sent
    #expect(fake.rowsEventsSent == 2)
    #expect(more() == 0)

    #expect(try await rows.next() == [.int(2)])
    #expect(more() == 1)

    await session.interrupt()
    let cancel = fake.requests.first { if case .cancel = $0.kind { true } else { false } }
    let query = fake.requests.first { if case .query = $0.kind { true } else { false } }
    #expect(cancel?.kind == .cancel(target: try #require(query).id))
    await #expect(throws: EnginePluginSessionError.cancelled) {
      while try await rows.next() != nil {}
    }
    #expect(fake.rowsEventsSent <= more() + 2)
    await session.close()
  }

  @Test("An unsolicited closed(lost) ends the session with connectionLost")
  func closedLostYieldsConnectionLost() async throws {
    let fake = FakeEnginePlugin()
    let session = session(fake)
    try await session.open()
    var events = session.closeEvents.makeAsyncIterator()

    fake.loseConnection(try #require(fake.openedConnection))

    #expect(await events.next() == .connectionLost)
    await session.close()
  }

  @Test("The plugin's error text reaches the user as plain text")
  func pluginErrorTextIsPlain() async throws {
    let fake = FakeEnginePlugin()
    let text = "Invalid object name 'dbo.missing'."
    fake.commandError = .init(code: .query, message: text, serverCode: "208")
    let session = session(fake)
    try await session.open()

    do {
      _ = try await session.command("DELETE FROM dbo.missing", binds: [])
      Issue.record("Expected the command to fail")
    } catch {
      #expect(session.formatError(error) == text)
    }
    await session.close()
  }

  @Test("A plugin error that echoes the password is surfaced with the password replaced")
  func pluginErrorHidesThePassword() async throws {
    let fake = FakeEnginePlugin()
    fake.commandError = .init(
      code: .query, message: "Login failed for 'S3cret-77', not 'S3cret-77'.", serverCode: "18456")
    let config = ConnectionConfig(
      host: "db.example.com", port: 1433, database: "app", username: "sa", password: "S3cret-77",
      sslMode: .disable, timeoutSeconds: 5)
    let session = session(fake, config: config)
    try await session.open()

    let error = await #expect(throws: EnginePluginError.self) {
      _ = try await session.command("SELECT 1", binds: [])
    }

    let shown = "Login failed for '••••', not '••••'."
    #expect(error == .server(.init(code: .query, message: shown, serverCode: "18456")))
    #expect(error?.errorDescription == shown)
    await session.close()
  }

  @Test("Dropping the rows early sends cancel for the query")
  func droppedRowsCancelTheQuery() async throws {
    let fake = FakeEnginePlugin()
    fake.batches = (0..<6).map { batch in (0..<2).map { [.int(batch * 2 + $0)] } }
    let session = session(fake)
    try await session.open()
    do {
      let source = try await session.query("SELECT n FROM t", binds: [])
      var rows = source.rows.makeAsyncIterator()
      #expect(try await rows.next() == [.int(0)])
    }
    let id = try queryID(fake)

    try await waitUntil { fake.requests.contains(where: isCancel(of: id)) }

    #expect(fake.requests.contains(where: isCancel(of: id)))
    await session.close()
  }

  @Test("A row whose width differs from the columns is refused and cancels the query")
  func rowWidthMismatchIsRefused() async throws {
    let fake = FakeEnginePlugin()
    fake.batches = [[[.int(1), .int(2)]], [[.int(3)]], [[.int(4)]]]
    let session = session(fake)
    try await session.open()
    let source = try await session.query("SELECT n FROM t", binds: [])
    var rows = source.rows.makeAsyncIterator()

    await #expect(throws: EnginePluginError.unreadableEvent) { _ = try await rows.next() }

    #expect(fake.requests.contains(where: isCancel(of: try queryID(fake))))
    await session.close()
  }

  @Test("Closing after a lost connection never waits for the plugin's answer")
  func closeAfterLossDoesNotWait() async throws {
    let fake = FakeEnginePlugin()
    fake.answersClose = false
    let session = session(fake)
    try await session.open()
    var events = session.closeEvents.makeAsyncIterator()
    fake.loseConnection(try #require(fake.openedConnection))
    #expect(await events.next() == .connectionLost)

    let elapsed = await ContinuousClock().measure { await session.close() }

    #expect(elapsed < .seconds(2))
    #expect(fake.count { $0 == .close } == 1)
  }

  @Test("A command answered with another kind of event is unreadable")
  func commandAnsweredWithAnotherKindIsUnreadable() async throws {
    let fake = FakeEnginePlugin()
    fake.commandAnswer = .settingsApplied
    let session = session(fake)
    try await session.open()

    await #expect(throws: EnginePluginError.unreadableEvent) {
      _ = try await session.command("DELETE FROM t", binds: [])
    }
    await session.close()
  }

  @Test("An over-cap event fails the request its id names; one with no readable id is dropped")
  func overCapEventFailsItsRequest() async throws {
    let fake = FakeEnginePlugin()
    fake.batches = (0..<4).map { [[.int($0)]] }
    let session = session(fake)
    try await session.open()
    let connection = try #require(fake.openedConnection)
    let filler = String(repeating: "a", count: EnginePluginProtocol.maxEventBytes)
    let source = try await session.query("SELECT n FROM t", binds: [])
    let id = try queryID(fake)
    // Sorted keys, as the codec writes them: `connection`, `event`, `id`, then `rows`
    fake.emitRaw(
      #"{"connection":\#(connection),"event":"rows","id":"\#(id)","rows":[[{"s":"\#(filler)"}]]}"#
    )
    var rows = source.rows.makeAsyncIterator()

    await #expect(throws: EnginePluginError.eventTooLarge) {
      while try await rows.next() != nil {}
    }

    fake.emitRaw(#"{"connection":\#(connection),"event":"rows","rows":[[{"s":"\#(filler)"}]]}"#)
    #expect(try await session.command("commit", binds: []).tag == "COMMIT")
    await session.close()
  }

  @Test("argv is refused without sending when the plugin's hello lacks the argv feature")
  func argvRefusedWithoutFeature() async throws {
    let fake = FakeEnginePlugin()
    let session = session(fake)
    try await session.open()

    let error = await #expect(throws: EnginePluginSessionError.self) {
      _ = try await session.sendArgv([Data("GET".utf8), Data("k".utf8)], db: 0)
    }

    guard case .unsupported = error else {
      Issue.record("Expected unsupported, got \(String(describing: error))")
      return
    }
    #expect(fake.count { if case .argv = $0 { true } else { false } } == 0)
    await session.close()
  }

  @Test("argv streams its reply as rows, with byte cells byte-exact")
  func argvReturnsByteCells() async throws {
    let fake = FakeEnginePlugin()
    fake.features = ["argv"]
    let bytes = Data([0xff, 0x00, 0x0d, 0x0a])
    fake.columns = [.init(name: "value", type: "bulk")]
    fake.batches = [[[.bytes(bytes)]]]
    let session = session(fake)
    try await session.open()
    let args = [Data("GET".utf8), Data([0xfe, 0x01])]

    let source = try await session.sendArgv(args, db: 3)
    var rows: [[CellValue]] = []
    for try await row in source.rows { rows.append(row) }

    #expect(source.columns.map(\.name) == ["value"])
    #expect(rows == [[.data(bytes)]])
    let sent = fake.requests.lazy.compactMap { request -> EngineRequest.Argv? in
      if case .argv(let argv) = request.kind { argv } else { nil }
    }.first
    #expect(sent == .init(args: args, db: 3, batchRows: EnginePluginSession.batchRows))
    await session.close()
  }

  @Test("A COMMIT whose done has no tag returns the COMMIT tag")
  func emptyTagFilledFromStatement() async throws {
    let fake = FakeEnginePlugin()
    let session = session(fake)
    try await session.open()

    let result = try await session.command("commit", binds: [])

    #expect(result.tag == "COMMIT")
    await session.close()
  }
}
