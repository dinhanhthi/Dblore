// EnginePluginProtocol.swift
// Engine plugin protocol v1 between Dblore and a database engine bundle: one JSON object per
// request and per event, passed through `dblore_engine_request` and its `emit` callback. Every
// engine bundle compiles this same file by path, so it stays Foundation only and holds no app
// type.

import Foundation

/// Version, limits and JSON codec of protocol v1. A request names its kind in `type` and an
/// event in `event`; the kind's fields sit next to the envelope's `id` and `connection`. Unknown
/// kinds decode as `.unknown`, unknown keys are ignored, and error codes, catalog reads and closed
/// reasons are open-ended, so additive changes (advertised in `hello.features`) keep version 1.
/// Event text comes from the plugin and is untrusted.
///
/// Plugin obligations beyond the shapes:
/// - `close` is always answered (`closed` or `error`), even for a lost or unknown connection.
/// - `cancel` is routed by `target` alone (`connection` may be nil).
/// - A `columns` or `chunk` event is never over `maxEventBytes`: sorted keys put `columns` and
///   `data` before `id`, so the app cannot tell which request such an event belongs to. A result
///   whose column metadata would pass the cap is answered with an `error` of code `tooLarge`.
/// - Every non-optional field of a catalog record is always sent, an empty array included (see
///   `EngineCatalog`): one missing field fails the whole `catalog` event.
nonisolated enum EnginePluginProtocol {

  /// The version `dblore_engine_protocol()` returns and `hello` reports
  static let version = 1

  /// The largest event either side accepts (1 MiB); the app refuses a bigger one
  static let maxEventBytes = 1 << 20

  /// The size a plugin aims for per `rows` event (512 KiB); a single cell over it goes as
  /// `chunk` events
  static let rowsEventTargetBytes = 512 << 10

  /// The largest value chunks may rebuild (256 MiB); a bigger one fails with `tooLarge`
  static let maxValueBytes = 256 << 20

  /// The request as compact JSON with sorted keys. NaN and infinities travel as the strings
  /// `NaN`, `Infinity` and `-Infinity`.
  static func encodeRequest(_ request: EngineRequest) throws -> Data {
    do { return try encoder().encode(request) } catch {
      throw EngineProtocolError.invalid(requestID: request.id)
    }
  }

  /// The request, or `invalid` with the request's id when it has one
  static func decodeRequest(_ data: Data) throws -> EngineRequest {
    do { return try decoder().decode(EngineRequest.self, from: data) } catch {
      throw EngineProtocolError.invalid(requestID: envelopeID(data))
    }
  }

  /// The event as compact JSON with sorted keys; `tooLarge` when it is over `maxEventBytes`
  static func encodeEvent(_ event: EngineEvent) throws -> Data {
    let data: Data
    do { data = try encoder().encode(event) } catch {
      throw EngineProtocolError.invalid(requestID: event.id)
    }
    guard data.count <= maxEventBytes else { throw EngineProtocolError.tooLarge }
    return data
  }

  /// The event; `tooLarge` before any parsing when `data` is over `maxEventBytes`, `invalid`
  /// with the event's id (when readable) when it is not a well-formed event
  static func decodeEvent(_ data: Data) throws -> EngineEvent {
    guard data.count <= maxEventBytes else { throw EngineProtocolError.tooLarge }
    do { return try decoder().decode(EngineEvent.self, from: data) } catch {
      throw EngineProtocolError.invalid(requestID: envelopeID(data))
    }
  }

  private static let nonFinite = (positive: "Infinity", negative: "-Infinity", nan: "NaN")

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: nonFinite.positive, negativeInfinity: nonFinite.negative,
      nan: nonFinite.nan)
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: nonFinite.positive, negativeInfinity: nonFinite.negative,
      nan: nonFinite.nan)
    return decoder
  }

  /// The `id` of a JSON object that failed to decode, so its request can be failed
  private static func envelopeID(_ data: Data) -> String? {
    struct Envelope: Decodable { let id: String? }
    return (try? JSONDecoder().decode(Envelope.self, from: data))?.id
  }
}

/// A codec failure. Never carries input text, so an open request's password can't leak.
nonisolated enum EngineProtocolError: Error, Equatable, Sendable {
  /// An event over `maxEventBytes`, or a chunked value over `maxValueBytes`
  case tooLarge
  /// Not a well-formed request, event or chunk sequence. `requestID` names the request it
  /// belongs to when that could be read.
  case invalid(requestID: String?)
}

// MARK: - Values

