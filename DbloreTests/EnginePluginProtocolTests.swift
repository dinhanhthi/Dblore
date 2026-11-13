import Foundation
import Testing

@testable import Dblore

/// Guards the engine plugin protocol v1 wire contract between the app and every engine bundle:
/// field names, discriminators, the event cap, chunked cell reassembly and password redaction.
/// The golden lines pin the wire, so a field rename can't silently break an installed plugin.
@Suite struct EnginePluginProtocolTests {
  private static let open = EngineRequest.Open(
    host: "127.0.0.1", port: 1433, tlsServerName: "db.example.com", database: "app",
    username: "sa", password: "Pw-7731-secret",
    tls: .init(mode: .verifyFull, caPEM: "-----BEGIN CERTIFICATE-----"), timeoutSeconds: 10,
    readOnly: false, options: ["tdsStrict": .bool(false)])

  /// A command name, a non-UTF-8 argument and one holding `\r\n`
  private static let argvArgs: [Data] = [
    Data("SET".utf8), Data([0xFF, 0x00, 0x0D, 0x0A] + Array("FLUSHALL".utf8)),
    Data("a\r\nb".utf8),
  ]

  /// Every request kind and its exact wire line (sorted keys)
  private static let requests: [(EngineRequest, String)] = [
    (EngineRequest(id: "1", kind: .hello), #"{"id":"1","type":"hello"}"#),
    (
      EngineRequest(id: "2", connection: 1, kind: .open(open)),
      #"{"connection":1,"database":"app","host":"127.0.0.1","id":"2","options":{"tdsStrict":false},"password":"Pw-7731-secret","port":1433,"readOnly":false,"timeoutSeconds":10,"tls":{"caPEM":"-----BEGIN CERTIFICATE-----","mode":"verifyFull"},"tlsServerName":"db.example.com","type":"open","username":"sa"}"#
    ),
    (
      EngineRequest(
        id: "3", connection: 1,
        kind: .query(
          .init(
            sql: "SELECT $1", binds: [nil, "42"], language: "sql", batchRows: 1000,
            maxCellBytes: 65536))),
      #"{"batchRows":1000,"binds":[null,"42"],"connection":1,"id":"3","language":"sql","maxCellBytes":65536,"sql":"SELECT $1","type":"query"}"#
    ),
    (
      EngineRequest(
        id: "4", connection: 1, kind: .command(.init(sql: "DELETE FROM t", binds: []))),
      #"{"binds":[],"connection":1,"id":"4","sql":"DELETE FROM t","type":"command"}"#
    ),
    (
      EngineRequest(id: "5", connection: 1, kind: .more(target: "3")),
      #"{"connection":1,"id":"5","target":"3","type":"more"}"#
    ),
    (
      EngineRequest(id: "6", connection: 1, kind: .cancel(target: "3")),
      #"{"connection":1,"id":"6","target":"3","type":"cancel"}"#
    ),
    (
      EngineRequest(
        id: "7", connection: 1,
        kind: .settings(
          .init(statementTimeoutSeconds: 30, lockTimeoutSeconds: 5, idleTimeoutSeconds: 600))),
      #"{"connection":1,"id":"7","idleTimeoutSeconds":600,"lockTimeoutSeconds":5,"statementTimeoutSeconds":30,"type":"settings"}"#
    ),
    (
      EngineRequest(id: "8", connection: 1, kind: .transactionState),
      #"{"connection":1,"id":"8","type":"transactionState"}"#
    ),
    (
      EngineRequest(
        id: "9", connection: 1,
        kind: .catalog(
          .init(
            read: .tableStructure,
            args: ["schema": .string("dbo"), "table": .string("orders"), "n": .number(2)]))),
      #"{"args":{"n":2,"schema":"dbo","table":"orders"},"connection":1,"id":"9","read":"tableStructure","type":"catalog"}"#
    ),
    (
      EngineRequest(id: "10", connection: 1, kind: .close),
      #"{"connection":1,"id":"10","type":"close"}"#
    ),
    // Byte-exact arguments: valid UTF-8 (`\r\n` included) goes as text, anything else as `{x}`
    (
      EngineRequest(
        id: "11", connection: 1,
        kind: .argv(
          .init(
            args: argvArgs, db: 3, batchRows: 500, maxCellBytes: 65536))),
      #"{"args":["SET",{"x":"/wANCkZMVVNIQUxM"},"a\r\nb"],"batchRows":500,"connection":1,"db":3,"id":"11","maxCellBytes":65536,"type":"argv"}"#
    ),
  ]

  /// Every event kind and its exact wire line, every cell kind included
  private static let events: [(String, EngineEvent)] = [
    (
      #"{"engine":"sqlserver","event":"hello","features":["catalog"],"id":"1","libraries":{"FreeTDS":"1.5.4"},"protocol":1,"queryLanguage":"sql","version":"1.0.0"}"#,
      EngineEvent(
        id: "1",
        kind: .hello(
          .init(
            protocolVersion: 1, version: "1.0.0", engine: "sqlserver", queryLanguage: "sql",
            libraries: ["FreeTDS": "1.5.4"], features: ["catalog"])))
    ),
    (
      #"{"connection":1,"event":"opened","id":"2","serverVersion":"16.0.1000"}"#,
      EngineEvent(id: "2", connection: 1, kind: .opened(serverVersion: "16.0.1000"))
    ),
    (
      #"{"columns":[{"name":"id","origin":{"column":"id","schema":"dbo","table":"orders"},"type":"int","wallClock":false},{"name":"at","type":"datetime2","wallClock":true}],"event":"columns","id":"3"}"#,
      EngineEvent(
        id: "3",
        kind: .columns([
          .init(
            name: "id", type: "int", origin: .init(schema: "dbo", table: "orders", column: "id"),
            wallClock: false),
          .init(name: "at", type: "datetime2", origin: nil, wallClock: true),
        ]))
    ),
    (
      #"{"event":"rows","id":"3","rows":[[null,{"s":"a/b"},{"i":-7},{"f":1.5},{"b":true},{"j":"{\"k\":1}"},{"d":"2026-11-10T08:30:00.123456Z"},{"x":"AAH/"},{"m":"12.30"},{"c":true},{"f":"-Infinity"}]]}"#,
      EngineEvent(
        id: "3",
        kind: .rows([
          [
            .null, .text("a/b"), .int(-7), .double(1.5), .bool(true), .json(#"{"k":1}"#),
            .date("2026-11-10T08:30:00.123456Z"), .bytes(Data([0x00, 0x01, 0xFF])),
            .decimal("12.30"), .chunked, .double(-.infinity),
          ]
        ]))
    ),
    (
      #"{"column":9,"data":{"s":"abc"},"event":"chunk","id":"3","last":false}"#,
      EngineEvent(id: "3", kind: .chunk(.init(column: 9, data: .text("abc"), last: false)))
    ),
    (
      #"{"affectedRows":3,"event":"done","id":"4","tag":"DELETE"}"#,
      EngineEvent(id: "4", kind: .done(affectedRows: 3, tag: "DELETE"))
    ),
    (#"{"event":"cancelled","id":"3"}"#, EngineEvent(id: "3", kind: .cancelled)),
    (#"{"event":"settingsApplied","id":"7"}"#, EngineEvent(id: "7", kind: .settingsApplied)),
    (
      #"{"event":"transactionState","id":"8","open":true}"#,
      EngineEvent(id: "8", kind: .transactionState(open: true))
    ),
    (
      #"{"event":"catalog","id":"9","read":"tables","result":[{"name":"orders","rowCount":12,"schema":"dbo"}]}"#,
      EngineEvent(
        id: "9",
        kind: .catalog(
          .tables([.init(schema: "dbo", name: "orders", rowCount: 12, isTemporary: nil)])))
    ),
    (
      #"{"event":"catalog","id":"9","read":"definition","result":null}"#,
      EngineEvent(id: "9", kind: .catalog(.definition(nil)))
    ),
    (
      #"{"connection":1,"event":"closed","reason":"lost"}"#,
      EngineEvent(connection: 1, kind: .closed(reason: .lost))
    ),
    (
      #"{"code":"query","event":"error","id":"3","message":"Invalid object name 'x'.","serverCode":"208"}"#,
      EngineEvent(
        id: "3",
        kind: .error(.init(code: .query, message: "Invalid object name 'x'.", serverCode: "208")))
    ),
  ]

  @Test(arguments: requests)
  func requestRoundTripsThroughItsWireLine(_ request: EngineRequest, _ line: String) throws {
    let encoded = try EnginePluginProtocol.encodeRequest(request)
    #expect(String(decoding: encoded, as: UTF8.self) == line)
    #expect(try EnginePluginProtocol.decodeRequest(Data(line.utf8)) == request)
  }

  @Test(arguments: events)
  func eventRoundTripsThroughItsWireLine(_ line: String, _ event: EngineEvent) throws {
    #expect(try EnginePluginProtocol.decodeEvent(Data(line.utf8)) == event)
    let encoded = try EnginePluginProtocol.encodeEvent(event)
    #expect(String(decoding: encoded, as: UTF8.self) == line)
  }

  /// A newer peer's kinds and keys decode instead of failing: unknown request and event kinds
  /// become `.unknown`, extra keys are ignored, a `done` without a tag has an empty one, an
  /// unknown catalog read keeps its raw result, and a `closed` without a reason is a loss.
  @Test func unknownKindsAndKeysAreTolerated() throws {
    let request = try EnginePluginProtocol.decodeRequest(
      Data(#"{"id":"1","type":"explain","connection":2,"future":[1]}"#.utf8))
    #expect(request == EngineRequest(id: "1", connection: 2, kind: .unknown("explain")))
    let event = try EnginePluginProtocol.decodeEvent(
      Data(#"{"event":"progress","id":"3","percent":40}"#.utf8))
    #expect(event == EngineEvent(id: "3", kind: .unknown("progress")))
    let done = try EnginePluginProtocol.decodeEvent(
      Data(#"{"event":"done","id":"4","extra":true}"#.utf8))
    #expect(done == EngineEvent(id: "4", kind: .done(affectedRows: nil, tag: "")))
    let catalog = try EnginePluginProtocol.decodeEvent(
      Data(#"{"event":"catalog","id":"9","read":"sequences","result":[{"name":"s"}]}"#.utf8))
    let raw = EngineJSONValue.array([.object(["name": .string("s")])])
    #expect(
      catalog
        == EngineEvent(
          id: "9", kind: .catalog(.unknown(read: .init(rawValue: "sequences"), result: raw))))
    // An unsolicited `closed` with a newer reason still reaches its connection, as a loss
    let closed = try EnginePluginProtocol.decodeEvent(
      Data(#"{"connection":2,"event":"closed","reason":"shutdown"}"#.utf8))
    #expect(closed.connection == 2)
    guard case .closed(let reason) = closed.kind else {
      Issue.record("Expected closed, got \(closed.kind)")
      return
    }
    #expect(reason.rawValue == "shutdown")
    #expect(
      EnginePluginError.connectionClosed(reason).errorDescription
        == "The connection to the server was lost.")
    // A `closed` without a reason is a loss
    let bare = try EnginePluginProtocol.decodeEvent(
      Data(#"{"connection":2,"event":"closed"}"#.utf8))
    #expect(bare == EngineEvent(connection: 2, kind: .closed(reason: .lost)))
  }

  /// The app reads an event of at most 1 MiB: a valid event one byte over is refused as too
  /// large, and the plugin side refuses to encode one.
  @Test func eventOverTheSizeCapIsRefused() throws {
    let overhead = #"{"event":"rows","id":"1","rows":[[{"s":""}]]}"#.utf8.count
    func line(bytes: Int) -> Data {
      let text = String(repeating: "a", count: bytes - overhead)
      return Data(#"{"event":"rows","id":"1","rows":[[{"s":"\#(text)"}]]}"#.utf8)
    }
    let atCap = try EnginePluginProtocol.decodeEvent(
      line(bytes: EnginePluginProtocol.maxEventBytes))
    #expect(atCap.id == "1")
    #expect(throws: EngineProtocolError.tooLarge) {
      try EnginePluginProtocol.decodeEvent(line(bytes: EnginePluginProtocol.maxEventBytes + 1))
    }
    let big = EngineEvent(
      id: "1",
      kind: .rows([[.text(String(repeating: "a", count: EnginePluginProtocol.maxEventBytes))]]))
    #expect(throws: EngineProtocolError.tooLarge) { try EnginePluginProtocol.encodeEvent(big) }
  }

  /// Chunks rebuild the value a `{c:true}` cell stands for, up to `maxValueBytes`; one byte
  /// over fails as too large and drops what was gathered.
  @Test func chunkReassemblyStopsAtTheValueCap() throws {
    var assembler = EngineChunkAssembler(maxValueBytes: 11)
    try assembler.append(.init(column: 1, data: .text("abcd"), last: false))
    try assembler.append(.init(column: 1, data: .text("éfg"), last: true))
    try assembler.append(.init(column: 2, data: .bytes(Data([1, 2])), last: false))
    try assembler.append(.init(column: 2, data: .bytes(Data([3])), last: true))
    let rows = try assembler.resolve([[.int(1), .chunked, .chunked]])
    #expect(rows == [[.int(1), .text("abcdéfg"), .bytes(Data([1, 2, 3]))]])

    try assembler.append(.init(column: 1, data: .text("abcdefgh"), last: false))
    #expect(throws: EngineProtocolError.tooLarge) {
      try assembler.append(.init(column: 1, data: .text("ijkl"), last: true))
    }
    #expect(throws: EngineProtocolError.invalid(requestID: nil)) {
      try assembler.resolve([[.int(1), .chunked]])
    }
  }

  /// Untrusted chunks stay bounded: the cap also covers every value gathered at once, across
  /// columns (over it fails as too large and drops them all; a resolved value no longer counts),
  /// and a chunk names an existing column, never a negative one or one past the known count.
  @Test func chunkReassemblyBoundsWhatItGathers() throws {
    var assembler = EngineChunkAssembler(maxValueBytes: 8)
    try assembler.append(.init(column: 0, data: .text("abcde"), last: true))
    try assembler.append(.init(column: 1, data: .text("abc"), last: false))
    #expect(throws: EngineProtocolError.tooLarge) {
      try assembler.append(.init(column: 1, data: .text("d"), last: true))
    }
    #expect(throws: EngineProtocolError.invalid(requestID: nil)) {
      try assembler.resolve([[.chunked]])
    }

    try assembler.append(.init(column: 0, data: .text("abcdefgh"), last: true))
    #expect(try assembler.resolve([[.chunked]]) == [[.text("abcdefgh")]])
    try assembler.append(.init(column: 0, data: .text("abcdefgh"), last: true))
    #expect(try assembler.resolve([[.chunked]]) == [[.text("abcdefgh")]])

    #expect(throws: EngineProtocolError.invalid(requestID: nil)) {
      try assembler.append(.init(column: -1, data: .text("a"), last: true))
    }
    var counted = EngineChunkAssembler(maxValueBytes: 8, columnCount: 2)
    try counted.append(.init(column: 1, data: .text("a"), last: true))
    #expect(throws: EngineProtocolError.invalid(requestID: nil)) {
      try counted.append(.init(column: 2, data: .text("a"), last: true))
    }
  }

  /// The password and the CA travel only in the open request's JSON: no description,
  /// reflection, dump or decode error of it shows them.
  @Test func openRequestNeverShowsItsPassword() throws {
    let request = EngineRequest(id: "2", connection: 1, kind: .open(Self.open))
    var dumped = ""
    dump(request, to: &dumped)
    var dumpedOpen = ""
    dump(Self.open, to: &dumpedOpen)
    let renderings = [
      String(describing: request), String(reflecting: request), "\(request)", dumped,
      String(describing: Self.open), String(reflecting: Self.open), dumpedOpen,
    ]
    for text in renderings {
      #expect(!text.contains("Pw-7731-secret"))
      #expect(!text.contains("BEGIN CERTIFICATE"))
      #expect(text.contains("127.0.0.1"))
    }
    var dumpedTLS = ""
    dump(Self.open.tls, to: &dumpedTLS)
    for text in [String(describing: Self.open.tls), String(reflecting: Self.open.tls), dumpedTLS] {
      #expect(!text.contains("BEGIN CERTIFICATE"))
      #expect(text.contains("verifyFull"))
    }
    let broken = #"{"connection":1,"id":"2","type":"open","password":"Pw-7731-secret","port":"x"}"#
    do {
      _ = try EnginePluginProtocol.decodeRequest(Data(broken.utf8))
      Issue.record("an open request without its fields decoded")
    } catch {
      #expect(error as? EngineProtocolError == .invalid(requestID: "2"))
      #expect(!String(reflecting: error).contains("Pw-7731-secret"))
    }
  }

  /// The database index is part of every argv request: one without `db` is refused with its id.
  @Test func argvWithoutDatabaseIsInvalid() {
    let line = #"{"args":["GET","k"],"connection":1,"id":"12","type":"argv"}"#
    #expect(throws: EngineProtocolError.invalid(requestID: "12")) {
      try EnginePluginProtocol.decodeRequest(Data(line.utf8))
    }
  }

  /// Argv arguments can be keys, values or passwords: descriptions, reflection and dumps show
  /// the command name and the argument count only.
  @Test func argvRequestShowsOnlyItsCommandName() {
    let request = EngineRequest(
      id: "13", connection: 1,
      kind: .argv(.init(args: [Data("AUTH".utf8), Data("Pw-7731-secret".utf8)], db: 0)))
    #expect(String(describing: request.kind) == "argv(Argv(command: AUTH, argCount: 2))")
    var dumped = ""
    dump(request, to: &dumped)
    for text in [String(describing: request), String(reflecting: request), dumped] {
      #expect(!text.contains("Pw-7731-secret"))
      #expect(text.contains("AUTH"))
    }
  }
}
