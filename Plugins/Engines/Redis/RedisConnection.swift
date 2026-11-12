// RedisConnection.swift
// One Redis server connection: the `EngineConnection` that sends `argv` requests over
// RedisTransport.swift and reads each reply as rows (see RESP.swift for the row shape).
//
// The socket's database is tracked: a request in another database is preceded by its own
// `SELECT <db>`, and while that `SELECT` is unanswered the database counts as unknown. The text
// `query` / `command` requests are refused. A read-only open sends only the reads of
// RedisReadOnly.swift (checked before the `SELECT`); catalog reads answer empty lists.
//
// Cancel: `interrupt` wakes a blocked read, which throws without consuming anything. The
// handler then calls `discardResults`, which drains what the reply still owes (whole nodes and
// payload bytes, never built into rows) for up to `drainBytes` or `drainSeconds`, so the socket
// stays in step and is kept. Past either cap the socket is closed and `isLost` turns true.
//
// Brakes (RedisBrakes.swift): the statement timeout is a deadline on the command's write and on
// its reply's first node (the server's run time; rows the app reads later on credit are not
// timed). Passing it on the read answers the timeout failure and takes the interrupt path above;
// on the write (part of the command may be sent) the connection is lost. When a drain passes its
// time cap (nothing came: the server may be busy running a script), a short-lived second
// connection asks the server to stop it, within `RedisBrakes.killSeconds`, before the loss is
// reported. A value over 256 MiB loses the connection at once (the stream is mid-payload).

import Foundation
import os

private let log = Logger(subsystem: "ace.thi.Dblore.Redis", category: "Connection")

/// One server connection. Used on its connection queue only, except `interrupt`.
final class RedisConnection: EngineConnection, @unchecked Sendable {
  /// What a drain may read at most before the socket is closed instead
  static let drainBytes = 64 << 20
  static let drainSeconds: TimeInterval = 3

  private let transport: RedisTransport
  private let usesTLS: Bool
  /// The open request (host, port, user, password, TLS), kept in memory only for the second
  /// connection that stops a busy script. Never logged: its descriptions redact the password.
  let request: EngineRequest.Open
  private(set) var serverVersion = ""
  /// 3 after `HELLO 3`, 2 when the server took RESP2 only
  private(set) var protocolVersion = 3
  /// The statement timeout of the `settings` request, 0 for none
  private var statementTimeoutSeconds = 0

  // Connection queue only
  /// The socket's database, nil while unknown
  private var database: Int?
  /// When the running command passes the statement timeout, nil without one
  private var commandDeadline: Date?
  /// The reply on the wire, read or drained
  private var reply: RESPReply?
  /// The reply's first row, read by `execute`
  private var root: [EngineCell]?
  /// A reply is ready for `nextResult` / `nextRow`
  private var hasResult = false
  private var columnsReturned = false
  private var lost = false
  private var closed = false

  init(transport: RedisTransport, usesTLS: Bool, request: EngineRequest.Open) {
    self.transport = transport
    self.usesTLS = usesTLS
    self.request = request
  }

  // MARK: Open

  /// Dials, then runs the open handshake (RedisHandshake.swift), all by `deadline`. Throws
  /// `EngineFailure`; the caller cleans the message of the password.
  func open(database home: Int, deadline: Date) throws {
    try io { try transport.connect(deadline: deadline) }
    let outcome = try RedisHandshake.run(
      username: request.username, password: request.password, database: home
    ) { args in
      try handshake(RESP.command(args.map { Data($0.utf8) }), deadline: deadline)
    }
    database = home
    protocolVersion = outcome.protocolVersion
    serverVersion = RedisHandshake.serverVersion(outcome.version, usesTLS: usesTLS)
  }

  /// Sends one open command and reads its whole reply (a short one) by `deadline`
  private func handshake(_ command: Data, deadline: Date) throws -> [RESPNode] {
    try io { try transport.write(command, deadline: deadline) }
    let reply = RESPReply()
    let reader = RedisReader(transport, deadline: deadline, interruptible: false)
    var nodes: [RESPNode] = []
    while let node = try io({ try reply.next(from: reader) }) {
      if nodes.isEmpty, node.type == "error" { throw Self.serverFailure(node) }
      nodes.append(node)
    }
    return nodes
  }

  // MARK: Statements

  func interrupt() {
    transport.interrupt()
  }

  func resetInterrupt() {
    transport.resetInterrupt()
  }