/// A free-form JSON value: `open.options` and catalog `args`
nonisolated enum EngineJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([EngineJSONValue])
  case object([String: EngineJSONValue])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(String.self) {  // before Double: "NaN" is text
      self = .string(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode([EngineJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: EngineJSONValue].self))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

/// One result cell. On the wire: `null`, or an object with one key naming the kind.
nonisolated enum EngineCell: Equatable, Sendable {
  case null
  /// `{s: text}`
  case text(String)
  /// `{i: int}`
  case int(Int)
  /// `{f: double}`
  case double(Double)
  /// `{b: bool}`
  case bool(Bool)
  /// `{j: json text}`
  case json(String)
  /// `{d: ISO-8601 instant}`, kept as text so sub-millisecond digits survive
  case date(String)
  /// `{x: base64}`
  case bytes(Data)
  /// `{m: decimal text}`, exact
  case decimal(String)
  /// `{c: true}`: the value came before in `chunk` events (`EngineChunkAssembler`)
  case chunked
}

nonisolated extension EngineCell: Codable {
  private enum CodingKeys: String, CodingKey { case s, i, f, b, j, d, x, m, c }

  init(from decoder: any Decoder) throws {
    if try decoder.singleValueContainer().decodeNil() {
      self = .null
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func text(_ key: CodingKeys) throws -> String? {
      try container.decodeIfPresent(String.self, forKey: key)
    }
    if let value = try text(.s) {
      self = .text(value)
    } else if let value = try container.decodeIfPresent(Int.self, forKey: .i) {
      self = .int(value)
    } else if let value = try container.decodeIfPresent(Double.self, forKey: .f) {
      self = .double(value)
    } else if let value = try container.decodeIfPresent(Bool.self, forKey: .b) {
      self = .bool(value)
    } else if let value = try text(.j) {
      self = .json(value)
    } else if let value = try text(.d) {
      self = .date(value)
    } else if let value = try container.decodeIfPresent(Data.self, forKey: .x) {
      self = .bytes(value)
    } else if let value = try text(.m) {
      self = .decimal(value)
    } else if try container.decodeIfPresent(Bool.self, forKey: .c) == true {
      self = .chunked
    } else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: container.codingPath, debugDescription: "Not a cell"))
    }
  }

  func encode(to encoder: any Encoder) throws {
    if case .null = self {
      var container = encoder.singleValueContainer()
      try container.encodeNil()
      return
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .null: break
    case .text(let value): try container.encode(value, forKey: .s)
    case .int(let value): try container.encode(value, forKey: .i)
    case .double(let value): try container.encode(value, forKey: .f)
    case .bool(let value): try container.encode(value, forKey: .b)
    case .json(let value): try container.encode(value, forKey: .j)
    case .date(let value): try container.encode(value, forKey: .d)
    case .bytes(let value): try container.encode(value, forKey: .x)
    case .decimal(let value): try container.encode(value, forKey: .m)
    case .chunked: try container.encode(true, forKey: .c)
    }
  }
}

/// Rebuilds values sent as `chunk` events. A plugin sends a cell over its event budget as
/// pieces of one kind (`s`, `j`, `m`, or `x`, each piece valid on its own), the last one with
/// `last: true`, before the `rows` event whose `{c: true}` cell stands for it. One finished
/// value per column waits for its row. `maxValueBytes` bounds each value and also every value
/// gathered at once, across columns. Any failure drops everything gathered.
nonisolated struct EngineChunkAssembler: Sendable {
  let maxValueBytes: Int
  /// The result's column count when known; a chunk past it is `invalid`
  let columnCount: Int?
  private var building: [Int: Value] = [:]
  private var finished: [Int: Value] = [:]
  /// Bytes in `building` and `finished`
  private var gatheredBytes = 0

  init(maxValueBytes: Int = EnginePluginProtocol.maxValueBytes, columnCount: Int? = nil) {
    self.maxValueBytes = maxValueBytes
    self.columnCount = columnCount
  }

  /// Adds one piece; `tooLarge` once the value, or all values gathered, would pass
  /// `maxValueBytes`; `invalid` for a column out of range
  mutating func append(_ chunk: EngineEvent.Chunk) throws {
    let column = chunk.column
    guard column >= 0, column < columnCount ?? .max, finished[column] == nil,
      let piece = Value(chunk.data), building[column].map({ $0.kind == piece.kind }) ?? true
    else { throw reset(.invalid(requestID: nil)) }
    guard (building[column]?.byteCount ?? 0) + piece.byteCount <= maxValueBytes,
      gatheredBytes + piece.byteCount <= maxValueBytes
    else { throw reset(.tooLarge) }
    building[column, default: Value(kind: piece.kind)].append(piece)
    gatheredBytes += piece.byteCount
    if chunk.last { finished[column] = building.removeValue(forKey: column) }
  }

  /// `rows` with every `{c: true}` cell replaced by its column's finished value; `invalid`
  /// when a column has none
  mutating func resolve(_ rows: [[EngineCell]]) throws -> [[EngineCell]] {
    var rows = rows
    for row in rows.indices {
      for column in rows[row].indices {
        guard case .chunked = rows[row][column] else { continue }
        guard let value = finished.removeValue(forKey: column) else {
          throw reset(.invalid(requestID: nil))
        }
        gatheredBytes -= value.byteCount
        rows[row][column] = value.cell
      }
    }
    return rows
  }

  private mutating func reset(_ error: EngineProtocolError) -> EngineProtocolError {
    building.removeAll()
    finished.removeAll()
    gatheredBytes = 0
    return error
  }

  /// A value being rebuilt, appended in place
  private struct Value: Sendable {
    enum Kind: Sendable { case text, json, decimal, bytes }
    let kind: Kind
    var text = ""
    var bytes = Data()

    init(kind: Kind) { self.kind = kind }

    init?(_ cell: EngineCell) {
      switch cell {
      case .text(let value): self.init(kind: .text, text: value)
      case .json(let value): self.init(kind: .json, text: value)
      case .decimal(let value): self.init(kind: .decimal, text: value)
      case .bytes(let value):
        self.init(kind: .bytes)
        bytes = value
      default: return nil
      }
    }

    private init(kind: Kind, text: String) {
      self.kind = kind
      self.text = text
    }

    var byteCount: Int { kind == .bytes ? bytes.count : text.utf8.count }

    mutating func append(_ piece: Value) {
      if kind == .bytes { bytes.append(piece.bytes) } else { text += piece.text }
    }

    var cell: EngineCell {
      switch kind {
      case .text: .text(text)
      case .json: .json(text)
      case .decimal: .decimal(text)
      case .bytes: .bytes(bytes)
      }
    }
  }
}

