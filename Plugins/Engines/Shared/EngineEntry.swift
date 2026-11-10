// EngineEntry.swift
// Entry points shared by every database engine bundle. Dblore loads the bundle into its own
// process and calls the two C functions below (plain C types only): one engine protocol v1
// request JSON object in, event JSON objects out through a callback. The types and codec are the
// app's EnginePluginProtocol.swift, compiled into the bundle by path. Each engine target adds its
// driver: a global `engineDriver` conforming to `EngineDriver`.
//
// Dispatch: each connection has its own serial queue, so db-lib style clients that are not thread
// safe per connection see one request at a time. `more` and `cancel` never wait on that queue:
// they are served on the caller's thread under one lock, so a cancel reaches a statement that
// blocks its queue, and a query waiting for credit wakes up.

import Foundation

/// Protocol version of the request and event objects
@_cdecl("dblore_engine_protocol")
public func dbloreEngineProtocol() -> Int32 { Int32(EnginePluginProtocol.version) }

/// Answers the request JSON object `json` (UTF-8, NUL-terminated) by calling `emit` with
/// `context` and one event JSON object (UTF-8, NUL-terminated) per call, echoing the request `id`.
/// `hello`, `close` of an unknown connection, unsupported kinds and unreadable requests are
/// answered before this returns; everything else later, from a connection queue, so `emit` and
/// `context` must stay valid for the life of the process. `more` and `cancel` get no answer of
/// their own (the cancelled request ends with `cancelled`). The string passed to `emit` is valid
/// only during that call. Never blocks on the network.
@_cdecl("dblore_engine_request")
public func dbloreEngineRequest(
  _ json: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?,
  _ emit: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
) {
  EngineRequestDispatcher.shared.receive(
    Data(bytes: json, count: strlen(json)), sink: EventSink(context: context, emit: emit))
}

// MARK: - Driver contract

/// One database engine. Each bundle defines exactly one, as the global `engineDriver`.
protocol EngineDriver: Sendable {
  /// `sqlserver`, `clickhouse`
  var engine: String { get }
  /// `sql`, or the engine's own query language
  var queryLanguage: String { get }
  /// Bundled client libraries and their versions, for `hello`
  var libraries: [String: String] { get }
  /// Opens a connection, on the connection's serial queue. Throws `EngineFailure`.
  func connect(_ open: EngineRequest.Open) throws -> any EngineConnection
}

/// One open connection. Every member runs on the connection's serial queue, except `interrupt`.
protocol EngineConnection: AnyObject, Sendable {
  /// The `opened` event's text
  var serverVersion: String { get }
  /// Any thread, only while a statement of this connection runs: asks it to stop soon. The
  /// statement then fails or ends early; the dispatcher answers `cancelled`.
  func interrupt()
  /// Before each statement: forgets an earlier interrupt
  func resetInterrupt()
  /// Sends the statement and waits for its first result. Throws `EngineFailure`.
  func execute(_ sql: String) throws
  /// The next result's columns (empty when it returns no rows), nil when none is left
  func nextResult() throws -> [EngineEvent.Column]?
  /// The next row of the current result, nil at its end
  func nextRow() throws -> [EngineCell]?
  /// Rows the current result affected, nil when the server did not say
  var affectedRows: Int? { get }
  /// Drops what is left of the statement (after a cancel, a failure or an early stop)
  func discardResults()
  /// Whether the server connection is gone
  var isLost: Bool { get }
  /// Closes the connection; nothing else is called afterwards
  func close()
}

/// A failure answered with an `error` event. `message` is plain text and never holds the password.
struct EngineFailure: Error, Sendable {
  let code: EngineErrorCode
  let message: String
  var serverCode: String? = nil

  static func from(_ error: any Error, code: EngineErrorCode) -> EngineFailure {
    error as? EngineFailure ?? EngineFailure(code: code, message: String(describing: error))
  }
}

// MARK: - Events out

/// The caller's callback and context, captured per request so a queue can answer later. The
/// caller keeps `context` alive and accepts calls from any thread (see `dbloreEngineRequest`).
struct EventSink: @unchecked Sendable {
  let context: UnsafeMutableRawPointer?
  let emit: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

