// ClickHouseDriverTests.swift
// The ClickHouse driver against a URLProtocol stub server (no network, no database): typed rows,
// exceptions after rows, cancel, credentials, the plain-HTTP host rule, binds, settings and the
// certificate check.
// Each test uses its own port, so tests running in parallel never share a stub.

import Foundation
import Security
import Testing

// MARK: - Stub server

/// One request as the stub saw it
nonisolated private struct StubRequest: Sendable {
  let url: URL
  let headers: [String: String]
  let sql: String

  var parameters: [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
  }
}

/// What the stub answers: status, headers, body; `holds` keeps the reply open (a long query)
nonisolated struct StubReply: Sendable {
  var status = 200
  var headers: [String: String] = [:]
  var body = ""
  var holds = false
}

/// The answers of one port, and the requests it got
nonisolated private final class StubServer: @unchecked Sendable {
  private static let registry = NSLock()
  nonisolated(unsafe) private static var servers: [Int: StubServer] = [:]

  let answer: @Sendable (StubRequest) -> StubReply
  private let lock = NSLock()
  private var received: [StubRequest] = []

  /// A server on `port` answering `SELECT version()`, `KILL QUERY` and, for anything else,
  /// `answer`
  @discardableResult
  static func start(
    port: Int, answer: @escaping @Sendable (StubRequest) -> StubReply
  )
    -> StubServer
  {
    let server = StubServer { request in
      if request.sql == "SELECT version()" {
        return StubReply(body: "[\"version()\"]\n[\"String\"]\n[\"24.8.4.13\"]\n")
      }
      if request.sql.hasPrefix("KILL QUERY") { return StubReply() }
      return answer(request)
    }
    registry.withLock { servers[port] = server }
    return server
  }

  private init(answer: @escaping @Sendable (StubRequest) -> StubReply) {
    self.answer = answer
  }

  static func server(port: Int?) -> StubServer? {
    registry.withLock { port.flatMap { servers[$0] } }
  }

  var requests: [StubRequest] { lock.withLock { received } }

  func record(_ request: StubRequest) {
    lock.withLock { received.append(request) }
  }
}

nonisolated private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let server = StubServer.server(port: url.port) else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let stubRequest = StubRequest(
      url: url, headers: request.allHTTPHeaderFields ?? [:], sql: Self.body(of: request))
    server.record(stubRequest)
    let reply = server.answer(stubRequest)
    let headers = ["Content-Type": "application/json; charset=UTF-8"].merging(reply.headers) {
      $1
    }
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)
    else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
    if !reply.holds { client?.urlProtocolDidFinishLoading(self) }
  }

  override func stopLoading() {}

  /// The SQL: URLSession hands a protocol the body as a stream
  private static func body(of request: URLRequest) -> String {
    if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return String(decoding: data, as: UTF8.self)
  }
}

// MARK: - Helpers

nonisolated private let driver = ClickHouseDriver {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubURLProtocol.self]
  return configuration
}

nonisolated private func openRequest(
  host: String = "127.0.0.1", port: Int, mode: EngineRequest.Open.TLS.Mode = .off,
  username: String = "analyst", password: String = "s3cr+t&pw", readOnly: Bool = false
) -> EngineRequest.Open {
  EngineRequest.Open(
    host: host, port: port, tlsServerName: host, database: "shop", username: username,
    password: password, tls: .init(mode: mode), timeoutSeconds: 5, readOnly: readOnly,
    options: [:])
}

nonisolated private func connect(_ open: EngineRequest.Open) throws -> ClickHouseConnection {
  let connection = try driver.connect(open)
  return try #require(connection as? ClickHouseConnection)
}

/// Every row of `sql`
nonisolated private func rows(
  of sql: String, on connection: ClickHouseConnection, binds: [String?] = []
) throws -> (columns: [EngineEvent.Column], rows: [[EngineCell]]) {
  connection.resetInterrupt()
  try connection.execute(sql, binds: binds)
  defer { connection.discardResults() }
  let columns = try connection.nextResult() ?? []
  var rows: [[EngineCell]] = []
  while let row = try connection.nextRow() { rows.append(row) }
  #expect(try connection.nextResult() == nil)
  return (columns, rows)
}