// MARK: - Requests

/// One request from the app. `connection` is the id the app gave the session in `open`.
nonisolated struct EngineRequest: Equatable, Sendable {
  nonisolated enum Kind: Equatable, Sendable {
    /// Answered by a `hello` event
    case hello
    /// Answered by `opened`
    case open(Open)
    /// Answered by `closed` (or `error`), even for a lost or unknown connection
    case close
    /// Answered by `columns`, `rows` (on credit), `chunk`, then `done`
    case query(Query)
    /// Answered by `done`
    case command(Command)
    /// Credit for one more `rows` event of the query with the `target` id
    case more(target: String)
    /// Stops the request with the `target` id, which ends with `cancelled`
    case cancel(target: String)
    /// Answered by `settingsApplied`
    case settings(Settings)
    /// Answered by `transactionState`
    case transactionState
    /// Answered by `catalog`
    case catalog(Catalog)
    /// Answered like `query` (`columns`, `rows` on credit, `chunk`, then `done`); served only
    /// by a plugin whose `hello.features` holds `argv`
    case argv(Argv)
    /// A kind this side does not know; answer it with an `unsupported` error
    case unknown(String)
  }

  /// The only request that holds the password. Its descriptions, mirror and `dump` redact it.
  nonisolated struct Open: Equatable, Sendable {
    nonisolated struct TLS: Codable, Equatable, Sendable {
      nonisolated enum Mode: String, Codable, Sendable {
        case off, request, require, verifyCA, verifyFull
      }
      let mode: Mode
      /// The CA to trust, PEM; nil trusts the system anchors. Never shown in descriptions.
      var caPEM: String? = nil
    }

    let host: String
    let port: Int
    /// The name the server certificate must match (the configured host behind an SSH tunnel)
    let tlsServerName: String
    let database: String
    let username: String
    let password: String
    let tls: TLS
    let timeoutSeconds: Int
    let readOnly: Bool
    /// Engine-specific switches
    let options: [String: EngineJSONValue]
  }

  nonisolated struct Query: Equatable, Sendable {
    let sql: String
    /// Positional parameters as text; nil is NULL
    let binds: [String?]
    /// `sql`; other engines name their query language here
    let language: String
    /// Rows per `rows` event at most
    let batchRows: Int
    /// Cells over this many bytes may be cut; nil reads them whole
    var maxCellBytes: Int? = nil
  }

  nonisolated struct Command: Codable, Equatable, Sendable {
    let sql: String
    let binds: [String?]
  }

  /// One command as its raw arguments, the command name first. On the wire an argument is text
  /// when its bytes are valid UTF-8, else `{x: base64}`; either way it decodes to the exact
  /// bytes. Descriptions, mirror and `dump` show the command name and the argument count only:
  /// the other arguments can be keys, values or passwords.
  nonisolated struct Argv: Equatable, Sendable {
    let args: [Data]
    /// The database index the command runs in
    let db: Int
    /// Rows per `rows` event at most; nil lets the plugin choose
    var batchRows: Int? = nil
    /// Cells over this many bytes may be cut; nil reads them whole
    var maxCellBytes: Int? = nil
  }

  /// Safety timeouts in seconds; 0 turns one off
  nonisolated struct Settings: Codable, Equatable, Sendable {
    let statementTimeoutSeconds: Int
    let lockTimeoutSeconds: Int
    let idleTimeoutSeconds: Int
  }

  nonisolated struct Catalog: Equatable, Sendable {
    let read: EngineCatalogRead
    let args: [String: EngineJSONValue]
  }

  let id: String
  let connection: Int?
  let kind: Kind

  init(id: String, connection: Int? = nil, kind: Kind) {
    self.id = id
    self.connection = connection
    self.kind = kind
  }
}