  /// Sends `event`. One that cannot be encoded (over the 1 MiB event limit) is never sent: an
  /// `error` for its request goes instead, and the result is false, so the request must stop.
  @discardableResult func send(_ event: EngineEvent) -> Bool {
    do {
      write(try EnginePluginProtocol.encodeEvent(event))
      return true
    } catch {
      let tooLarge = (error as? EngineProtocolError) == .tooLarge
      let failure = EngineEvent.Failure(
        code: tooLarge ? .tooLarge : .invalid,
        message: tooLarge
          ? "The answer is over the 1 MiB event limit." : "The answer could not be encoded.")
      if let data = try? EnginePluginProtocol.encodeEvent(
        EngineEvent(id: event.id, connection: event.connection, kind: .error(failure)))
      {
        write(data)
      }
      return false
    }
  }

  func send(_ kind: EngineEvent.Kind, id: String?) {
    send(EngineEvent(id: id, kind: kind))
  }

  func fail(_ failure: EngineFailure, id: String?) {
    send(
      .error(.init(code: failure.code, message: failure.message, serverCode: failure.serverCode)),
      id: id)
  }

  private func write(_ data: Data) {
    // Encoded JSON escapes every control character, so it holds no NUL
    String(decoding: data, as: UTF8.self).withCString { emit(context, $0) }
  }
}

// MARK: - Dispatch

/// One connection: its queue and, once open, its driver connection
final class ConnectionSlot: @unchecked Sendable {
  let id: Int
  let queue: DispatchQueue
  /// Guarded by the dispatcher's lock; used only on `queue` (and `interrupt` anywhere)
  var connection: (any EngineConnection)?
  /// The request running on `queue`, guarded by the dispatcher's lock
  var current: RequestControl?

  init(id: Int) {
    self.id = id
    queue = DispatchQueue(label: "ace.thi.Dblore.engine.connection.\(id)")
  }
}

/// The credit and cancel state of one request, shared by its queue and `more` / `cancel`
final class RequestControl: @unchecked Sendable {
  let id: String
  let slot: ConnectionSlot
  private let condition = NSCondition()
  private var credit = 0
  private var cancelled = false

  init(id: String, slot: ConnectionSlot) {
    self.id = id
    self.slot = slot
  }

  var isCancelled: Bool { condition.withLock { cancelled } }

  /// Credit for `count` more `rows` events
  func grant(_ count: Int = 1) {
    condition.withLock {
      credit += count
      condition.broadcast()
    }
  }

  func markCancelled() {
    condition.withLock {
      cancelled = true
      condition.broadcast()
    }
  }

  /// Takes one credit, waiting for it; false once the request is cancelled
  func takeCredit() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    while credit == 0 && !cancelled { condition.wait() }
    guard !cancelled else { return false }
    credit -= 1
    return true
  }
}

/// Routes requests to connection queues and serves `more` and `cancel` by `target` alone.
final class EngineRequestDispatcher: @unchecked Sendable {
  static let shared = EngineRequestDispatcher(driver: engineDriver)

  private let driver: any EngineDriver
  private let lock = NSLock()
  /// Open (or opening) connections by the app's connection id, guarded by `lock`
  private var slots: [Int: ConnectionSlot] = [:]
  /// Requests that may still get `more` or `cancel`, by id, guarded by `lock`
  private var running: [String: RequestControl] = [:]

  init(driver: any EngineDriver) {
    self.driver = driver
  }

  func receive(_ data: Data, sink: EventSink) {
    let request: EngineRequest
    do {
      request = try EnginePluginProtocol.decodeRequest(data)
    } catch {
      var id: String?
      if case .invalid(let requestID)? = error as? EngineProtocolError { id = requestID }
      sink.fail(.init(code: .invalid, message: "The request could not be read."), id: id)
      return
    }
    switch request.kind {
    case .hello: sink.send(.hello(hello()), id: request.id)
    case .open(let open): self.open(open, request: request, sink: sink)
    case .close: close(request, sink: sink)
    case .query(let query):
      enqueue(request, sink: sink) { connection, control in
        self.run(query.sql, binds: query.binds, query: query, on: connection, control, sink)
      }
    case .command(let command):
      enqueue(request, sink: sink) { connection, control in
        self.run(command.sql, binds: command.binds, query: nil, on: connection, control, sink)
      }
    case .more(let target): lock.withLock { running[target] }?.grant()
    case .cancel(let target): cancel(target)
    case .settings, .transactionState, .catalog, .unknown:
      sink.fail(
        .init(code: .unsupported, message: "This request is not supported by this plugin."),
        id: request.id)
    }
  }

