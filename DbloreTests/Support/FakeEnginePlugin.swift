// FakeEnginePlugin.swift
// An in-process engine plugin for tests: the engine side of protocol v1 written with the codec,
// behind a fake `EngineEntryPoint`. Scriptable per test (handshake versions, open, query batches,
// command answers) and emitting from its own serial queue, as a bundle emits from its connection
// queue. It honors the rows credit (2 events ahead of `more`), answers `cancel` with
// `cancelled`, and answers each catalog read as scripted.

import Foundation

@testable import Dblore

final class FakeEnginePlugin: @unchecked Sendable {
  /// What `dblore_engine_protocol()` returns
  var entryProtocol: Int32 = 1
  /// Columns and rows events of every query
  var columns: [EngineEvent.Column] = [.init(name: "n", type: "int")]
  var batches: [[[EngineCell]]] = []
  /// The `done` of a command; `commandError` answers it instead when set
  var commandAffectedRows: Int? = 0
  var commandTag = ""
  var commandError: EngineEvent.Failure?
  /// Answers a command in place of `done` or `commandError` when set
  var commandAnswer: EngineEvent.Kind?
  /// False leaves `open` unanswered, as a server that never answers the dial
  var answersOpen = true
  /// False leaves `close` unanswered, as a plugin that hangs
  var answersClose = true
  /// What `transactionState` answers (`@@TRANCOUNT > 0`); nil answers it with an error
  var transactionOpen: Bool? = false
  /// The answer to a `catalog` request, by its read; any other read is answered `unsupported`
  var catalogAnswers: [EngineCatalogRead: EngineEvent.Kind] = [:]

  private let queue = DispatchQueue(label: "FakeEnginePlugin.emit")
  private let lock = NSLock()
  private var received: [EngineRequest] = []
  private var rowsEventsSentStorage = 0
  private var query: RunningQuery?

  private struct RunningQuery {
    let id: String
    let connection: Int?
    var remaining: [[[EngineCell]]]
    var credit = 2
  }

  /// `emit` and its context, to call from the queue
  private struct Sink: @unchecked Sendable {
    let context: UnsafeMutableRawPointer?
    let emit: EngineEntryPoint.Emit

    func send(_ event: EngineEvent) {
      guard let data = try? EnginePluginProtocol.encodeEvent(event) else { return }
      send(String(decoding: data, as: UTF8.self))
    }

    func send(_ line: String) {
      line.withCString { emit(context, $0) }
    }
  }

  /// Every request received, in order
  var requests: [EngineRequest] { lock.withLock { received } }
  var rowsEventsSent: Int { lock.withLock { rowsEventsSentStorage } }

  func count(_ matches: (EngineRequest.Kind) -> Bool) -> Int {
    requests.filter { matches($0.kind) }.count
  }

  /// The connection id the app gave in its `open`
  var openedConnection: Int? {
    requests.first { if case .open = $0.kind { true } else { false } }?.connection
  }

  /// A runtime for a fresh plugin id with this fake behind it, installed for the session
  func install() -> String {
    let pluginID = "fake-engine-\(UUID().uuidString)"
    let entry = entryPoint
    EnginePluginRuntime.install(EnginePluginRuntime(pluginID: pluginID, loader: { entry }))
    return pluginID
  }

  /// Holds the fake strongly: the installed runtime lives for the process and may still send
  /// a late `cancel` after the test ended.
  var entryPoint: EngineEntryPoint {
    EngineEntryPoint(
      protocolVersion: { self.entryProtocol },
      send: { json, context, emit in
        self.receive(json, sink: Sink(context: context, emit: emit))
      })
  }

  /// An unsolicited `closed(lost)` of `connection`, as when the server goes away
  func loseConnection(_ connection: Int) {
    guard let sink = lock.withLock({ lastSink }) else { return }
    queue.async { sink.send(EngineEvent(connection: connection, kind: .closed(reason: .lost))) }
  }

  /// `line` emitted as is, unchecked (an over-cap or malformed event), after what is queued
  func emitRaw(_ line: String) {
    guard let sink = lock.withLock({ lastSink }) else { return }
    queue.async { sink.send(line) }
  }

  private var lastSink: Sink?

  private func receive(_ json: String, sink: Sink) {
    guard let request = try? EnginePluginProtocol.decodeRequest(Data(json.utf8)) else { return }
    lock.withLock {
      received.append(request)
      lastSink = sink
    }
    let id = request.id
    let connection = request.connection
    func answer(_ kind: EngineEvent.Kind) {
      queue.async { sink.send(EngineEvent(id: id, connection: connection, kind: kind)) }
    }
    switch request.kind {
    case .hello:
      answer(
        .hello(
          .init(
            protocolVersion: Int(entryProtocol), version: "1.0.0", engine: "fake",
            queryLanguage: "sql")))
    case .open: if answersOpen { answer(.opened(serverVersion: "fake 1")) }
    case .close: if answersClose { answer(.closed(reason: .closed)) }
    case .query:
      lock.withLock { query = RunningQuery(id: id, connection: connection, remaining: batches) }
      answer(.columns(columns))
      pump(sink)
    case .more(let target):
      lock.withLock { if query?.id == target { query?.credit += 1 } }
      pump(sink)
    case .cancel(let target):
      let cancelled = lock.withLock {
        defer { if query?.id == target { query = nil } }
        return query?.id == target ? query : nil
      }
      if let cancelled {
        queue.async {
          sink.send(
            EngineEvent(id: cancelled.id, connection: cancelled.connection, kind: .cancelled))
        }
      }
    case .command:
      if let commandAnswer {
        answer(commandAnswer)
      } else if let commandError {
        answer(.error(commandError))
      } else {
        answer(.done(affectedRows: commandAffectedRows, tag: commandTag))
      }
    case .settings: answer(.settingsApplied)
    case .transactionState:
      if let open = transactionOpen {
        answer(.transactionState(open: open))
      } else {
        answer(.error(.init(code: .unsupported, message: "unsupported")))
      }
    case .catalog(let catalog):
      answer(
        catalogAnswers[catalog.read] ?? .error(.init(code: .unsupported, message: "unsupported")))
    case .unknown:
      answer(.error(.init(code: .unsupported, message: "unsupported")))
    }
  }

  /// Sends the rows events the credit allows, then `done` once every batch is out
  private func pump(_ sink: Sink) {
    var events: [EngineEvent] = []
    lock.withLock {
      guard var running = query else { return }
      while running.credit > 0, !running.remaining.isEmpty {
        running.credit -= 1
        rowsEventsSentStorage += 1
        events.append(
          EngineEvent(
            id: running.id, connection: running.connection,
            kind: .rows(running.remaining.removeFirst())))
      }
      if running.remaining.isEmpty {
        events.append(
          EngineEvent(
            id: running.id, connection: running.connection,
            kind: .done(affectedRows: nil, tag: "SELECT")))
        query = nil
      } else {
        query = running
      }
    }
    let ready = events
    queue.async { ready.forEach(sink.send) }
  }
}