nonisolated extension EngineRequest.Open: Codable {
  private enum CodingKeys: String, CodingKey {
    case host, port, tlsServerName, database, username, password, tls, timeoutSeconds, readOnly
    case options
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func string(_ key: CodingKeys) throws -> String {
      try container.decode(String.self, forKey: key)
    }
    self.init(
      host: try string(.host), port: try container.decode(Int.self, forKey: .port),
      tlsServerName: try string(.tlsServerName), database: try string(.database),
      username: try string(.username), password: try string(.password),
      tls: try container.decode(TLS.self, forKey: .tls),
      timeoutSeconds: try container.decode(Int.self, forKey: .timeoutSeconds),
      readOnly: try container.decode(Bool.self, forKey: .readOnly),
      options: try container.decodeIfPresent([String: EngineJSONValue].self, forKey: .options)
        ?? [:])
  }
}

nonisolated extension EngineRequest.Open: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  var description: String {
    "Open(host: \(host), port: \(port), tlsServerName: \(tlsServerName), database: \(database), "
      + "username: \(username), password: <redacted>, tls: \(tls.mode.rawValue), "
      + "timeoutSeconds: \(timeoutSeconds), readOnly: \(readOnly), options: \(options))"
  }

  var debugDescription: String { description }

  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "host": host, "port": port, "tlsServerName": tlsServerName, "database": database,
        "username": username, "password": "<redacted>", "tls": tls,
        "timeoutSeconds": timeoutSeconds, "readOnly": readOnly, "options": options,
      ])
  }
}

/// Shows the mode and whether a CA is set, never the CA text
nonisolated extension EngineRequest.Open.TLS: CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  var description: String { "TLS(mode: \(mode.rawValue), hasCA: \(caPEM != nil))" }

  var debugDescription: String { description }

  var customMirror: Mirror {
    Mirror(self, children: ["mode": mode, "hasCA": caPEM != nil])
  }
}

nonisolated extension EngineRequest.Query: Codable {
  private enum CodingKeys: String, CodingKey { case sql, binds, language, batchRows, maxCellBytes }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      sql: try container.decode(String.self, forKey: .sql),
      binds: try container.decode([String?].self, forKey: .binds),
      language: try container.decodeIfPresent(String.self, forKey: .language) ?? "sql",
      batchRows: try container.decode(Int.self, forKey: .batchRows),
      maxCellBytes: try container.decodeIfPresent(Int.self, forKey: .maxCellBytes))
  }
}

nonisolated extension EngineRequest.Argv: Codable {
  private enum CodingKeys: String, CodingKey { case args, db, batchRows, maxCellBytes }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      args: try container.decode([Argument].self, forKey: .args).map(\.bytes),
      db: try container.decode(Int.self, forKey: .db),
      batchRows: try container.decodeIfPresent(Int.self, forKey: .batchRows),
      maxCellBytes: try container.decodeIfPresent(Int.self, forKey: .maxCellBytes))
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(args.map(Argument.init), forKey: .args)
    try container.encode(db, forKey: .db)
    try container.encodeIfPresent(batchRows, forKey: .batchRows)
    try container.encodeIfPresent(maxCellBytes, forKey: .maxCellBytes)
  }

  /// The argument as text when its bytes survive a UTF-8 round trip unchanged, else nil
  fileprivate static func text(_ bytes: Data) -> String? {
    guard let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes else {
      return nil
    }
    return text
  }

  /// One argument on the wire: a JSON string, or the bytes cell `{x: base64}`
  private struct Argument: Codable {
    let bytes: Data

    init(_ bytes: Data) { self.bytes = bytes }

    init(from decoder: any Decoder) throws {
      if let text = try? decoder.singleValueContainer().decode(String.self) {
        bytes = Data(text.utf8)
      } else if case .bytes(let value) = try EngineCell(from: decoder) {
        bytes = value
      } else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "Not an argument"))
      }
    }

    func encode(to encoder: any Encoder) throws {
      if let text = EngineRequest.Argv.text(bytes) {
        var container = encoder.singleValueContainer()
        try container.encode(text)
      } else {
        try EngineCell.bytes(bytes).encode(to: encoder)
      }
    }
  }
}

/// Shows the command name and the argument count, never the other arguments
nonisolated extension EngineRequest.Argv: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  /// The first argument as text, or a placeholder when it is not UTF-8 or missing
  private var command: String { args.first.flatMap(Self.text) ?? "<bytes>" }

  var description: String { "Argv(command: \(command), argCount: \(args.count))" }

  var debugDescription: String { description }

  var customMirror: Mirror { Mirror(self, children: ["command": command, "argCount": args.count]) }
}

nonisolated extension EngineRequest.Catalog: Codable {
  private enum CodingKeys: String, CodingKey { case read, args }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      read: try container.decode(EngineCatalogRead.self, forKey: .read),
      args: try container.decodeIfPresent([String: EngineJSONValue].self, forKey: .args) ?? [:])
  }
}

