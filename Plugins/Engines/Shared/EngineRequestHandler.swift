// EngineRequestHandler.swift
// The request handler shared by every database engine bundle: one engine protocol v1 request in,
// event JSON objects out through an `EventSink`. EngineEntry.swift feeds it from the C entry
// point; tests feed it directly with a driver of their own and a closure sink.
//
// Dispatch: each connection has its own serial queue, so db-lib style clients that are not thread
// safe per connection see one request at a time. `more` and `cancel` never wait on that queue:
// they are served on the caller's thread under one lock, so a cancel reaches a statement that
// blocks its queue, and a query waiting for credit wakes up.
//
// Flow control: after `columns` a query may send 2 `rows` events; each `more` allows one more.
// A row whose cells pass the event budget sends its biggest cells as `chunk` events first, and
// those go only once the credit for their `rows` event is in hand.

import Foundation

// MARK: - Driver contract

/// One database engine. Each bundle defines exactly one, as the global `engineDriver`.
protocol EngineDriver: Sendable {
  /// `sqlserver`, `clickhouse`
  var engine: String { get }
  /// `sql`, or the engine's own query language
  var queryLanguage: String { get }
  /// Bundled client libraries and their versions, for `hello`
  var libraries: [String: String] { get }
  /// Request kinds beyond the base set this bundle serves (`argv`), for `hello`. Default none.
  var features: [String] { get }
  /// Opens a connection, on the connection's serial queue. Throws `EngineFailure`.
  func connect(_ open: EngineRequest.Open) throws -> any EngineConnection
}

extension EngineDriver {
  var features: [String] { [] }
}

/// One open connection. Every member runs on the connection's serial queue, except `interrupt`.
protocol EngineConnection: AnyObject, Sendable {
  /// The `opened` event's text
  var serverVersion: String { get }
  /// Any thread, only while a statement of this connection runs: asks it to stop soon. The
  /// statement then fails or ends early; the handler answers `cancelled`.
  func interrupt()
  /// Before each statement: forgets an earlier interrupt
  func resetInterrupt()
  /// Sends the statement and waits for its first result. Throws `EngineFailure`.
  func execute(_ sql: String) throws
  /// `execute` with parameters: `binds[i]` is parameter i + 1 in the engine's own placeholder
  /// syntax, nil is NULL. The default refuses any bind (`unsupported`).
  func execute(_ sql: String, binds: [String?]) throws
  /// The `argv` request: sends one command as its raw arguments (command name first) in database
  /// `db` and waits for its first result, read like `execute`'s. The default answers
  /// `unsupported`.
  func execute(argv args: [Data], db: Int) throws
  /// The next result's columns (empty when it returns no rows), nil when none is left
  func nextResult() throws -> [EngineEvent.Column]?
  /// The next row of the current result, nil at its end
  func nextRow() throws -> [EngineCell]?
  /// Rows the current result affected, nil when the server did not say
  var affectedRows: Int? { get }
  /// Drops what is left of the statement (after a cancel, a failure or an early stop)
  func discardResults()
  /// The `settings` request (session brakes). The default answers `unsupported`.
  func apply(_ settings: EngineRequest.Settings) throws
  /// One `catalog` read. The default answers `unsupported`.
  func catalog(_ request: EngineRequest.Catalog) throws -> EngineCatalogResult
  /// The `transactionState` request: whether a transaction is open, nil when unknown. The
  /// default answers `unsupported`.
  func transactionOpen() throws -> Bool?
  /// Whether the server connection is gone
  var isLost: Bool { get }
  /// Closes the connection; nothing else is called afterwards
  func close()
}

extension EngineConnection {
  func execute(_ sql: String, binds: [String?]) throws {
    guard binds.isEmpty else {
      throw EngineFailure(
        code: .unsupported, message: "Statement parameters are not supported yet.")
    }
    try execute(sql)
  }

  func execute(argv args: [Data], db: Int) throws {
    throw EngineFailure(
      code: .unsupported, message: "This request is not supported by this plugin.")
  }

  func apply(_ settings: EngineRequest.Settings) throws {
    throw EngineFailure(
      code: .unsupported, message: "Session settings are not supported by this plugin.")
  }

  func catalog(_ request: EngineRequest.Catalog) throws -> EngineCatalogResult {
    throw EngineFailure(
      code: .unsupported, message: "This catalog read is not supported by this plugin.")
  }

