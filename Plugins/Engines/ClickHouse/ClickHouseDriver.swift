// ClickHouseDriver.swift
// The ClickHouse engine of the plugin, over the HTTP(S) interface (see ClickHouseHTTP.swift for
// TLS and credentials, ClickHouseFormat.swift for cells).
//
// One connection is one server session (`session_id`), so `SET` and temporary tables last
// between statements; the server runs one statement of a session at a time. Each statement has
// its own `query_id`. Settings sent with every statement: the reply format, `readonly=2` on a
// read-only connection (the server refuses writes; settings may still change),
// `max_execution_time` once the app's statement timeout is applied.
//
// Cancel: `KILL QUERY WHERE query_id = {id:String} SYNC` on a request outside the session (the
// session is busy with the statement), and the statement's request is cancelled.
//
// Binds: the app writes `{p1:Type}`, `{p2:Type}`, ...; bind N goes as the URL parameter
// `param_pN`, in the server's escaped text form (`\N` is NULL).
//
// `opened.serverVersion` is the server's version followed by the transport, e.g.
// "24.8.4.13 (https)". The same is logged (os_log, subsystem ace.thi.Dblore.ClickHouse), never
// the password; server texts are logged private.

import Foundation
import os

/// This bundle's engine
let engineDriver: any EngineDriver = ClickHouseDriver()

private let log = Logger(subsystem: "ace.thi.Dblore.ClickHouse", category: "Connection")

struct ClickHouseDriver: EngineDriver {
  var engine: String { "clickhouse" }
  var queryLanguage: String { "sql" }
  var libraries: [String: String] { [:] }

  /// The base configuration of each connection's URLSession. Tests stub the transport by
  /// returning one with `protocolClasses`.
  let makeConfiguration: @Sendable () -> URLSessionConfiguration

  init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
    self.makeConfiguration = makeConfiguration
  }

  func connect(_ open: EngineRequest.Open) throws -> any EngineConnection {
    let endpoint = try ClickHouseEndpoint(open)
    let connection = ClickHouseConnection(
      http: ClickHouseHTTP(endpoint: endpoint, configuration: makeConfiguration()),
      database: open.database, readOnly: open.readOnly)
    let timeoutSeconds = open.timeoutSeconds > 0 ? min(open.timeoutSeconds, 3_600) : 30
    do {
      try connection.probe(timeoutSeconds: TimeInterval(timeoutSeconds))
    } catch {
      connection.close()
      let failure = EngineFailure.from(error, code: .connect)
      let message = failure.message
      log.error("\(open.host, privacy: .public): open failed: \(message, privacy: .private)")
      throw EngineFailure(code: .connect, message: failure.message, serverCode: failure.serverCode)
    }
    log.notice(
      "\(open.host, privacy: .public): connected, \(connection.serverVersion, privacy: .public)")
    return connection
  }
}

// MARK: - Connection

/// One server session. Used on its connection queue only, except `interrupt`.
final class ClickHouseConnection: EngineConnection, @unchecked Sendable {
  /// How long a discard waits for the server to drop a stopped statement
  static let killTimeout: TimeInterval = 10
  /// How long the rest of an error text may take to arrive (it ends the reply)
  static let errorTextWait: TimeInterval = 1

  private let http: ClickHouseHTTP
  private let database: String
  private let readOnly: Bool
  private let sessionID = UUID().uuidString
  private(set) var serverVersion = ""

  private let lock = NSLock()
  /// The statement on the wire, guarded by `lock`
  private var running: (response: ClickHouseResponse, queryID: String)?
  /// The `KILL QUERY` an interrupt sent, guarded by `lock`
  private var killing: ClickHouseResponse?
  /// Guarded by `lock`
  private var interrupted = false

  // Connection queue only
  private var statement: Statement?
  private var maxExecutionTime: Int?
  private var lost = false
  private var closed = false