nonisolated extension EngineRequest: Codable {
  private enum CodingKeys: String, CodingKey { case id, type, connection, target }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    func target() throws -> String { try container.decode(String.self, forKey: .target) }
    let kind: Kind
    switch type {
    case "hello": kind = .hello
    case "open": kind = .open(try Open(from: decoder))
    case "close": kind = .close
    case "query": kind = .query(try Query(from: decoder))
    case "command": kind = .command(try Command(from: decoder))
    case "more": kind = .more(target: try target())
    case "cancel": kind = .cancel(target: try target())
    case "settings": kind = .settings(try Settings(from: decoder))
    case "transactionState": kind = .transactionState
    case "catalog": kind = .catalog(try Catalog(from: decoder))
    case "argv": kind = .argv(try Argv(from: decoder))
    default: kind = .unknown(type)
    }
    self.init(
      id: try container.decode(String.self, forKey: .id),
      connection: try container.decodeIfPresent(Int.self, forKey: .connection), kind: kind)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(connection, forKey: .connection)
    let type: String
    switch kind {  // payload fields sit next to `id` and `type`
    case .hello: type = "hello"
    case .open(let open):
      type = "open"
      try open.encode(to: encoder)
    case .close: type = "close"
    case .query(let query):
      type = "query"
      try query.encode(to: encoder)
    case .command(let command):
      type = "command"
      try command.encode(to: encoder)
    case .more(let target):
      type = "more"
      try container.encode(target, forKey: .target)
    case .cancel(let target):
      type = "cancel"
      try container.encode(target, forKey: .target)
    case .settings(let settings):
      type = "settings"
      try settings.encode(to: encoder)
    case .transactionState: type = "transactionState"
    case .catalog(let catalog):
      type = "catalog"
      try catalog.encode(to: encoder)
    case .argv(let argv):
      type = "argv"
      try argv.encode(to: encoder)
    case .unknown(let name): type = name
    }
    try container.encode(type, forKey: .type)
  }
}

// MARK: - Events

/// One event from the plugin. `id` echoes the request; nil for an unsolicited `closed`.
nonisolated struct EngineEvent: Equatable, Sendable {
  nonisolated enum Kind: Equatable, Sendable {
    case hello(Hello)
    case opened(serverVersion: String)
    case columns([Column])
    case rows([[EngineCell]])
    case chunk(Chunk)
    /// `tag` is the statement's command tag (`INSERT`, `COMMIT`); empty when the engine has none
    case done(affectedRows: Int?, tag: String)
    case cancelled
    case settingsApplied
    /// Whether a transaction is open; nil when the plugin cannot tell
    case transactionState(open: Bool?)
    case catalog(EngineCatalogResult)
    /// Unsolicited: the session's `connection` was lost or closed
    case closed(reason: ClosedReason)
    case error(Failure)
    /// A kind this side does not know
    case unknown(String)
  }

  nonisolated struct Hello: Equatable, Sendable {
    /// `EnginePluginProtocol.version` of the plugin
    let protocolVersion: Int
    /// The bundle's version
    let version: String
    /// The engine id (`sqlserver`, `clickhouse`)
    let engine: String
    /// `sql`, or the engine's own query language
    let queryLanguage: String
    /// Bundled client libraries and their versions
    var libraries: [String: String] = [:]
    /// Additive request kinds and fields this plugin serves
    var features: [String] = []
  }

  nonisolated struct Column: Equatable, Sendable {
    nonisolated struct Origin: Codable, Equatable, Sendable {
      let schema: String
      let table: String
      let column: String
    }

    let name: String
    let type: String
    var origin: Origin? = nil
    /// A naive date-time column: its instants hold the stored wall clock in UTC
    var wallClock: Bool = false
  }

  /// One piece of the value at `column` (see `EngineChunkAssembler`)
  nonisolated struct Chunk: Codable, Equatable, Sendable {
    let column: Int
    let data: EngineCell
    let last: Bool
  }

  /// Why a connection ended. Open-ended: a newer plugin's reason still decodes, and the app
  /// reads every reason but `closed` as a loss.
  nonisolated struct ClosedReason: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    /// The server went away
    static let lost = Self(rawValue: "lost")
    /// The answer to `close`
    static let closed = Self(rawValue: "closed")
  }

  nonisolated struct Failure: Codable, Equatable, Sendable {
    let code: EngineErrorCode
    /// Plain text for the user; never holds the password
    let message: String
    /// The server's own error number or code
    var serverCode: String? = nil
  }

  let id: String?
  let connection: Int?
  let kind: Kind

  init(id: String? = nil, connection: Int? = nil, kind: Kind) {
    self.id = id
    self.connection = connection
    self.kind = kind
  }
}