  func transactionOpen() throws -> Bool? {
    throw EngineFailure(
      code: .unsupported, message: "This request is not supported by this plugin.")
  }
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

/// Where events go: `write` gets one encoded event (UTF-8 JSON) per call, from any thread.
struct EventSink: Sendable {
  let write: @Sendable (Data) -> Void

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
}

// MARK: - Dispatch

/// One connection: its queue and, once open, its driver connection
final class ConnectionSlot: @unchecked Sendable {
  let id: Int
  let queue: DispatchQueue
  /// Guarded by the handler's lock; used only on `queue` (and `interrupt` anywhere)
  var connection: (any EngineConnection)?
  /// The request running on `queue`, guarded by the handler's lock
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
final class EngineRequestHandler: @unchecked Sendable {
  /// `rows` events a query may send before its first `more`
  static let initialCredit = 2

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
        self.run(rows: (query.batchRows, query.maxCellBytes), on: connection, control, sink) {
          try connection.execute(query.sql, binds: query.binds)
        }
      }
    case .command(let command):
      enqueue(request, sink: sink) { connection, control in
        self.run(rows: nil, on: connection, control, sink) {
          try connection.execute(command.sql, binds: command.binds)
        }
      }
    case .argv(let argv):
      let rows = (argv.batchRows ?? RowStreamer.defaultBatchRows, argv.maxCellBytes)
      enqueue(request, sink: sink) { connection, control in
        self.run(rows: rows, on: connection, control, sink) {
          try connection.execute(argv: argv.args, db: argv.db)
        }
      }
    case .settings(let settings):
      enqueue(request, sink: sink) { connection, control in
        self.answer(on: connection, control, sink) {
          try connection.apply(settings)
          return .settingsApplied
        }
      }
    case .catalog(let catalog):
      enqueue(request, sink: sink) { connection, control in
        self.answer(on: connection, control, sink) { .catalog(try connection.catalog(catalog)) }
      }
    case .transactionState:
      enqueue(request, sink: sink) { connection, control in
        self.answer(on: connection, control, sink) {
          .transactionState(open: try connection.transactionOpen())
        }
      }
    case .more(let target): lock.withLock { running[target] }?.grant()
    case .cancel(let target): cancel(target)
    case .unknown:
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
      features: driver.features)
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

  /// Routed by `target` alone: the request is marked cancelled (a queued one answers
  /// `cancelled` when its turn comes, one waiting for credit wakes up) and, when it is the
  /// statement running on its connection, the connection is interrupted.
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

  /// A request answered by one event (`settings`, `catalog`, `transactionState`)
  private func answer(
    on connection: any EngineConnection, _ control: RequestControl, _ sink: EventSink,
    _ body: () throws -> EngineEvent.Kind
  ) {
    do {
      let kind = try body()
      guard !control.isCancelled else { return sink.send(.cancelled, id: control.id) }
      sink.send(EngineEvent(id: control.id, kind: kind))
    } catch {
      failed(error, on: connection, control, sink)
    }
  }

  /// A `query` or `argv` (columns, rows on credit, chunks, then done) or, with `rows` nil, a
  /// `command` (done with the affected rows); `execute` starts the statement. Only the first
  /// result set with columns is streamed; later ones are read and dropped, since a query has one
  /// `columns` event.
  private func run(
    rows: (batchRows: Int, maxCellBytes: Int?)?, on connection: any EngineConnection,
    _ control: RequestControl, _ sink: EventSink, execute: () throws -> Void
  ) {
    let id = control.id
    do {
      try execute()
      var affectedRows: Int?
      var streamed = false
      while !control.isCancelled, let columns = try connection.nextResult() {
        if let rows, !streamed, !columns.isEmpty {
          streamed = true
          guard sink.send(EngineEvent(id: id, kind: .columns(columns))) else {
            return connection.discardResults()
          }
          control.grant(Self.initialCredit)
          var streamer = RowStreamer(
            batchRows: rows.batchRows, maxCellBytes: rows.maxCellBytes, control: control,
            sink: sink)
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
        sink.send(.cancelled, id: id)
        if connection.isLost { lose(control.slot, sink: sink) }
        return
      }
      sink.send(.done(affectedRows: affectedRows, tag: ""), id: id)
    } catch {
      failed(error, on: connection, control, sink)
    }
  }

  /// Answers a failed request: `cancelled` when it was cancelled (an interrupted statement
  /// fails), else its `error`; a lost connection (also one lost while its results drain) closes
  private func failed(
    _ error: any Error, on connection: any EngineConnection, _ control: RequestControl,
    _ sink: EventSink
  ) {
    let id = control.id
    if connection.isLost {
      if control.isCancelled {
        sink.send(.cancelled, id: id)
      } else {
        sink.fail(.from(error, code: .query), id: id)
      }
      return lose(control.slot, sink: sink)
    }
    connection.discardResults()
    if control.isCancelled {
      sink.send(.cancelled, id: id)
    } else {
      sink.fail(.from(error, code: .query), id: id)
    }
    if connection.isLost { lose(control.slot, sink: sink) }
  }
}

/// Marks this bundle's image for `Bundle(for:)`
private final class EngineBundleToken {}

// MARK: - Rows

/// Batches a query's rows into `rows` events of about `rowsEventTargetBytes`, each sent on
/// credit. A row over that budget sends its biggest text, json, decimal or bytes cells as `chunk`
/// events (pieces of at most `chunkPieceBytes`, text pieces valid UTF-8) and `{c: true}` in the
/// row, with at most one chunked value per column per `rows` event. The credit of that `rows`
/// event is taken before its chunks go, so chunks never run ahead of the app. Sizes are upper
/// bounds of the encoded JSON (escapes included), so no event passes `maxEventBytes`.
struct RowStreamer {
  /// Raw bytes per chunk piece: escaped (or base64), even all control characters stay under 1 MiB
  static let chunkPieceBytes = 128 << 10
  /// A cell smaller than this is never chunked
  static let minimumChunkedCost = 1 << 10
  static let chunkedCellCost = 12
  /// Rows per `rows` event when the request leaves it to the plugin (`argv`)
  static let defaultBatchRows = 1_000