  /// The statement timeout first (it stays applied), then `unsupported` when a lock or idle
  /// timeout is asked for: Redis has neither
  func apply(_ settings: EngineRequest.Settings) throws {
    let (seconds, refusal) = RedisBrakes.apply(settings)
    statementTimeoutSeconds = seconds
    if let refusal { throw refusal }
  }

  func execute(_ sql: String) throws {
    throw EngineFailure(code: .unsupported, message: "Redis runs commands from the Redis editor.")
  }

  func execute(_ sql: String, binds: [String?]) throws {
    try execute(sql)
  }

  /// Sends `SELECT <db>` first when the socket is on another database, then the command, and
  /// reads the reply's first node: a top-level error throws here. On a read-only connection a
  /// command off the allowlist (RedisReadOnly.swift) throws before anything is sent. The
  /// statement timeout covers the `SELECT` and the command.
  func execute(argv args: [Data], db: Int) throws {
    discardResults()
    commandDeadline = nil
    guard !lost, !closed else {
      throw EngineFailure(code: .connect, message: "The connection to the server was lost.")
    }
    guard !args.isEmpty else {
      throw EngineFailure(code: .invalid, message: "The command is empty.")
    }
    guard db >= 0 else {
      throw EngineFailure(code: .invalid, message: "The database index must be 0 or more.")
    }
    if request.readOnly, let refusal = RedisReadOnly.refusal(args) { throw refusal }
    if statementTimeoutSeconds > 0 {
      commandDeadline = Date(timeIntervalSinceNow: TimeInterval(statementTimeoutSeconds))
    }
    if database != db {
      database = nil
      _ = try send(RESP.command("SELECT", String(db)))
      // `+OK`: the reply ends with its first node
      discardResults()
      guard !lost else {
        throw EngineFailure(code: .connect, message: "The connection to the server was lost.")
      }
      database = db
    }
    root = try send(RESP.command(args)).row
    hasResult = true
    columnsReturned = false
  }

  /// Writes `command` and reads the first node of its reply, both by `commandDeadline`. A
  /// top-level error throws (the reply is then whole).
  private func send(_ command: Data) throws -> RESPNode {
    // Interrupted before the write: nothing was sent, nothing is owed
    try io { try braked(write: true) { try transport.write(command, deadline: commandDeadline) } }
    let reply = RESPReply()
    self.reply = reply
    let reader = RedisReader(transport, deadline: commandDeadline, interruptible: true)
    guard let node = try io({ try braked(write: false) { try reply.next(from: reader) } }) else {
      throw RedisTransportError.malformed.failure
    }
    if node.type == "error", reply.isComplete {
      self.reply = nil
      throw Self.serverFailure(node)
    }
    return node
  }

  func nextResult() throws -> [EngineEvent.Column]? {
    guard hasResult else { return nil }
    if !columnsReturned {
      columnsReturned = true
      return RESP.columns
    }
    while try nextRow() != nil {}
    hasResult = false
    return nil
  }

  func nextRow() throws -> [EngineCell]? {
    guard hasResult else { return nil }
    if let row = root {
      root = nil
      return row
    }
    guard let reply, !reply.isComplete else { return nil }
    return try io { try reply.next(from: reader()) }?.row
  }

  var affectedRows: Int? { nil }

  /// Redis has no tables, views or columns: the list reads answer empty, so the app's
  /// introspector lists nothing (keys are read with `argv`). Other reads stay unsupported.
  func catalog(_ read: EngineRequest.Catalog) throws -> EngineCatalogResult {
    switch read.read {
    case .tables: .tables([])
    case .views: .views([])
    case .functions: .functions([])
    case .procedures: .procedures([])
    case .triggers: .triggers([])
    case .users: .users([])
    case .roles: .roles([])
    case .foreignKeys: .foreignKeys([])
    case .allColumns: .allColumns([:])
    case .primaryKey: .primaryKey([])
    case .definition: .definition(nil)
    case .editTable: .editTable(nil)
    default:
      throw EngineFailure(
        code: .unsupported, message: "This catalog read is not supported by this plugin.")
    }
  }

  /// Drains what the current reply still owes, within `drainBytes` / `drainSeconds`; past
  /// either the socket is closed and the connection is lost. An interrupt does not stop it.
  func discardResults() {
    root = nil
    hasResult = false
    guard let reply else { return }
    self.reply = nil
    guard !reply.isComplete, !lost, !closed else { return }
    let reader = RedisReader(
      transport, deadline: Date(timeIntervalSinceNow: Self.drainSeconds), interruptible: false,
      budget: Self.drainBytes)
    do {
      while try reply.skipNext(from: reader) {}
    } catch {
      log.notice("The rest of a reply could not be drained; the connection closes.")
      markLost()
      // The drain passed its `drainSeconds` deadline (bytes may still have been arriving): the
      // server may be busy running a script
      if error as? RedisTransportError == .timedOut { stopBusyScript() }
    }
  }