/// A reply in the driver's format
nonisolated private func reply(_ lines: String...) -> StubReply {
  StubReply(body: lines.map { $0 + "\n" }.joined())
}

// MARK: - Certificate fixtures

/// Throwaway public certificates (no keys kept): a CA, a server certificate it issued for
/// `ch.test` (valid 2026-11-11 to 2029-01-19), and an unrelated CA
nonisolated private enum Fixture {
  static let ca = """
    -----BEGIN CERTIFICATE-----
    MIIDJTCCAg2gAwIBAgIUXO537jX9LlFK8828f5SLwXy9SwcwDQYJKoZIhvcNAQEL
    BQAwGjEYMBYGA1UEAwwPVGVzdCBGaXh0dXJlIENBMB4XDTI2MTExMTAxMDMxOFoX
    DTI5MDExOTAxMDMxOFowGjEYMBYGA1UEAwwPVGVzdCBGaXh0dXJlIENBMIIBIjAN
    BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtavj+KN1/5D8RnrDnMsP+3h1JGgQ
    lDhoOBy+M21doJtvpyXv77+50X62y+Qef06W+XRyozN1zL0RPRu8D+2rRV39QAyF
    sD50vwg6voVE/vxOLnyDEDikqlzEJdfwWEt9Y/exAF2JVLwo6dAAcBJb+KzosdrK
    FZGS6khwGGYlLPRe1zeXV4CsMmaeq5bAaBqr8V6VURQqwTRLz9q7j0aYMDfe5RC9
    pGDrfj6jS46R2riLkbdIjOxVTJTFcwjxvlDdVTENAStkile3QqPU58yH9tcJTDkt
    l/WefFqzog23vJXsmV20nVdHcAaWiZjwVv8nAXwsRK92qQUYVf5LKQlddwIDAQAB
    o2MwYTAdBgNVHQ4EFgQUktqw6FqAlvc7EFOs9b8K13tPNu0wHwYDVR0jBBgwFoAU
    ktqw6FqAlvc7EFOs9b8K13tPNu0wDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8E
    BAMCAQYwDQYJKoZIhvcNAQELBQADggEBAHsPz+X+JA7q3gXpDuhQdbIYDDpStZ9G
    PHGkzMQzJ0CUueoLKnd4BvaCxdcjD03ayJxom55sndvJk8eciUEvaROT+rYA+bMn
    Jfibw2Q9LqyMgsw6bhsoLa1U1+38F9wwG7OyGZ8DmLVQ3VTuZXv83C/LddQnwpY7
    egePxYjhpUcZF9A2MNSc2in/sb9R2vVzzGnWmvU6+fIaTS1G+9yDDV+5DqIHNvCE
    ra4Qy37Y3sxyTCWuiE/UOcmAk1RR8yoHckxP20AuYzCyqTEaQ4etiFCnAQEEwcWT
    zjUP4fZBC0zMdBlftxCcBTVQKggTD3k6j404WT5w+Qz45trdL21NVNk=
    -----END CERTIFICATE-----
    """
  static let server = """
    -----BEGIN CERTIFICATE-----
    MIIDMjCCAhqgAwIBAgIBAjANBgkqhkiG9w0BAQsFADAaMRgwFgYDVQQDDA9UZXN0
    IEZpeHR1cmUgQ0EwHhcNMjYxMTExMDEwMzE4WhcNMjkwMTE5MDEwMzE4WjASMRAw
    DgYDVQQDDAdjaC50ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
    oWZBQfmuFyod1TZqGmJXEWtfKS6xAMffCgSQqkgH+uRxz0HA2ZwhfLmqP0J/x7tU
    d/8ekChSEsqbjiJZzQpUdZFDNn2Ojh40YDdjx/eh3MR87aqDwxeaytgG8abDquDv
    /Js1WkS32wu4owaun7fRD+saZROSIq5wv/Q1gaXLlj8MmyQ+kav2njeDj56bzJDA
    4MI6DFtl62WZlng24J9JoLeFA+g7jueelT8J9OpCXmTKH6Aa1Iw1LiBdGKrKMiC4
    eaiJnLjCxALiAjpne4l2lEdllD849ax5oGPr2RaO+33bT44agFcUr8fUEvuXEAhh
    vOQ+NDK4T50OQYjG95wRswIDAQABo4GKMIGHMBIGA1UdEQQLMAmCB2NoLnRlc3Qw
    EwYDVR0lBAwwCgYIKwYBBQUHAwEwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMC
    BaAwHQYDVR0OBBYEFGmQTjQHMWHe30FhpaC2KXnXLdOAMB8GA1UdIwQYMBaAFJLa
    sOhagJb3OxBTrPW/Ctd7TzbtMA0GCSqGSIb3DQEBCwUAA4IBAQBatuM3xZYjI/jv
    ytFnu/ialHCUwFuY155sdJP8VvpueI/RNIZlxTL3oA4vBjwpNXlW1rH2y1FU6e8h
    wwTI5ai/T8Hh84qUoKvfUqtYUyjU/8Eh5LB/+eBuzm28NmoIlJcb6D2XaCXCC+CP
    vwgEtoRRqBqnfLPE+hqPnqsJb2ta+od5rfokJhdcL4fd7yHvuzjhWk9kfaXyROX2
    psAUhnQiN72OrOYoAGg4Iu97JmZonUZfbR4ALt8qyw0nU+dvb/mfY5MXN09LO7aZ
    Fa1Kl6/x4ga35D2YeCgdFSJYlzESLw80mE8LRUjL/h33JEnWa/W/CVsJEtGBYNZs
    OHQwU3Af
    -----END CERTIFICATE-----
    """
  static let otherCA = """
    -----BEGIN CERTIFICATE-----
    MIIDMTCCAhmgAwIBAgIUGHLEhEMtkFmWON9BCb51G9oTqTowDQYJKoZIhvcNAQEL
    BQAwIDEeMBwGA1UEAwwVVGVzdCBGaXh0dXJlIE90aGVyIENBMB4XDTI2MTExMTAx
    MDMxOFoXDTI5MDExOTAxMDMxOFowIDEeMBwGA1UEAwwVVGVzdCBGaXh0dXJlIE90
    aGVyIENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2hFV/V6DQouZ
    9sf5Rxdjy3sQtO3IzJbC4d6aTUGgAIno4bpmZ3kAeMYcFwLCABMJDDs1CbHp/WUj
    8G71UMxEd3Cix+MM/Iwztg4i031mjVF2/JcGTs0N0/eItFtUGXLSz3CVgBS1jKzO
    A9WEoJdkU5an8qWbwEtNdvmF80Ju2v0tsPQdSBNr3U7bK5ckSVyCL46J0n37uYK/
    Z1hf1LUtMn67I1ttjUqF+boS5F8lefISxPBpbzB2hps3ZOOFUH3jN0bNeaPM4zcJ
    p2omPA1HB9L1E41RtuCEHoKjuQGYZK+YNia1e2p9Ac+gRKHYNdihYhaUnIA17sw5
    RNmydWWZcQIDAQABo2MwYTAdBgNVHQ4EFgQUKG1X5UhDbebou1J6qxBHTgCz6Nww
    HwYDVR0jBBgwFoAUKG1X5UhDbebou1J6qxBHTgCz6NwwDwYDVR0TAQH/BAUwAwEB
    /zAOBgNVHQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggEBAKycd91veMpAp2na
    Ptlhpnesgew963JORaviB8QrvSrU/9wksyrlhc3hxnJzfgl29x4DRZPnPj3NsFlu
    7iJy1lLBdn2Jt3bbgsEjziKMtL/CkBK7ikIbqSSuzvHVNyxtExjCUX7Vd9AM9b8K
    0DG5WFk+6hRg2YtgEuFqNlnHzW+QoKIC5CJObn+zxQ8k8uKo6hH5P+4afDy1J2UK
    ZSSA2LdyNFPZ/LtneJcfPlZFROccmFlCAgRA/lHc4jBe3I8kmgt54SbO5HmRbk/z
    5oXEdvnUXLpFudZ2KjfEDtHFO1pir8mccJnszRg82NsU+Oz69WAkfDypFxA5WI1b
    yogB79Y=
    -----END CERTIFICATE-----
    """
  /// Inside every certificate's validity
  static let verifyDate = Date(timeIntervalSince1970: 1_811_808_000)  // 2027-06-01

  static func certificate(_ pem: String) throws -> SecCertificate {
    try #require(ClickHouseEndpoint.certificates(fromPEM: pem).first)
  }
}