nonisolated extension EngineEvent.Hello: Codable {
  private enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol"
    case version, engine, queryLanguage, libraries, features
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
      version: try container.decode(String.self, forKey: .version),
      engine: try container.decode(String.self, forKey: .engine),
      queryLanguage: try container.decode(String.self, forKey: .queryLanguage),
      libraries: try container.decodeIfPresent([String: String].self, forKey: .libraries) ?? [:],
      features: try container.decodeIfPresent([String].self, forKey: .features) ?? [])
  }
}

nonisolated extension EngineEvent.Column: Codable {
  private enum CodingKeys: String, CodingKey { case name, type, origin, wallClock }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      name: try container.decode(String.self, forKey: .name),
      type: try container.decode(String.self, forKey: .type),
      origin: try container.decodeIfPresent(Origin.self, forKey: .origin),
      wallClock: try container.decodeIfPresent(Bool.self, forKey: .wallClock) ?? false)
  }
}

nonisolated extension EngineEvent: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, connection, event, serverVersion, columns, rows, affectedRows, tag, open, read
    case result, reason
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let event = try container.decode(String.self, forKey: .event)
    let kind: Kind
    switch event {
    case "hello": kind = .hello(try Hello(from: decoder))
    case "opened":
      kind = .opened(serverVersion: try container.decode(String.self, forKey: .serverVersion))
    case "columns": kind = .columns(try container.decode([Column].self, forKey: .columns))
    case "rows": kind = .rows(try container.decode([[EngineCell]].self, forKey: .rows))
    case "chunk": kind = .chunk(try Chunk(from: decoder))
    case "done":
      kind = .done(
        affectedRows: try container.decodeIfPresent(Int.self, forKey: .affectedRows),
        tag: try container.decodeIfPresent(String.self, forKey: .tag) ?? "")
    case "cancelled": kind = .cancelled
    case "settingsApplied": kind = .settingsApplied
    case "transactionState":
      kind = .transactionState(open: try container.decodeIfPresent(Bool.self, forKey: .open))
    case "catalog": kind = .catalog(try Self.catalogResult(container))
    case "closed":
      // A missing reason is a loss, as is any reason but `closed`
      kind = .closed(
        reason: try container.decodeIfPresent(ClosedReason.self, forKey: .reason) ?? .lost)
    case "error": kind = .error(try Failure(from: decoder))
    default: kind = .unknown(event)
    }
    self.init(
      id: try container.decodeIfPresent(String.self, forKey: .id),
      connection: try container.decodeIfPresent(Int.self, forKey: .connection), kind: kind)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(id, forKey: .id)
    try container.encodeIfPresent(connection, forKey: .connection)
    let event: String
    switch kind {  // payload fields sit next to `id` and `event`
    case .hello(let hello):
      event = "hello"
      try hello.encode(to: encoder)
    case .opened(let serverVersion):
      event = "opened"
      try container.encode(serverVersion, forKey: .serverVersion)
    case .columns(let columns):
      event = "columns"
      try container.encode(columns, forKey: .columns)
    case .rows(let rows):
      event = "rows"
      try container.encode(rows, forKey: .rows)
    case .chunk(let chunk):
      event = "chunk"
      try chunk.encode(to: encoder)
    case .done(let affectedRows, let tag):
      event = "done"
      try container.encodeIfPresent(affectedRows, forKey: .affectedRows)
      try container.encode(tag, forKey: .tag)
    case .cancelled: event = "cancelled"
    case .settingsApplied: event = "settingsApplied"
    case .transactionState(let open):
      event = "transactionState"
      try container.encodeIfPresent(open, forKey: .open)
    case .catalog(let result):
      event = "catalog"
      let wire = result.wire
      try container.encode(wire.read, forKey: .read)
      try container.encode(wire.result, forKey: .result)
    case .closed(let reason):
      event = "closed"
      try container.encode(reason, forKey: .reason)
    case .error(let failure):
      event = "error"
      try failure.encode(to: encoder)
    case .unknown(let name): event = name
    }
    try container.encode(event, forKey: .event)
  }

  /// The `result` decoded as the DTO its `read` names; an unknown read keeps the raw JSON
  private static func catalogResult(
    _ container: KeyedDecodingContainer<CodingKeys>
  ) throws -> EngineCatalogResult {
    let read = try container.decode(EngineCatalogRead.self, forKey: .read)
    func result<T: Decodable>(_ type: T.Type = T.self) throws -> T {
      try container.decode(T.self, forKey: .result)
    }
    switch read {
    case .tables: return .tables(try result())
    case .views: return .views(try result())
    case .functions: return .functions(try result())
    case .procedures: return .procedures(try result())
    case .triggers: return .triggers(try result())
    case .definition:
      return .definition(try container.decodeIfPresent(String.self, forKey: .result))
    case .users: return .users(try result())
    case .roles: return .roles(try result())
    case .foreignKeys: return .foreignKeys(try result())
    case .allColumns: return .allColumns(try result())
    case .editTable:
      return .editTable(
        try container.decodeIfPresent(EngineCatalog.EditTable.self, forKey: .result))
    case .primaryKey: return .primaryKey(try result())
    case .rowCount: return .rowCount(try result())
    case .tableStructure: return .tableStructure(try result())
    case .enrichColumnTypes: return .enrichColumnTypes(try result())
    default:
      return .unknown(
        read: read,
        result: try container.decodeIfPresent(EngineJSONValue.self, forKey: .result) ?? .null)
    }
  }
}