  /// Best effort, within `RedisBrakes.killSeconds` in all: a second connection to the same
  /// endpoint (same TLS and local-host policy) sends only the open's authentication,
  /// `SCRIPT KILL` and `FUNCTION KILL` (RedisBrakes.swift), skips their replies whatever they
  /// say (`NOTBUSY`, `UNKILLABLE`, ...), then closes. Nothing it reads is logged: an error can
  /// echo the password.
  private func stopBusyScript() {
    guard let endpoint = try? RedisEndpoint(request) else { return }
    let deadline = Date(timeIntervalSinceNow: RedisBrakes.killSeconds)
    let kill = RedisTransport(
      endpoint: endpoint, connectTimeoutSeconds: Int(RedisBrakes.killSeconds))
    defer { kill.close() }
    let commands = RedisBrakes.killCommands(
      username: request.username, password: request.password, protocolVersion: protocolVersion)
    do {
      try kill.connect(deadline: deadline)
      // One write: the server reads them all once it reads clients again
      try kill.write(
        commands.reduce(into: Data()) { $0.append(RESP.command($1.map { Data($0.utf8) })) },
        deadline: deadline)
      let reader = RedisReader(
        kill, deadline: deadline, interruptible: false, budget: Self.killReplyBytes)
      for _ in commands {
        let reply = RESPReply()
        while try reply.skipNext(from: reader) {}
      }
      log.notice("\(endpoint.host, privacy: .public): asked the server to stop a busy script.")
    } catch {
      log.notice("\(endpoint.host, privacy: .public): the request to stop a busy script failed.")
    }
  }

  /// What the kill connection's replies may hold at most
  private static let killReplyBytes = 1 << 20

  var isLost: Bool { lost }

  func close() {
    guard !closed else { return }
    closed = true
    reply = nil
    root = nil
    hasResult = false
    transport.close()
  }

  // MARK: Helpers

  /// A reader for a request's reply: no deadline, stopped by an interrupt
  private func reader() -> RedisReader {
    RedisReader(transport, deadline: nil, interruptible: true)
  }

  /// `body`, with transport and stream failures as `EngineFailure`. Any of them but an
  /// interrupt leaves the stream out of step: the connection is lost. So does a value over
  /// 256 MiB (`tooLarge`): the stream stops mid-payload, past what a drain would skip.
  private func io<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as RedisTransportError {
      if error != .interrupted { markLost() }
      throw error.failure
    } catch let error as RESPProtocolError {
      markLost()
      throw error.failure
    } catch let failure as EngineFailure where failure.code == .tooLarge {
      markLost()
      throw failure
    }
  }

  /// `body`, a command's write or its reply's first read, with the statement deadline's
  /// timeout as the timeout failure. A read stopped by it consumed nothing (the drain follows,
  /// as after an interrupt); a write may have sent part of the command, so the connection is
  /// lost.
  private func braked<T>(write: Bool, _ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch RedisTransportError.timedOut where commandDeadline != nil {
      if write { markLost() }
      throw RedisBrakes.timeoutFailure(seconds: statementTimeoutSeconds)
    }
  }

  private func markLost() {
    guard !lost else { return }
    lost = true
    reply = nil
    transport.close()
  }

  /// A top-level error reply: its first word is the server code (`ERR`, `WRONGTYPE`, ...)
  private static func serverFailure(_ node: RESPNode) -> EngineFailure {
    var text: String
    switch node.value {
    case .text(let value): text = value
    case .bytes(let value): text = String(decoding: value, as: UTF8.self)
    default: text = ""
    }
    // "ERR unknown command 'X', with args beginning with: ..." echoes the arguments (a
    // password, say): the message keeps only what comes before them
    if let echo = text.range(of: "with args", options: .caseInsensitive) {
      text = String(text[..<echo.lowerBound]).trimmingCharacters(
        in: CharacterSet(charactersIn: " ,"))
    }
    let code = text.split(separator: " ", maxSplits: 1).first.map(String.init)
    return EngineFailure(
      code: .query, message: text.isEmpty ? "The server refused the command." : text,
      serverCode: code)
  }
}