// MARK: - Tests

@Suite struct ClickHouseDriverTests {

  @Test func typedRowsStream() throws {
    StubServer.start(port: 19001) { _ in
      reply(
        #"["n","maybe","name","price","tags","at","ratio","ok"]"#,
        #"["UInt8","Nullable(Int32)","LowCardinality(String)","Decimal(10, 2)","Array(String)","DateTime","Float64","Bool"]"#,
        #"[1,null,"a\tb é","12.50",["x","y"],"2024-01-02T03:04:05Z",0.5,true]"#,
        #"[2,7,"c","-0.01",[],"2024-01-02T03:04:06Z","inf",false]"#)
    }
    let connection = try connect(openRequest(port: 19001))
    defer { connection.close() }
    let result = try rows(of: "SELECT * FROM t", on: connection)
    #expect(
      result.columns.map(\.name) == ["n", "maybe", "name", "price", "tags", "at", "ratio", "ok"])
    #expect(result.columns[1].type == "Nullable(Int32)")
    #expect(
      result.rows == [
        [
          .int(1), .null, .text("a\tb é"), .decimal("12.50"), .json(#"["x","y"]"#),
          .date("2024-01-02T03:04:05Z"), .double(0.5), .bool(true),
        ],
        [
          .int(2), .int(7), .text("c"), .decimal("-0.01"), .json("[]"),
          .date("2024-01-02T03:04:06Z"), .double(.infinity), .bool(false),
        ],
      ])
  }