  /// The reply of the current statement
  private struct Statement {
    let response: ClickHouseResponse
    let queryID: String
    let columns: [EngineEvent.Column]
    let kinds: [ClickHouseFormat.Kind]
    /// The X-ClickHouse-Summary `written_rows`
    let writtenRows: Int?
    var columnsReturned = false
    var rowsDone = false
    /// A line read ahead to tell a last exception row from a value
    var lookahead: Data?
  }

  init(http: ClickHouseHTTP, database: String, readOnly: Bool) {
    self.http = http
    self.database = database
    self.readOnly = readOnly
  }

  deinit { http.invalidate() }

  /// The open check: `SELECT version()` within `timeoutSeconds`
  fileprivate func probe(timeoutSeconds: TimeInterval) throws {
    defer { discardResults() }
    try start("SELECT version()", parameters: [], timeout: timeoutSeconds)
    guard try nextResult()?.count == 1, let row = try nextRow(),
      case .text(let version)? = row.first
    else { throw EngineFailure(code: .connect, message: "The server did not report its version.") }
    // Read to the end, so the discard sees a finished reply and kills nothing
    while try nextRow() != nil {}
    serverVersion = "\(version) (\(http.endpoint.usesTLS ? "https" : "http"))"
  }

  // MARK: Statements

  func interrupt() {
    lock.withLock {
      interrupted = true
      guard let running else { return }
      if killing == nil { killing = kill(running.queryID) }
      running.response.cancel()
    }
  }

  func resetInterrupt() {
    lock.withLock { interrupted = false }
  }

  func execute(_ sql: String) throws {
    try execute(sql, binds: [])
  }

  /// `sql` with bind N (1-based) as `{pN:Type}`
  func execute(_ sql: String, binds: [String?]) throws {
    let parameters = binds.enumerated().map {
      ("param_p\($0.offset + 1)", Self.escaped($0.element))
    }
    try start(sql, parameters: parameters)
  }

  /// The `settings` request: the statement timeout as `max_execution_time` (0 = none). The lock
  /// and idle timeouts have no ClickHouse counterpart and are ignored.
  func apply(_ settings: EngineRequest.Settings) {
    maxExecutionTime = settings.statementTimeoutSeconds > 0 ? settings.statementTimeoutSeconds : nil
  }

  /// A `catalog` request
  func catalog(_ request: EngineRequest.Catalog) throws -> EngineCatalogResult {
    try ClickHouseCatalog(connection: self).read(request)
  }

  /// Every row of `sql`, with each named parameter as `{name:Type}` (catalog reads)
  func rows(_ sql: String, parameters: [String: String] = [:]) throws -> [[EngineCell]] {
    defer { discardResults() }
    try start(
      sql,
      parameters: parameters.sorted { $0.key < $1.key }.map { ("param_\($0)", Self.escaped($1)) })
    guard try nextResult() != nil else { return [] }
    var rows: [[EngineCell]] = []
    while let row = try nextRow() { rows.append(row) }
    return rows
  }