/// Error kinds of an `error` event. Open-ended: a newer plugin's code still decodes.
nonisolated struct EngineErrorCode: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  /// A request this side could not read
  static let invalid = Self(rawValue: "invalid")
  /// Opening the connection failed
  static let connect = Self(rawValue: "connect")
  /// The server refused the statement
  static let query = Self(rawValue: "query")
  /// The plugin does not serve this request kind or catalog read
  static let unsupported = Self(rawValue: "unsupported")
  /// The connection is running another request
  static let busy = Self(rawValue: "busy")
  /// An event or value over the protocol limits
  static let tooLarge = Self(rawValue: "tooLarge")
}

// MARK: - Catalog

/// What a `catalog` request reads, and its `args`. Open-ended: a newer app's read still
/// decodes, and the plugin answers it with `unsupported`.
nonisolated struct EngineCatalogRead: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  /// No args → `[Table]`
  static let tables = Self(rawValue: "tables")
  /// No args → `[View]`
  static let views = Self(rawValue: "views")
  /// No args → `[Function]`
  static let functions = Self(rawValue: "functions")
  /// No args → `[Procedure]`
  static let procedures = Self(rawValue: "procedures")
  /// No args → `[Trigger]`
  static let triggers = Self(rawValue: "triggers")
  /// `{kind: function|procedure|trigger, schema, name, table?}` → source text or null
  static let definition = Self(rawValue: "definition")
  /// No args → `[Principal]`
  static let users = Self(rawValue: "users")
  /// No args → `[Principal]`
  static let roles = Self(rawValue: "roles")
  /// No args → `[ForeignKey]`
  static let foreignKeys = Self(rawValue: "foreignKeys")
  /// No args → `{"schema.relation": [Column]}` for every table and view
  static let allColumns = Self(rawValue: "allColumns")
  /// `{name}` (`table` or `schema.table`) → `EditTable`, or null when not editable
  static let editTable = Self(rawValue: "editTable")
  /// `{name}` → primary key column names in key order
  static let primaryKey = Self(rawValue: "primaryKey")
  /// `{schema, table}` → exact row count
  static let rowCount = Self(rawValue: "rowCount")
  /// `{schema, table}` → `TableStructure`
  static let tableStructure = Self(rawValue: "tableStructure")
  /// `{query, columns: [Column]}` → the columns with full types (precision, scale, length)
  static let enrichColumnTypes = Self(rawValue: "enrichColumnTypes")
}

/// The `result` of a `catalog` event, typed by its read
nonisolated enum EngineCatalogResult: Equatable, Sendable {
  case tables([EngineCatalog.Table])
  case views([EngineCatalog.View])
  case functions([EngineCatalog.Function])
  case procedures([EngineCatalog.Procedure])
  case triggers([EngineCatalog.Trigger])
  case definition(String?)
  case users([EngineCatalog.Principal])
  case roles([EngineCatalog.Principal])
  case foreignKeys([EngineCatalog.ForeignKey])
  case allColumns([String: [EngineCatalog.Column]])
  case editTable(EngineCatalog.EditTable?)
  case primaryKey([String])
  case rowCount(Int)
  case tableStructure(EngineCatalog.TableStructure)
  case enrichColumnTypes([EngineEvent.Column])
  case unknown(read: EngineCatalogRead, result: EngineJSONValue)

  var read: EngineCatalogRead { wire.read }

  fileprivate var wire: (read: EngineCatalogRead, result: any Encodable) {
    switch self {
    case .tables(let value): (.tables, value)
    case .views(let value): (.views, value)
    case .functions(let value): (.functions, value)
    case .procedures(let value): (.procedures, value)
    case .triggers(let value): (.triggers, value)
    case .definition(let value): (.definition, value)
    case .users(let value): (.users, value)
    case .roles(let value): (.roles, value)
    case .foreignKeys(let value): (.foreignKeys, value)
    case .allColumns(let value): (.allColumns, value)
    case .editTable(let value): (.editTable, value)
    case .primaryKey(let value): (.primaryKey, value)
    case .rowCount(let value): (.rowCount, value)
    case .tableStructure(let value): (.tableStructure, value)
    case .enrichColumnTypes(let value): (.enrichColumnTypes, value)
    case .unknown(let read, let value): (read, value)
    }
  }
}

