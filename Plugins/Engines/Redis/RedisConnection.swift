// RedisConnection.swift
// One Redis server connection: the `EngineConnection` that sends `argv` requests over
// RedisTransport.swift and reads each reply as rows (see RESP.swift for the row shape).
//
// The socket's database is tracked: a request in another database is preceded by its own
// `SELECT <db>`, and while that `SELECT` is unanswered the database counts as unknown. The text
// `query` / `command` requests are refused.
//
// Cancel: `interrupt` wakes a blocked read, which throws without consuming anything. The
// handler then calls `discardResults`, which drains what the reply still owes (whole nodes and
// payload bytes, never built into rows) for up to `drainBytes` or `drainSeconds`, so the socket
// stays in step and is kept. Past either cap the socket is closed and `isLost` turns true.

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
  private(set) var serverVersion = ""

  // Connection queue only
  /// The socket's database, nil while unknown
  private var database: Int?
  /// The reply on the wire, read or drained
  private var reply: RESPReply?
  /// The reply's first row, read by `execute`
  private var root: [EngineCell]?
  /// A reply is ready for `nextResult` / `nextRow`
  private var hasResult = false
  private var columnsReturned = false
  private var lost = false
  private var closed = false

  init(transport: RedisTransport, usesTLS: Bool) {
    self.transport = transport
    self.usesTLS = usesTLS
  }

  // MARK: Open

  /// Dials, then `HELLO 3` (with `AUTH` when a password is set) and `SELECT <database>`, all by
  /// `deadline`. Throws `EngineFailure`; the caller cleans the message of the password.
  func open(username: String, password: String, database home: Int, deadline: Date) throws {
    try io { try transport.connect(deadline: deadline) }
    var hello = ["HELLO", "3"]
    if !password.isEmpty {
      hello += ["AUTH", username.isEmpty ? "default" : username, password]
    }
    let nodes = try handshake(RESP.command(hello.map { Data($0.utf8) }), deadline: deadline)
    // The map's direct children alternate key and value
    let pairs = nodes.filter { $0.path.split(separator: ".").count == 2 }
    var version: String?
    var index = 0
    while index + 1 < pairs.count {
      if pairs[index].text == "version" { version = pairs[index + 1].text }
      index += 2
    }
    if home != 0 {
      _ = try handshake(RESP.command("SELECT", String(home)), deadline: deadline)
    }
    database = home
    serverVersion = "Redis" + (version.map { " \($0)" } ?? "") + (usesTLS ? " (TLS)" : "")
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

  func execute(_ sql: String) throws {
    throw EngineFailure(code: .unsupported, message: "Redis runs commands from the Redis editor.")
  }

  func execute(_ sql: String, binds: [String?]) throws {
    try execute(sql)
  }

  /// Sends `SELECT <db>` first when the socket is on another database, then the command, and
  /// reads the reply's first node: a top-level error throws here
  func execute(argv args: [Data], db: Int) throws {
    discardResults()
    guard !lost, !closed else {
      throw EngineFailure(code: .connect, message: "The connection to the server was lost.")
    }
    guard !args.isEmpty else {
      throw EngineFailure(code: .invalid, message: "The command is empty.")
    }
    guard db >= 0 else {
      throw EngineFailure(code: .invalid, message: "The database index must be 0 or more.")
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

  /// Writes `command` and reads the first node of its reply. A top-level error throws (the
  /// reply is then whole).
  private func send(_ command: Data) throws -> RESPNode {
    // Interrupted before the write: nothing was sent, nothing is owed
    try io { try transport.write(command, deadline: nil) }
    let reply = RESPReply()
    self.reply = reply
    guard let node = try io({ try reply.next(from: reader()) }) else {
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
    }
  }

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
  /// interrupt leaves the stream out of step: the connection is lost.
  private func io<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as RedisTransportError {
      if error != .interrupted { markLost() }
      throw error.failure
    } catch is RESPProtocolError {
      markLost()
      throw RedisTransportError.malformed.failure
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