  private func hello() -> EngineEvent.Hello {
    let version =
      Bundle(for: EngineBundleToken.self).object(
        forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return EngineEvent.Hello(
      protocolVersion: EnginePluginProtocol.version, version: version ?? "unknown",
      engine: driver.engine, queryLanguage: driver.queryLanguage, libraries: driver.libraries,
      features: [])
  }

  // MARK: Connections

  private func open(_ open: EngineRequest.Open, request: EngineRequest, sink: EventSink) {
    let control: RequestControl? = lock.withLock {
      guard let id = request.connection, slots[id] == nil else { return nil }
      let slot = ConnectionSlot(id: id)
      slots[id] = slot
      let control = RequestControl(id: request.id, slot: slot)
      running[request.id] = control
      return control
    }
    guard let control else {
      let message =
        request.connection == nil
        ? "The open request has no connection id." : "This connection is already open."
      return sink.fail(.init(code: .invalid, message: message), id: request.id)
    }
    let slot = control.slot
    slot.queue.async { [self, driver] in
      defer { finish(control) }
      let connection: any EngineConnection
      do {
        connection = try driver.connect(open)
      } catch {
        lock.withLock { if slots[slot.id] === slot { slots[slot.id] = nil } }
        if control.isCancelled { return sink.send(.cancelled, id: request.id) }
        return sink.fail(.from(error, code: .connect), id: request.id)
      }
      // A cancel or close during the open wins: the new connection goes away again
      let kept = lock.withLock {
        guard !control.isCancelled, slots[slot.id] === slot else {
          if slots[slot.id] === slot { slots[slot.id] = nil }
          return false
        }
        slot.connection = connection
        return true
      }
      guard kept else {
        connection.close()
        return sink.send(.cancelled, id: request.id)
      }
      sink.send(.opened(serverVersion: connection.serverVersion), id: request.id)
    }
  }

  /// Always answered with `closed`, also for an unknown or lost connection. Requests of the
  /// connection are cancelled first, so one waiting for credit or blocking on the server ends.
  private func close(_ request: EngineRequest, sink: EventSink) {
    let answer = EngineEvent(
      id: request.id, connection: request.connection, kind: .closed(reason: .closed))
    let slot: ConnectionSlot? = lock.withLock {
      guard let id = request.connection, let slot = slots.removeValue(forKey: id) else {
        return nil
      }
      for control in running.values where control.slot === slot {
        cancelLocked(control)
      }
      return slot
    }
    guard let slot else {
      sink.send(answer)
      return
    }
    slot.queue.async { [self] in
      let connection = lock.withLock {
        defer { slot.connection = nil }
        return slot.connection
      }
      connection?.close()
      sink.send(answer)
    }
  }

  /// The server went away: the connection closes and the app gets an unsolicited `closed`
  private func lose(_ slot: ConnectionSlot, sink: EventSink) {
    let connection = lock.withLock {
      if slots[slot.id] === slot { slots[slot.id] = nil }
      for control in running.values where control.slot === slot { control.markCancelled() }
      defer { slot.connection = nil }
      return slot.connection
    }
    connection?.close()
    sink.send(EngineEvent(connection: slot.id, kind: .closed(reason: .lost)))
  }

  // MARK: Requests

  private func cancel(_ target: String) {
    lock.withLock {
      guard let control = running[target] else { return }
      cancelLocked(control)
    }
  }

  private func cancelLocked(_ control: RequestControl) {
    control.markCancelled()
    if control.slot.current === control { control.slot.connection?.interrupt() }
  }

  /// Runs `body` on the connection's queue once the requests before it are done
  private func enqueue(
    _ request: EngineRequest, sink: EventSink,
    body: @escaping @Sendable (any EngineConnection, RequestControl) -> Void
  ) {
    let control: RequestControl? = lock.withLock {
      guard let id = request.connection, let slot = slots[id] else { return nil }
      let control = RequestControl(id: request.id, slot: slot)
      running[request.id] = control
      return control
    }
    guard let control else {
      return sink.fail(
        .init(code: .invalid, message: "The connection is not open."), id: request.id)
    }
    control.slot.queue.async { [self] in
      defer { finish(control) }
      let connection: (any EngineConnection)? = lock.withLock {
        guard let connection = control.slot.connection else { return nil }
        connection.resetInterrupt()
        control.slot.current = control
        return connection
      }
      guard let connection else {
        return sink.fail(
          .init(code: .invalid, message: "The connection is not open."), id: request.id)
      }
      guard !control.isCancelled else { return sink.send(.cancelled, id: request.id) }
      body(connection, control)
    }
  }

  private func finish(_ control: RequestControl) {
    lock.withLock {
      running[control.id] = nil
      if control.slot.current === control { control.slot.current = nil }
    }
  }

  /// A `query` (columns, rows on credit, chunks, then done) or, with `query` nil, a `command`
  /// (done with the affected rows). Only the first result set with columns is streamed; later
  /// ones are read and dropped, since a query has one `columns` event.
  private func run(
    _ sql: String, binds: [String?], query: EngineRequest.Query?,
    on connection: any EngineConnection,
    _ control: RequestControl, _ sink: EventSink
  ) {
    let id = control.id
    guard binds.isEmpty else {
      return sink.fail(
        .init(code: .unsupported, message: "Statement parameters are not supported yet."), id: id)
    }
    do {
      try connection.execute(sql)
      var affectedRows: Int?
      var streamed = false
      while !control.isCancelled, let columns = try connection.nextResult() {
        if let query, !streamed, !columns.isEmpty {
          streamed = true
          guard sink.send(EngineEvent(id: id, kind: .columns(columns))) else {
            return connection.discardResults()
          }
          control.grant(2)  // at most 2 rows events ahead of `more`
          var streamer = RowStreamer(query: query, control: control, sink: sink)
          while !control.isCancelled, let row = try connection.nextRow() {
            guard streamer.add(row) else { break }
          }
          if !streamer.failed, !control.isCancelled { _ = streamer.flush() }
          if streamer.failed { return connection.discardResults() }
        } else {
          while !control.isCancelled, try connection.nextRow() != nil {}
        }
        affectedRows = connection.affectedRows ?? affectedRows
      }
      guard !control.isCancelled else {
        connection.discardResults()
        return sink.send(.cancelled, id: id)
      }
      sink.send(.done(affectedRows: affectedRows, tag: ""), id: id)
    } catch {
      if connection.isLost {
        if control.isCancelled {
          sink.send(.cancelled, id: id)
        } else {
          sink.fail(.from(error, code: .query), id: id)
        }
        return lose(control.slot, sink: sink)
      }
      connection.discardResults()
      // An interrupted statement fails; the cancel is the answer
      guard !control.isCancelled else { return sink.send(.cancelled, id: id) }
      sink.fail(.from(error, code: .query), id: id)
    }
  }
}

/// Marks this bundle's image for `Bundle(for:)`
private final class EngineBundleToken {}

// MARK: - Rows

/// Batches a query's rows into `rows` events of about `rowsEventTargetBytes`, each sent on
/// credit. A row over that budget sends its biggest text cells as `chunk` events (pieces of at
/// most `chunkPieceBytes`, each valid UTF-8) and `{c: true}` in the row, with at most one chunked
/// value per column per `rows` event. Sizes are upper bounds of the encoded JSON (escapes
/// included), so no event passes `maxEventBytes`.
struct RowStreamer {
  /// Raw bytes per chunk piece: escaped, even all control characters stay under 1 MiB
  static let chunkPieceBytes = 128 << 10
  /// A cell smaller than this is never chunked
  static let minimumChunkedCost = 1 << 10
  static let chunkedCellCost = 12