/// Engine-neutral catalog records. Optional fields may be left out by an engine that lacks them;
/// every other field is required, and a record without one makes the `catalog` event unreadable.
/// Beyond names and schemas, that is: `Column.type`, `Trigger.timing` and `events`, every
/// `ForeignKey` column list, `EditTable.columns` and `primaryKeyColumns`, `TableStructure.columns`,
/// `indexes` and `constraints`, `StructureColumn.dataType` and `isNullable`,
/// `Generated.isStored`, `Index.keys`, `isUnique` and `isPrimary`, `Constraint.kind` and
/// `columns`, and `Reference.columns`.
nonisolated enum EngineCatalog {
  nonisolated struct Table: Codable, Equatable, Sendable {
    let schema: String
    let name: String
    var rowCount: Int? = nil
    var isTemporary: Bool? = nil
  }

  nonisolated struct View: Codable, Equatable, Sendable {
    let schema: String
    let name: String
    var definition: String? = nil
  }

  nonisolated struct Column: Codable, Equatable, Sendable {
    let name: String
    let type: String
    var isNullable: Bool? = nil
    var isPrimaryKey: Bool? = nil
    var isIdentity: Bool? = nil
    var isUnique: Bool? = nil
    var isGenerated: Bool? = nil
  }

  nonisolated struct Function: Codable, Equatable, Sendable {
    let schema: String
    let name: String
    var returnType: String? = nil
    /// Argument list as display text
    var arguments: String? = nil
  }

  nonisolated struct Procedure: Codable, Equatable, Sendable {
    let schema: String
    let name: String
    var arguments: String? = nil
  }

  nonisolated struct Trigger: Codable, Equatable, Sendable {
    let schema: String
    let table: String
    let name: String
    /// `BEFORE`, `AFTER` or `INSTEAD OF`
    let timing: String
    /// `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`
    let events: [String]
    var enabled: Bool? = nil
  }

  /// A user or role
  nonisolated struct Principal: Codable, Equatable, Sendable {
    let name: String
    var canLogin: Bool? = nil
    var isSuperuser: Bool? = nil
    var canCreateDB: Bool? = nil
    var canCreateRole: Bool? = nil
    var connectionLimit: Int? = nil
    var members: [String]? = nil
  }

  nonisolated struct ForeignKey: Codable, Equatable, Sendable {
    let name: String
    let sourceSchema: String
    let sourceTable: String
    let sourceColumns: [String]
    let targetSchema: String
    let targetTable: String
    /// Matches `sourceColumns` position by position
    let targetColumns: [String]
    /// `NO ACTION`, `RESTRICT`, `CASCADE`, `SET NULL` or `SET DEFAULT`; nil is NO ACTION
    var onUpdate: String? = nil
    var onDelete: String? = nil
  }

  /// The table an inline edit targets
  nonisolated struct EditTable: Codable, Equatable, Sendable {
    let schema: String
    let name: String
    /// Every column in table order
    let columns: [String]
    /// In key order; empty when the table has no primary key
    let primaryKeyColumns: [String]
    /// Columns the server computes, never written
    var generatedColumns: [String]? = nil
  }

  nonisolated struct TableStructure: Codable, Equatable, Sendable {
    let schema: String
    let name: String
    var comment: String? = nil
    /// In table order
    let columns: [StructureColumn]
    /// Every index, including those backing a primary key or unique constraint
    let indexes: [Index]
    let constraints: [Constraint]
  }

  nonisolated struct StructureColumn: Codable, Equatable, Sendable {
    let name: String
    /// The type as the engine displays it
    let dataType: String
    let isNullable: Bool
    /// Raw DEFAULT expression text
    var defaultExpression: String? = nil
    /// `autoIncrement`, `always` or `byDefault`
    var identity: String? = nil
    var generated: Generated? = nil
    var comment: String? = nil
    var collation: String? = nil
  }

  nonisolated struct Generated: Codable, Equatable, Sendable {
    /// Raw expression text
    var expression: String? = nil
    /// STORED; false is VIRTUAL
    let isStored: Bool
  }

  nonisolated struct Index: Codable, Equatable, Sendable {
    let name: String
    /// Key parts in order
    let keys: [IndexKey]
    let isUnique: Bool
    let isPrimary: Bool
    /// `btree`, `clustered`, ... when the engine has more than one kind
    var method: String? = nil
    /// Raw WHERE text of a partial (filtered) index
    var predicate: String? = nil
  }

  /// A column, or an expression (raw text) when `column` is nil
  nonisolated struct IndexKey: Codable, Equatable, Sendable {
    var column: String? = nil
    var expression: String? = nil
    var descending: Bool? = nil
  }

  nonisolated struct Constraint: Codable, Equatable, Sendable {
    /// Nil when the engine does not name it
    var name: String? = nil
    /// `primaryKey`, `unique`, `foreignKey` or `check`
    let kind: String
    /// Constrained columns in key order; empty for a table-level check
    let columns: [String]
    /// Raw CHECK expression text
    var check: String? = nil
    /// The referenced table of a foreign key
    var references: Reference? = nil
  }

  nonisolated struct Reference: Codable, Equatable, Sendable {
    let schema: String
    let table: String
    /// Matches `Constraint.columns` position by position
    let columns: [String]
    var onUpdate: String? = nil
    var onDelete: String? = nil
  }
}