  /// Sends `sql` and reads the reply's status, headers, column names and types
  private func start(
    _ sql: String, parameters: [(String, String)], timeout: TimeInterval? = nil
  ) throws {
    discardResults()
    let queryID = UUID().uuidString
    let request = try http.request(
      sql, parameters: sessionParameters(queryID: queryID) + parameters, timeout: timeout)
    let response: ClickHouseResponse? = lock.withLock {
      guard !interrupted else { return nil }
      let response = http.start(request)
      running = (response, queryID)
      return response
    }
    guard let response else { throw ClickHouseTransportError.cancelled.failure }

    let head = try transport { try response.waitForHead() }
    let exceptionCode = head.value(forHTTPHeaderField: "X-ClickHouse-Exception-Code")
    guard head.statusCode == 200, exceptionCode == nil else {
      let body = response.remainingBody(limit: ClickHouseFormat.maxErrorBytes)
      finishRunning()
      throw ClickHouseFormat.failure(fromBody: body, headerCode: exceptionCode)
    }
    let writtenRows = Self.writtenRows(head.value(forHTTPHeaderField: "X-ClickHouse-Summary"))
    var columns: [EngineEvent.Column] = []
    if let namesLine = try transport({ try response.nextLine() }) {
      let typesLine = try transport { try response.nextLine() } ?? Data()
      guard let names = Self.strings(namesLine), let types = Self.strings(typesLine),
        names.count == types.count, !names.isEmpty
      else {
        // Either way the reply stays `running`: the discard that follows a failure stops a reply
        // still streaming (rows of another format that merely look like an error) and kills its
        // query, and leaves a finished one (a real error) alone
        var body = namesLine + Data([0x0A]) + typesLine + Data([0x0A])
        // A server error: its text is short and ends the reply
        if Self.isErrorText(body) {
          body.append(
            response.bufferedBody(
              limit: ClickHouseFormat.maxErrorBytes, wait: Self.errorTextWait))
          throw ClickHouseFormat.failure(fromBody: body, headerCode: nil)
        }
        // Another format (a FORMAT clause), perhaps a long one
        throw EngineFailure(
          code: .query,
          message: "Dblore reads results in its own format; remove the FORMAT clause.")
      }
      columns = zip(names, types).map { EngineEvent.Column(name: $0, type: $1) }
    }
    statement = Statement(
      response: response, queryID: queryID, columns: columns,
      kinds: columns.map { ClickHouseFormat.kind(of: $0.type) }, writtenRows: writtenRows,
      rowsDone: columns.isEmpty)
  }

  /// One result: the reply's columns (empty for a statement without rows), then nil
  func nextResult() throws -> [EngineEvent.Column]? {
    guard var current = statement else { return nil }
    if !current.columnsReturned {
      current.columnsReturned = true
      statement = current
      return current.columns
    }
    while try nextRow() != nil {}
    return nil
  }

  func nextRow() throws -> [EngineCell]? {
    guard var current = statement, !current.rowsDone else { return nil }
    let response = current.response
    defer { statement = current }
    while true {
      let line: Data
      if let held = current.lookahead {
        line = held
        current.lookahead = nil
      } else {
        guard let next = try transport({ try response.nextLine() }) else {
          current.rowsDone = true
          finishRunning()
          return nil
        }
        line = next
      }
      if line.isEmpty { continue }
      guard let tokens = ClickHouseFormat.tokens(of: line), tokens.count == current.kinds.count
      else {
        // The server wrote an exception into the body after rows, as plain text
        current.rowsDone = true
        var body = line + Data([0x0A])
        // Without waiting on a reply that goes on: the discard that follows stops it
        body.append(
          response.bufferedBody(limit: ClickHouseFormat.maxErrorBytes, wait: Self.errorTextWait))
        let failure = ClickHouseFormat.failure(fromBody: body, headerCode: nil)
        if failure.serverCode == nil, let broken = response.transportFailure {
          throw mark(broken).failure
        }
        throw failure
      }
      // Servers 23.9 to 25.10 write it as a last row `["Code: N. DB::Exception: ..."]` instead:
      // such a row fails the query when nothing follows it
      if tokens.count == 1, case .string(let text) = tokens[0],
        ClickHouseFormat.isException(text)
      {
        let after: Data?
        do {
          after = try transport { try response.nextLine() }
        } catch {
          current.rowsDone = true
          throw ClickHouseFormat.failure(fromBody: Data(text.utf8), headerCode: nil)
        }
        guard let after else {
          current.rowsDone = true
          throw ClickHouseFormat.failure(fromBody: Data(text.utf8), headerCode: nil)
        }
        current.lookahead = after
      }
      return zip(tokens, current.kinds).map { ClickHouseFormat.cell($0, kind: $1) }
    }
  }