  let id: String
  let batchRows: Int
  let maxCellBytes: Int?
  let control: RequestControl
  let sink: EventSink
  private var rows: [[EngineCell]] = []
  private var cost = 0
  private var chunkedColumns: Set<Int> = []
  /// The credit of the pending `rows` event is already taken (its chunks went)
  private var hasCredit = false
  /// An event could not be sent (its `error` went instead): the query must stop
  private(set) var failed = false

  init(batchRows: Int, maxCellBytes: Int?, control: RequestControl, sink: EventSink) {
    id = control.id
    self.batchRows = max(1, batchRows)
    self.maxCellBytes = maxCellBytes
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
      let column = costs.indices.filter({ cells[$0].isChunkable && !chunked.contains($0) })
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
    if !chunked.isEmpty, !hasCredit {
      guard control.takeCredit() else { return false }
      hasCredit = true
    }
    for column in chunked {
      guard sendChunks(of: cells[column], column: column) else { return false }
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
    if !hasCredit {
      guard control.takeCredit() else { return false }
    }
    hasCredit = false
    guard sink.send(EngineEvent(id: id, kind: .rows(rows))) else {
      failed = true
      return false
    }
    rows.removeAll(keepingCapacity: true)
    cost = 0
    chunkedColumns.removeAll()
    return true
  }

  /// `cell` as `chunk` events of its own kind
  private mutating func sendChunks(of cell: EngineCell, column: Int) -> Bool {
    let pieces: [EngineCell]
    switch cell {
    case .text(let text): pieces = Self.pieces(of: text).map(EngineCell.text)
    case .json(let text): pieces = Self.pieces(of: text).map(EngineCell.json)
    case .decimal(let text): pieces = Self.pieces(of: text).map(EngineCell.decimal)
    case .bytes(let data):
      pieces = stride(from: 0, to: data.count, by: Self.chunkPieceBytes).map {
        let start = data.startIndex + $0
        return .bytes(Data(data[start..<min(start + Self.chunkPieceBytes, data.endIndex)]))
      }
    default: return false
    }
    for (index, piece) in pieces.enumerated() {
      guard !control.isCancelled else { return false }
      let chunk = EngineEvent.Chunk(column: column, data: piece, last: index == pieces.count - 1)
      guard sink.send(EngineEvent(id: id, kind: .chunk(chunk))) else {
        failed = true
        return false
      }
    }
    return true
  }

  /// `text` in pieces of at most `chunkPieceBytes`, each whole scalars
  private static func pieces(of text: String) -> [String] {
    let bytes = Array(text.utf8)
    var pieces: [String] = []
    var start = 0
    while start < bytes.count {
      var end = min(start + chunkPieceBytes, bytes.count)
      while end < bytes.count && bytes[end] & 0xC0 == 0x80 { end -= 1 }
      pieces.append(String(decoding: bytes[start..<end], as: UTF8.self))
      start = end
    }
    return pieces
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
  /// Whether the value can travel as `chunk` events
  fileprivate var isChunkable: Bool {
    switch self {
    case .text, .json, .decimal: true
    case .bytes(let data): !data.isEmpty
    default: false
    }
  }
}