  /// `count()` (UInt64) must be an int for the data viewer's total; wider values stay exact
  @Test func integerWidths() throws {
    StubServer.start(port: 19002) { _ in
      reply(
        #"["count()","u","i","w"]"#, #"["UInt64","UInt64","Int64","Int128"]"#,
        #"["42","18446744073709551615","-9223372036854775808","-170141183460469231731687303715884105728"]"#
      )
    }
    let connection = try connect(openRequest(port: 19002))
    defer { connection.close() }
    #expect(
      try rows(of: "SELECT count(), u, i, w", on: connection).rows == [
        [
          .int(42), .decimal("18446744073709551615"), .int(Int.min),
          .decimal("-170141183460469231731687303715884105728"),
        ]
      ])
  }

  /// After rows: plain text (servers since 25.11), the same in a reply left open (read without
  /// waiting for more), and a last JSON row (servers 23.9 to 25.10); before any: an error status
  /// with X-ClickHouse-Exception-Code
  @Test(arguments: [
    (
      19004,
      reply(
        #"["n"]"#, #"["UInt8"]"#, "[1]", "[2]",
        "Code: 395. DB::Exception: boom. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO) (version 24.8.4.13)"),
      "395"
    ),
    (
      19029,
      StubReply(
        body:
          "[\"n\"]\n[\"UInt8\"]\n[1]\nCode: 395. DB::Exception: boom. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO)\n",
        holds: true),
      "395"
    ),
    (
      19005,
      reply(
        #"["n"]"#, #"["String"]"#, #"["a"]"#,
        #"["Code: 395. DB::Exception: boom. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO)"]"#),
      "395"
    ),
    (
      19006,
      StubReply(
        status: 400, headers: ["X-ClickHouse-Exception-Code": "62"],
        body: "Code: 62. DB::Exception: boom: syntax error. (SYNTAX_ERROR)\n"),
      "62"
    ),
  ])
  func serverExceptionsFailTheQuery(port: Int, answer: StubReply, code: String) throws {
    StubServer.start(port: port) { _ in answer }
    let connection = try connect(openRequest(port: port))
    defer { connection.close() }
    let error = #expect(throws: EngineFailure.self) {
      try connection.execute("SELECT throwIf(n = 3) FROM t")
      _ = try connection.nextResult()
      while try connection.nextRow() != nil {}
    }
    #expect(error?.serverCode == code)
    #expect(error?.message.contains("boom") == true)
  }

  @Test func cancelKillsTheQueryOutsideTheSession() throws {
    let server = StubServer.start(port: 19007) { _ in
      var answer = reply(#"["n"]"#, #"["UInt8"]"#, "[1]")
      answer.holds = true
      return answer
    }
    let connection = try connect(openRequest(port: 19007))
    defer { connection.close() }
    connection.resetInterrupt()
    try connection.execute("SELECT sleepEachRow(1) FROM numbers(100)")
    _ = try connection.nextResult()
    #expect(try connection.nextRow() == [.int(1)])

    connection.interrupt()
    #expect(throws: EngineFailure.self) { _ = try connection.nextRow() }
    connection.discardResults()  // waits for the server to confirm the kill

    let requests = server.requests
    let query = try #require(requests.first { $0.sql.hasPrefix("SELECT sleepEachRow") })
    let kill = try #require(requests.first { $0.sql.hasPrefix("KILL QUERY") })
    #expect(kill.sql == "KILL QUERY WHERE query_id = {id:String} SYNC")
    #expect(kill.parameters["param_id"] == query.parameters["query_id"])
    #expect(query.parameters["query_id"]?.isEmpty == false)
    #expect(query.parameters["session_id"] != nil)
    #expect(kill.parameters["session_id"] == nil)
    #expect(kill.headers["X-ClickHouse-User"] == "analyst")
  }

  @Test func credentialsTravelOnlyInHeaders() throws {
    let server = StubServer.start(port: 19008) { _ in reply(#"["n"]"#, #"["UInt8"]"#, "[1]") }
    let connection = try connect(openRequest(port: 19008))
    defer { connection.close() }
    _ = try rows(of: "SELECT 1", on: connection)
    let requests = server.requests
    #expect(requests.count == 2)
    for request in requests {
      let url = request.url.absoluteString
      #expect(!url.contains("analyst"))
      #expect(!url.contains("s3cr"))
      #expect(request.parameters["user"] == nil)
      #expect(request.parameters["password"] == nil)
      #expect(request.headers["X-ClickHouse-User"] == "analyst")
      #expect(request.headers["X-ClickHouse-Key"] == "s3cr+t&pw")
      #expect(request.headers["Authorization"] == nil)
    }
  }

  /// Public hosts, and malformed ones that only look local (a hex first group, a `.local`
  /// suffix after a path or user part, an octal-looking IPv4, a mapped public IPv4)
  @Test(arguments: [
    "clickhouse.example.com", "8.8.8.8", "[2001:db8::1]", "fc00:evil.example",
    "evil.example/.local", "x@evil.example#.local", "010.0.0.1", "::ffff:8.8.8.8",
  ])
  func plainHTTPToAPublicHostIsRefused(host: String) throws {
    let error = #expect(throws: EngineFailure.self) {
      _ = try driver.connect(openRequest(host: host, port: 19009))
    }
    #expect(error?.code == .connect)
    #expect(error?.message == "Use HTTPS (Verify full) for this server")
  }

  @Test(arguments: [
    ("127.0.0.1", 19010), ("192.168.1.20", 19011), ("localhost", 19023), ("box.local", 19024),
    ("::1", 19025), ("::ffff:127.0.0.1", 19026), ("fe80::1%en0", 19027),
  ])
  func plainHTTPToALocalHostOpens(host: String, port: Int) throws {
    let server = StubServer.start(port: port) { _ in StubReply() }
    let connection = try connect(openRequest(host: host, port: port))
    defer { connection.close() }
    #expect(connection.serverVersion == "24.8.4.13 (http)")
    #expect(server.requests.first?.url.scheme == "http")
  }

  /// No TLS mode falls back to plain HTTP, the weakest (request) included
  @Test(arguments: [(EngineRequest.Open.TLS.Mode.request, 19013), (.verifyFull, 19014)])
  func tlsModesUseHTTPS(mode: EngineRequest.Open.TLS.Mode, port: Int) throws {
    let server = StubServer.start(port: port) { _ in StubReply() }
    let connection = try connect(
      openRequest(host: "clickhouse.example.com", port: port, mode: mode))
    defer { connection.close() }
    #expect(connection.serverVersion == "24.8.4.13 (https)")
    #expect(server.requests.allSatisfy { $0.url.scheme == "https" })
  }

  @Test(arguments: [(true, 19018), (false, 19019)])
  func readOnlyConnectionsSendReadonly2(readOnly: Bool, port: Int) throws {
    let server = StubServer.start(port: port) { _ in StubReply() }
    let connection = try connect(openRequest(port: port, readOnly: readOnly))
    defer { connection.close() }
    _ = try rows(of: "SELECT 1", on: connection)
    #expect(server.requests.count == 2)
    for request in server.requests {
      #expect(request.parameters["readonly"] == (readOnly ? "2" : nil))
    }
  }

  /// Binds, `settings` and `catalog` through the shared handler reach this driver: binds as
  /// `param_pN` in the escaped form, the statement timeout as `max_execution_time`
  @Test func requestsRouteThroughTheHandler() async throws {
    let server = StubServer.start(port: 19020) { request in
      if request.sql.hasPrefix("SELECT database, name, total_rows") {
        return reply(
          #"["database","name","total_rows"]"#, #"["String","String","Nullable(UInt64)"]"#,
          #"["shop","orders","12"]"#)
      }
      return reply(#"["v"]"#, #"["String"]"#, #"["a"]"#)
    }
    let handler = EngineRequestHandler(driver: driver)
    let log = EventLog()
    func send(_ id: String, _ kind: EngineRequest.Kind) throws {
      handler.receive(
        try EnginePluginProtocol.encodeRequest(EngineRequest(id: id, connection: 7, kind: kind)),
        sink: log.sink)
    }
    try send("open", .open(openRequest(port: 19020)))
    try await waitUntil { log.isFinished("open") }
    try send(
      "s",
      .settings(.init(statementTimeoutSeconds: 30, lockTimeoutSeconds: 5, idleTimeoutSeconds: 60)))
    try await waitUntil { log.isFinished("s") }
    #expect(log.kinds("s") == [.settingsApplied])

    try send(
      "q",
      .query(
        .init(
          sql: "SELECT {p1:String}, {p2:Nullable(String)}, {p3:String}",
          binds: ["a+b&c", nil, "line\nbreak\\"], language: "sql", batchRows: 100)))
    try await waitUntil { log.isFinished("q") }
    #expect(log.kinds("q").last == .done(affectedRows: nil, tag: ""))
    let query = try #require(server.requests.first { $0.sql.hasPrefix("SELECT {p1") })
    #expect(query.parameters["param_p1"] == "a+b&c")
    #expect(query.parameters["param_p2"] == "\\N")
    #expect(query.parameters["param_p3"] == "line\\nbreak\\\\")
    #expect(query.parameters["max_execution_time"] == "30")

    try send("k", .catalog(.init(read: .tables, args: [:])))
    try await waitUntil { log.isFinished("k") }
    #expect(
      log.kinds("k") == [.catalog(.tables([.init(schema: "shop", name: "orders", rowCount: 12)]))])
    try send("close", .close)
  }

  /// A FORMAT clause makes another format: the query fails with a plain message, and its reply
  /// (held open here, as a long one would be) is stopped and the query killed
  @Test func otherFormatFailsAndKillsTheQuery() throws {
    let server = StubServer.start(port: 19021) { _ in
      var answer = reply("1,a", "2,b", "3,c")
      answer.holds = true
      return answer
    }
    let connection = try connect(openRequest(port: 19021))
    defer { connection.close() }
    connection.resetInterrupt()
    let error = #expect(throws: EngineFailure.self) {
      try connection.execute("SELECT * FROM numbers(1e9) FORMAT CSV")
    }
    #expect(error?.message == "Dblore reads results in its own format; remove the FORMAT clause.")
    connection.discardResults()  // as the handler does after a failure
    let query = try #require(server.requests.first { $0.sql.hasSuffix("FORMAT CSV") })
    let kill = try #require(server.requests.first { $0.sql.hasPrefix("KILL QUERY") })
    #expect(kill.parameters["param_id"] == query.parameters["query_id"])
  }

  /// Rows of another format that start like an error text are still stopped and killed
  @Test func otherFormatLookingLikeAnErrorIsKilled() throws {
    let server = StubServer.start(port: 19028) { _ in
      var answer = reply(
        "Code: 60. DB::Exception: Table shop.gone does not exist. (UNKNOWN_TABLE)\t2026-11-10",
        "Code: 81. DB::Exception: Database old does not exist. (UNKNOWN_DATABASE)\t2026-11-10")
      answer.holds = true
      return answer
    }
    let connection = try connect(openRequest(port: 19028))
    defer { connection.close() }
    connection.resetInterrupt()
    #expect(throws: EngineFailure.self) {
      try connection.execute(
        "SELECT exception, event_date FROM system.query_log WHERE exception != '' FORMAT TSV")
    }
    connection.discardResults()  // as the handler does after a failure
    let query = try #require(server.requests.first { $0.sql.hasSuffix("FORMAT TSV") })
    let kill = try #require(server.requests.first { $0.sql.hasPrefix("KILL QUERY") })
    #expect(kill.parameters["param_id"] == query.parameters["query_id"])
  }

  /// The default user's password goes as X-ClickHouse-Key even without a user name
  @Test func passwordWithoutUserNameIsSent() throws {
    let server = StubServer.start(port: 19022) { _ in StubReply() }
    let connection = try connect(openRequest(port: 19022, username: "", password: "pw"))
    defer { connection.close() }
    let probe = try #require(server.requests.first)
    #expect(probe.headers["X-ClickHouse-User"] == nil)
    #expect(probe.headers["X-ClickHouse-Key"] == "pw")
    #expect(!probe.url.absoluteString.contains("pw"))
  }

  /// The certificate check: the connection's CA and the server name must both match
  @Test(arguments: [
    ("ch.test", true, true), ("other.test", true, false), ("ch.test", false, false),
  ])
  func certificateNeedsTheCAAndTheName(serverName: String, ownCA: Bool, trusted: Bool) throws {
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates(
      try Fixture.certificate(Fixture.server), SecPolicyCreateBasicX509(), &trust)
    let serverTrust = try #require(status == errSecSuccess ? trust : nil)
    #expect(SecTrustSetVerifyDate(serverTrust, Fixture.verifyDate as CFDate) == errSecSuccess)
    let anchors = [try Fixture.certificate(ownCA ? Fixture.ca : Fixture.otherCA)]
    #expect(
      ClickHouseHTTP.evaluate(serverTrust, serverName: serverName, anchors: anchors) == trusted)
  }
}