  let id: String
  let batchRows: Int
  let maxCellBytes: Int?
  let control: RequestControl
  let sink: EventSink
  private var rows: [[EngineCell]] = []
  private var cost = 0
  private var chunkedColumns: Set<Int> = []
  /// An event could not be sent (its `error` went instead): the query must stop
  private(set) var failed = false

  init(query: EngineRequest.Query, control: RequestControl, sink: EventSink) {
    id = control.id
    batchRows = max(1, query.batchRows)
    maxCellBytes = query.maxCellBytes
    self.control = control
    self.sink = sink
  }

  /// Adds one row; false once the query must stop (cancelled, or failed)
  mutating func add(_ row: [EngineCell]) -> Bool {
    var cells = row.map(cut)
    var costs = cells.map(Self.cost)
    var chunked: [Int] = []
    let budget = EnginePluginProtocol.rowsEventTargetBytes
    while costs.reduce(0, +) + cells.count + 2 > budget,
      let column = costs.indices.filter({ cells[$0].isText && !chunked.contains($0) })
        .max(by: { costs[$0] < costs[$1] }),
      costs[column] >= Self.minimumChunkedCost
    {
      chunked.append(column)
      costs[column] = Self.chunkedCellCost
    }
    let rowCost = costs.reduce(0, +) + cells.count + 2
    if !rows.isEmpty,
      rows.count >= batchRows || cost + rowCost > budget
        || !chunkedColumns.isDisjoint(with: chunked)
    {
      guard flush() else { return false }
    }
    for column in chunked {
      guard case .text(let text) = cells[column], sendChunks(of: text, column: column) else {
        return false
      }
      cells[column] = .chunked
      chunkedColumns.insert(column)
    }
    rows.append(cells)
    cost += rowCost
    return true
  }