  var affectedRows: Int? {
    guard let statement, statement.columns.isEmpty, let rows = statement.writtenRows, rows > 0
    else { return nil }
    return rows
  }

  /// Drops the rest of the reply. A statement the server may still run (its reply had begun, or
  /// an interrupt killed it) is killed, and the discard waits up to `killTimeout` for the server
  /// to confirm, so the session is free for the next statement. Nothing is sent to a server that
  /// could not be reached.
  func discardResults() {
    let current = statement.map { ($0.response, $0.queryID) } ?? lock.withLock { running }
    statement = nil
    guard let (response, queryID) = current else {
      lock.withLock { killing = nil }
      return
    }
    let mayRun = response.hasHead && !response.isFinished && !lost
    response.cancel()
    let kill: ClickHouseResponse? = lock.withLock {
      defer { killing = nil }
      return killing ?? (mayRun ? self.kill(queryID) : nil)
    }
    kill?.waitForEnd(timeout: Self.killTimeout)
    finishRunning()
  }

  var isLost: Bool { lost }

  func close() {
    guard !closed else { return }
    closed = true
    lock.withLock { running?.response.cancel() }
    statement = nil
    finishRunning()
    http.invalidate()
  }

  // MARK: Helpers

  /// The URL parameters of every statement of the session
  private func sessionParameters(queryID: String) -> [(String, String)] {
    var parameters = ClickHouseFormat.settings
    parameters.append(("session_id", sessionID))
    parameters.append(("query_id", queryID))
    if !database.isEmpty { parameters.append(("database", database)) }
    if readOnly { parameters.append(("readonly", "2")) }
    if let maxExecutionTime { parameters.append(("max_execution_time", String(maxExecutionTime))) }
    return parameters
  }

  /// Starts `KILL QUERY` for `queryID` outside the session. Never waits.
  private func kill(_ queryID: String) -> ClickHouseResponse? {
    guard
      let request = try? http.request(
        "KILL QUERY WHERE query_id = {id:String} SYNC", parameters: [("param_id", queryID)],
        timeout: Self.killTimeout)
    else { return nil }
    return http.start(request)
  }

  private func finishRunning() {
    lock.withLock { running = nil }
  }

  /// `body`, with a transport failure as an `EngineFailure` (a lost server marks the
  /// connection lost)
  private func transport<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as ClickHouseTransportError {
      throw mark(error).failure
    }
  }

  private func mark(_ error: ClickHouseTransportError) -> ClickHouseTransportError {
    if case .unreachable = error { lost = true }
    return error
  }

  /// Whether the start of a reply body is a server error rather than rows of another format
  private static func isErrorText(_ body: Data) -> Bool {
    let text = String(decoding: body.prefix(ClickHouseFormat.maxErrorBytes), as: UTF8.self)
    return ClickHouseFormat.serverCode(in: text) != nil || text.contains("__exception__")
      || text.hasPrefix("{\"exception\"")
  }

  /// A header line: every value a string
  private static func strings(_ line: Data) -> [String]? {
    guard let tokens = ClickHouseFormat.tokens(of: line) else { return nil }
    var strings: [String] = []
    for token in tokens {
      guard case .string(let text) = token else { return nil }
      strings.append(text)
    }
    return strings
  }

  /// `written_rows` of an X-ClickHouse-Summary header (`{"read_rows":"0","written_rows":"3",...}`)
  private static func writtenRows(_ summary: String?) -> Int? {
    guard let summary,
      let object = try? JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any]
    else { return nil }
    switch object["written_rows"] {
    case let text as String: return Int(text)
    case let number as NSNumber: return number.intValue
    default: return nil
    }
  }

  /// A parameter value in the server's escaped text form; nil is `\N` (NULL)
  static func escaped(_ value: String?) -> String {
    guard let value else { return "\\N" }
    var out = ""
    out.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\\": out += "\\\\"
      case "\t": out += "\\t"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\u{0}": out += "\\0"
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out
  }
}