  /// Sends the pending rows once credit allows; false once cancelled or failed
  mutating func flush() -> Bool {
    guard !rows.isEmpty else { return true }
    guard control.takeCredit() else { return false }
    guard sink.send(EngineEvent(id: id, kind: .rows(rows))) else {
      failed = true
      return false
    }
    rows.removeAll(keepingCapacity: true)
    cost = 0
    chunkedColumns.removeAll()
    return true
  }

  private mutating func sendChunks(of text: String, column: Int) -> Bool {
    let bytes = Array(text.utf8)
    var start = 0
    while start < bytes.count {
      guard !control.isCancelled else { return false }
      var end = min(start + Self.chunkPieceBytes, bytes.count)
      while end < bytes.count && bytes[end] & 0xC0 == 0x80 { end -= 1 }  // whole scalars only
      let piece = String(decoding: bytes[start..<end], as: UTF8.self)
      let chunk = EngineEvent.Chunk(column: column, data: .text(piece), last: end == bytes.count)
      guard sink.send(EngineEvent(id: id, kind: .chunk(chunk))) else {
        failed = true
        return false
      }
      start = end
    }
    return true
  }

  /// A text cell cut to `maxCellBytes`, on a scalar boundary
  private func cut(_ cell: EngineCell) -> EngineCell {
    guard let maxCellBytes, case .text(let text) = cell, text.utf8.count > maxCellBytes else {
      return cell
    }
    let bytes = Array(text.utf8)
    var end = max(0, maxCellBytes)
    while end > 0 && bytes[end] & 0xC0 == 0x80 { end -= 1 }
    return .text(String(decoding: bytes[..<end], as: UTF8.self))
  }

  /// An upper bound of the cell's encoded size
  static func cost(_ cell: EngineCell) -> Int {
    switch cell {
    case .text(let text), .json(let text), .decimal(let text), .date(let text):
      var escaped = 8
      for byte in text.utf8 {
        escaped += byte < 0x20 ? 6 : (byte == 0x22 || byte == 0x5C) ? 2 : 1
      }
      return escaped
    case .bytes(let data): return (data.count + 2) / 3 * 4 + 8
    default: return 32
    }
  }
}

extension EngineCell {
  fileprivate var isText: Bool {
    if case .text = self { true } else { false }
  }
}
