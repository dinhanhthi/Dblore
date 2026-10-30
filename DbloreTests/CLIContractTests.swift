// CLIContractTests.swift
// The dblore command-line tool's contract with the app and with scripts: what the app sends
// (pairing, hello, tools/call, MCPResultEncoder text, refusal texts) decodes with the tool's own
// code (DbloreCLI/Core, compiled into this target), the five output formats print one fixed
// result byte for byte, the documented flags parse, and the token reaches only a server that
// proved it is Dblore on the port the tool dialed.

import CryptoKit
import Foundation
import Testing
import os

@testable import Dblore

@Suite("dblore command-line tool contract")
struct CLIContractTests {
  /// The app's /cli/* routes and /mcp JSON-RPC handler behind a `CLITransport`, as the listener
  /// runs them: `/mcp` gets caller cli only with a paired bearer. `appPort` is the port the app
  /// sees; a value other than the dialed port is a relay to another Dblore port.
  private final class AppTransport: CLITransport, Sendable {
    struct Sent: Sendable {
      let port: Int
      let path: String
      let headers: [String: String]
    }

    private let handler: MCPHTTPServer.Handler
    private let registry: MCPCLITokenRegistry
    private let appPort: Int
    private let log = OSAllocatedUnfairLock(initialState: [Sent]())

    init(pairing: MCPCLIPairingService, tools: any MCPToolCalling, appPort: Int) {
      handler = pairing.handler(next: MCPJSONRPC.handler(tools: tools))
      registry = pairing.registry
      self.appPort = appPort
    }

    var sent: [Sent] { log.withLock { $0 } }

    func post(
      port: Int, path: String, headers: [String: String], body: Data, timeout: TimeInterval
    ) async throws -> CLIHTTPResponse {
      log.withLock { $0.append(Sent(port: port, path: path, headers: headers)) }
      let bearer = headers["Authorization"].map { String($0.dropFirst("Bearer ".count)) }
      let caller: MCPCallerKind? =
        path == "/mcp" && bearer.flatMap(registry.pairedID(for:)) != nil ? .cli : nil
      let response = await handler(
        MCPHTTPRequest(
          method: "POST", path: path, headers: headers, body: body, caller: caller,
          port: appPort))
      return CLIHTTPResponse(status: response.status, body: response.body)
    }
  }

  /// Answers every tool call with `result`
  private struct FixedTools: MCPToolCalling {
    let result: MCPToolResult
    var tools: [MCPToolDefinition] { [] }
    func call(_ name: String, arguments: [String: JSONValue]) async -> MCPToolResult { result }
  }

  private static let port = 41730
  private static let connections = MCPResultEncoder.encodeConnections([
    (id: UUID(uuidString: "6F1E3C2A-0B4D-4E8F-9A1B-2C3D4E5F6A7B")!, name: "Prod", engine: "sqlite")
  ])

  /// A paired tool for `pairing`, redeemed through the app's /cli/pair on `port`
  private func paired(
    _ pairing: MCPCLIPairingService, tools: any MCPToolCalling
  ) async throws -> CLICredentials {
    let code = pairing.start(port: Self.port).code
    let transport = AppTransport(pairing: pairing, tools: tools, appPort: Self.port)
    return try await CLIClient(transport: transport).pair(code: code, port: Self.port)
  }

  // MARK: - Pairing

  @Test("The app's pairing answer decodes with the tool's decoder")
  func pairResponseDecodes() throws {
    let key = MCPTokenStoreFactory.base64URL(Array(repeating: 7, count: 32))
    let result = MCPCLIPairResult(token: "tok", proofKey: key, port: Self.port, id: "id-1")
    let credentials = try CLIClient.decodePairResponse(
      JSONEncoder().encode(result), dialedPort: Self.port)
    #expect(credentials == CLICredentials(token: "tok", proofKey: key, port: Self.port, id: "id-1"))
  }

  @Test("A pairing answer naming another port than the one dialed is refused (exit 3)")
  func pairResponseOtherPortRefused() throws {
    let key = MCPTokenStoreFactory.base64URL(Array(repeating: 7, count: 32))
    let result = MCPCLIPairResult(token: "tok", proofKey: key, port: Self.port + 1, id: "id-1")
    let failure = try #require(throws: CLIFailure.self) {
      try CLIClient.decodePairResponse(JSONEncoder().encode(result), dialedPort: Self.port)
    }
    #expect(failure.exitCode == .refused)
    #expect(failure.message.hasPrefix("The answer on port 41730 names port 41731"))
  }

  @Test("pair through the app's /cli/pair saves a pairing the app's registry accepts")
  func pairThroughApp() async throws {
    let pairing = MCPCLIPairingService(store: InMemoryMCPCLITokenStore())
    let tools = FixedTools(result: MCPToolResult(text: "[]", isError: false))
    let credentials = try await paired(pairing, tools: tools)
    #expect(credentials.port == Self.port)
    #expect(pairing.registry.pairedID(for: credentials.token) == credentials.id)
  }

  @Test("pair relayed to Dblore on another port is refused and nothing is saved")
  func pairRelayedRefused() async throws {
    let pairing = MCPCLIPairingService(store: InMemoryMCPCLITokenStore())
    let code = pairing.start(port: Self.port + 1).code
    let transport = AppTransport(
      pairing: pairing, tools: FixedTools(result: MCPToolResult(text: "[]", isError: false)),
      appPort: Self.port + 1)
    let failure = try await #require(throws: CLIFailure.self) {
      try await CLIClient(transport: transport).pair(code: code, port: Self.port)
    }
    #expect(failure.exitCode == .refused)
    #expect(failure.message.contains("names port 41731"))
  }

  // MARK: - Hello

  @Test("The app's hello proof is valid for the port it signed, not for another")
  func helloProofMatches() {
    let key = Data(repeating: 9, count: 32)
    let nonce = Data((0..<32).map { UInt8($0) })
    let proof = MCPCLIPairingService.helloProof(
      key: SymmetricKey(data: key), nonce: nonce, port: UInt16(Self.port))
    #expect(MCPCLIPairingService.helloLabel == CLIClient.helloLabel)
    #expect(CLIClient.isValidHello(proof: proof, key: key, nonce: nonce, port: UInt16(Self.port)))
    #expect(
      !CLIClient.isValidHello(proof: proof, key: key, nonce: nonce, port: UInt16(Self.port + 1)))
  }

  @Test("After a valid hello the token goes to /mcp only, and the tool text comes back")
  func helloThenTool() async throws {
    let pairing = MCPCLIPairingService(store: InMemoryMCPCLITokenStore())
    let tools = FixedTools(result: MCPToolResult(text: Self.connections, isError: false))
    let credentials = try await paired(pairing, tools: tools)
    let transport = AppTransport(pairing: pairing, tools: tools, appPort: Self.port)
    let text = try await CLIClient(transport: transport).callTool(
      "list_connections", arguments: [:], credentials: credentials, port: Self.port)
    #expect(text == Self.connections)
    #expect(transport.sent.map(\.path) == ["/cli/hello", "/mcp"])
    #expect(transport.sent[0].headers["Authorization"] == nil)
    #expect(transport.sent[1].headers["Authorization"] == "Bearer \(credentials.token)")
  }

  @Test("A hello answered for another port fails with exit 3 and the token is never sent")
  func helloOtherPortRejected() async throws {
    let pairing = MCPCLIPairingService(store: InMemoryMCPCLITokenStore())
    let tools = FixedTools(result: MCPToolResult(text: Self.connections, isError: false))
    let credentials = try await paired(pairing, tools: tools)
    // Dblore answers, but the connection reached it on another port: a relay
    let transport = AppTransport(pairing: pairing, tools: tools, appPort: Self.port + 1)
    let failure = try await #require(throws: CLIFailure.self) {
      try await CLIClient(transport: transport).callTool(
        "list_connections", arguments: [:], credentials: credentials, port: Self.port)
    }
    #expect(failure == CLIClient.anotherProgram(Self.port))
    #expect(transport.sent.map(\.path) == ["/cli/hello"])
    #expect(transport.sent.allSatisfy { $0.headers["Authorization"] == nil })
  }

  /// The app for /cli/*, then `error` instead of an answer on /mcp
  private struct FailingMCPTransport: CLITransport {
    let app: AppTransport
    let error: CLITransportError

    func post(
      port: Int, path: String, headers: [String: String], body: Data, timeout: TimeInterval
    ) async throws -> CLIHTTPResponse {
      if path == "/mcp" { throw error }
      return try await app.post(
        port: port, path: path, headers: headers, body: body, timeout: timeout)
    }
  }

  @Test(
    "No answer on /mcp after the token went out: exit 2 if Dblore stopped, else 4, no token claim",
    arguments: [
      (CLITransportError.unreachable, CLIExitCode.unavailable),
      (.timedOut, .queryFailed),
      (.failed, .queryFailed),
    ])
  func mcpLegTransportFailure(_ error: CLITransportError, exitCode: CLIExitCode) async throws {
    let pairing = MCPCLIPairingService(store: InMemoryMCPCLITokenStore())
    let tools = FixedTools(result: MCPToolResult(text: Self.connections, isError: false))
    let credentials = try await paired(pairing, tools: tools)
    let app = AppTransport(pairing: pairing, tools: tools, appPort: Self.port)
    let failure = try await #require(throws: CLIFailure.self) {
      try await CLIClient(transport: FailingMCPTransport(app: app, error: error)).callTool(
        "list_connections", arguments: [:], credentials: credentials, port: Self.port)
    }
    #expect(failure.exitCode == exitCode)
    #expect(!failure.message.contains("token"))
    #expect(app.sent.map(\.path) == ["/cli/hello"])
  }

  @Test(
    "No answer on pair or hello: exit 2 when nothing listens or in time, else another program",
    arguments: [
      (CLITransportError.unreachable, CLIExitCode.unavailable),
      (.timedOut, .unavailable),
      (.failed, .refused),
    ])
  func beforeTokenTransportFailure(_ error: CLITransportError, exitCode: CLIExitCode) async throws {
    struct Failing: CLITransport {
      let error: CLITransportError
      func post(
        port: Int, path: String, headers: [String: String], body: Data, timeout: TimeInterval
      ) async throws -> CLIHTTPResponse { throw error }
    }
    let client = CLIClient(transport: Failing(error: error))
    let pairFailure = try await #require(throws: CLIFailure.self) {
      try await client.pair(code: "ABCD1234", port: Self.port)
    }
    let helloFailure = try await #require(throws: CLIFailure.self) {
      try await client.hello(Self.credentials, port: Self.port)
    }
    #expect(pairFailure.exitCode == exitCode)
    #expect(helloFailure == pairFailure)
    if error == .failed { #expect(pairFailure == CLIClient.anotherProgram(Self.port)) }
  }

  @Test("A tool refusal from the app exits 3, a database error exits 4")
  func toolErrorsThroughApp() async throws {
    let cases: [(MCPToolResult, CLIExitCode)] = [
      (MCPToolResult(text: MCPToolError.cliReadOnly.localizedDescription, isError: true), .refused),
      (MCPToolResult(text: "no such table: orders", isError: true), .queryFailed),
    ]
    for (result, exitCode) in cases {
      let pairing = MCPCLIPairingService(store: InMemoryMCPCLITokenStore())
      let tools = FixedTools(result: result)
      let credentials = try await paired(pairing, tools: tools)
      let transport = AppTransport(pairing: pairing, tools: tools, appPort: Self.port)
      let failure = try await #require(throws: CLIFailure.self) {
        try await CLIClient(transport: transport).callTool(
          "run_query", arguments: ["connection_id": .string("Prod"), "sql": .string("x")],
          credentials: credentials, port: Self.port)
      }
      #expect(failure == CLIFailure(exitCode: exitCode, message: result.text))
    }
  }

  // MARK: - Tool text

  @Test("MCPResultEncoder rows decode with the tool's decoder, every cell kind")
  func rowsDecode() throws {
    let long = String(repeating: "x", count: MCPResultEncoder.maxCellCharacters + 1)
    let bigBlob = Data(repeating: 7, count: 1_501)
    let read = MCPReadResult(
      columns: [MCPResultColumn(name: "a", type: "int"), MCPResultColumn(name: "b", type: "text")],
      rows: [
        [.null, .bool(true)],
        [.int(1), .int(42)],
        [.double(2.5), .string("a,\"b\"\n\tc\r")],
        [.string(long), .data(Data([1, 2, 3]))],
        [.data(bigBlob), .string("")],
      ],
      rowsTruncated: true)
    let text = MCPResultEncoder.encodeRows(read)
    let result = try CLIOutput.decodeRows(text)
    #expect(
      result.columns == [CLIColumn(name: "a", type: "int"), CLIColumn(name: "b", type: "text")])
    #expect(
      result.rows == [
        [.null, .bool(true)],
        [.int(1), .int(42)],
        [.double(2.5), .text("a,\"b\"\n\tc\r")],
        [
          .cutText(String(repeating: "x", count: MCPResultEncoder.maxCellCharacters)),
          .binary(base64: "AQID", bytes: 3),
        ],
        [.cutBinary(base64: Data(bigBlob.prefix(1_500)).base64EncodedString()), .text("")],
      ])
    #expect(result.rowCount == 5)
    #expect(result.rowsTruncated)
    #expect(result.truncatedCells == 2)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(object["notice"] as? String == CLIOutput.dataNotice)
  }

  @Test("The tool's data notice is the app's")
  func dataNoticeMatches() {
    #expect(CLIOutput.dataNotice == MCPResultEncoder.dataNotice)
  }

  @Test("list_connections decodes with the tool's decoder")
  func connectionsDecode() throws {
    let id = UUID()
    let text = MCPResultEncoder.encodeConnections([
      (id: id, name: "Prod \"main\", EU", engine: "postgresql"),
      (id: id, name: "", engine: "mongodb"),
    ])
    #expect(
      try CLIOutput.decodeConnections(text) == [
        CLIConnection(id: id.uuidString, name: "Prod \"main\", EU", engine: "postgresql"),
        CLIConnection(id: id.uuidString, name: "", engine: "mongodb"),
      ])
  }

  // MARK: - Output formats

  /// Two rows covering every cell kind; text with a comma, quotes, a tab, LF and a backslash
  private static let fixed = CLIQueryResult(
    columns: ["id", "name", "flag", "score", "data"].map { CLIColumn(name: $0, type: "t") },
    rowCount: 2,
    rows: [
      [.int(1), .text("a,b \"q\""), .bool(true), .double(2.5), .binary(base64: "AQID", bytes: 3)],
      [.null, .text("x\ty\nz\\"), .bool(false), .cutText("ab"), .cutBinary(base64: "AAAA")],
    ],
    rowsTruncated: false, truncatedCells: 0)

  @Test("csv: RFC 4180 quoting and CRLF line ends")
  func csvExact() {
    #expect(
      CLIOutput.render(Self.fixed, format: .csv)
        == "id,name,flag,score,data\r\n"
        + "1,\"a,b \"\"q\"\"\",true,2.5,AQID\r\n"
        + ",\"x\ty\nz\\\",false,ab,AAAA\r\n")
  }

  @Test("tsv: backslash, tab, LF and CR escaped, LF line ends")
  func tsvExact() {
    #expect(
      CLIOutput.render(Self.fixed, format: .tsv)
        == "id\tname\tflag\tscore\tdata\n"
        + "1\ta,b \"q\"\ttrue\t2.5\tAQID\n"
        + "\tx\\ty\\nz\\\\\tfalse\tab\tAAAA\n")
    #expect(CLIOutput.tsvField("a\rb") == "a\\rb")
  }

  @Test("json: one array of row objects in column order")
  func jsonExact() {
    #expect(
      CLIOutput.render(Self.fixed, format: .json)
        == #"[{"id":1,"name":"a,b \"q\"","flag":true,"score":2.5,"#
        + #""data":{"base64":"AQID","bytes":3}},"#
        + #"{"id":null,"name":"x\ty\nz\\","flag":false,"score":{"truncated":true,"value":"ab"},"#
        + #""data":{"base64":"AAAA","truncated":true}}]"# + "\n")
    #expect(CLIOutput.uniqueKeys(["a", "a", "a_2"]) == ["a", "a_3", "a_2"])
  }

  @Test("jsonl: one row object per line")
  func jsonlExact() {
    #expect(
      CLIOutput.render(Self.fixed, format: .jsonl)
        == #"{"id":1,"name":"a,b \"q\"","flag":true,"score":2.5,"#
        + #""data":{"base64":"AQID","bytes":3}}"# + "\n"
        + #"{"id":null,"name":"x\ty\nz\\","flag":false,"score":{"truncated":true,"value":"ab"},"#
        + #""data":{"base64":"AAAA","truncated":true}}"# + "\n")
  }

  @Test("table: aligned columns, NULL shown, control characters escaped")
  func tableExact() {
    #expect(
      CLIOutput.render(Self.fixed, format: .table)
        == "id    name      flag   score  data\n"
        + "----  --------  -----  -----  ----\n"
        + "1     a,b \"q\"   true   2.5    AQID\n"
        + #"NULL  x\ty\nz\  false  ab     AAAA"# + "\n")
  }

  @Test(
    "terminalSafe escapes controls, C1, text-direction, zero-width, BOM, separators and tags",
    arguments: [
      ("a\u{1B}[31mb", #"a\u{1B}[31mb"#),
      ("a\u{7F}b", #"a\u{7F}b"#),
      ("a\u{9B}b", #"a\u{9B}b"#),
      ("a\u{202E}b", #"a\u{202E}b"#),
      ("a\u{2066}b", #"a\u{2066}b"#),
      ("a\u{200B}b", #"a\u{200B}b"#),
      ("a\u{200D}b", #"a\u{200D}b"#),
      ("a\u{2060}b", #"a\u{2060}b"#),
      ("a\u{FEFF}b", #"a\u{FEFF}b"#),
      ("a\u{2028}b\u{2029}", #"a\u{2028}b\u{2029}"#),
      ("a\u{E0001}b", #"a\u{E0001}b"#),
      ("a\tb\nc\rd", #"a\tb\nc\rd"#),
      ("plain é 漢字", "plain é 漢字"),
    ])
  func terminalSafeEscapes(_ text: String, expected: String) {
    #expect(CLIOutput.terminalSafe(text) == expected)
    let result = CLIQueryResult(
      columns: [CLIColumn(name: "v", type: "text")], rowCount: 1, rows: [[.text(text)]],
      rowsTruncated: false, truncatedCells: 0)
    let rule = String(repeating: "-", count: max(1, expected.count))
    #expect(CLIOutput.render(result, format: .table) == "v\n\(rule)\n\(expected)\n")
  }

  /// A value with ESC, a C1 CSI, a right-to-left override, a line separator, a tab, LF and CR
  private static let hostile = CLIQueryResult(
    columns: [CLIColumn(name: "v\u{1B}", type: "text")], rowCount: 1,
    rows: [[.text("a\u{1B}]0;x\u{07}\u{9B}2J\u{202E}b\u{2028}c\td\ne\rf")]],
    rowsTruncated: false, truncatedCells: 0)

  @Test("csv and tsv are byte-exact when piped and escape control characters on a terminal")
  func csvTsvTerminal() {
    let raw = "a\u{1B}]0;x\u{07}\u{9B}2J\u{202E}b\u{2028}c\td\ne\rf"
    #expect(
      CLIOutput.render(Self.hostile, format: .csv) == "v\u{1B}\r\n\"\(raw)\"\r\n")
    #expect(
      CLIOutput.render(Self.hostile, format: .csv, isTerminal: true)
        == #"v\u{1B}"# + "\r\n"
        + #""a\u{1B}]0;x\u{7}\u{9B}2J\u{202E}b\u{2028}c"# + "\td\n" + #"e\rf""# + "\r\n")
    #expect(
      CLIOutput.render(Self.hostile, format: .tsv)
        == "v\u{1B}\n" + "a\u{1B}]0;x\u{07}\u{9B}2J\u{202E}b\u{2028}c" + #"\td\ne\rf"# + "\n")
    #expect(
      CLIOutput.render(Self.hostile, format: .tsv, isTerminal: true)
        == #"v\u{1B}"# + "\n" + #"a\u{1B}]0;x\u{7}\u{9B}2J\u{202E}b\u{2028}c\td\ne\rf"# + "\n")
  }

  @Test("json and jsonl write controls, C1 and format characters as \\u escapes")
  func jsonEscapesInvisible() throws {
    let text = "a\u{1B}\u{7F}\u{9B}\u{202E}\u{2066}\u{200B}\u{FEFF}\u{2028}\u{E0001}é"
    let literal = CLIOutput.jsonString(text)
    #expect(
      literal
        == #""a\u001b\u007f\u009b\u202e\u2066\u200b\ufeff\u2028\udb40\udc01é""#)
    let decoded = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
    #expect(decoded == text)
    let jsonl = CLIOutput.render(Self.hostile, format: .jsonl)
    #expect(jsonl == #"{"v\u001b":"a\u001b]0;x\u0007\u009b2J\u202eb\u2028c\td\ne\rf"}"# + "\n")
  }

  @Test("table: a row longer than the header is cut to the header's columns")
  func tableRaggedRow() {
    let result = CLIQueryResult(
      columns: [CLIColumn(name: "a", type: "t")], rowCount: 2,
      rows: [[.int(1), .int(2)], []], rowsTruncated: false, truncatedCells: 0)
    #expect(CLIOutput.render(result, format: .table) == "a\n-\n1\n\n")
  }

  @Test("stderr notes: the notice first, then what was cut")
  func notes() {
    #expect(CLIOutput.notes(for: Self.fixed) == [MCPResultEncoder.dataNotice])
    let cut = CLIQueryResult(
      columns: [], rowCount: 2, rows: [], rowsTruncated: true, truncatedCells: 3)
    #expect(
      CLIOutput.notes(for: cut) == [
        MCPResultEncoder.dataNotice,
        "More rows were available: the output stops at 2 rows (--max-rows; at most 1,000 rows "
          + "and about 4 MB per query).",
        "3 values were cut to their first 2,000 characters.",
      ])
    let one = CLIQueryResult(
      columns: [], rowCount: 0, rows: [], rowsTruncated: false, truncatedCells: 1)
    #expect(CLIOutput.notes(for: one).last == "1 value was cut to its first 2,000 characters.")
  }

  // MARK: - Flags

  @Test("The documented commands and flags parse")
  func flagsParse() throws {
    #expect(
      try CLICommand.parse(["pair", "ABCD-1234", "--port", "41730"])
        == .pair(code: "ABCD-1234", port: 41730))
    #expect(
      try CLICommand.parse(["pair", "--port", "41730", "ABCD-1234"])
        == .pair(code: "ABCD-1234", port: 41730))
    #expect(try CLICommand.parse(["pair", "--port", "41730"]) == .pair(code: nil, port: 41730))
    #expect(try CLICommand.parse(["connections"]) == .connections(port: nil))
    #expect(try CLICommand.parse(["connections", "--port", "41730"]) == .connections(port: 41730))
    #expect(
      try CLICommand.parse(["query", "--connection", "Prod", "SELECT 1"])
        == .query(
          CLIQuery(
            connection: "Prod", sql: .text("SELECT 1"), format: .table, maxRows: nil, port: nil)))
    #expect(
      try CLICommand.parse([
        "query", "--connection", "6F1E3C2A", "-f", "q.sql", "--format", "csv", "--max-rows",
        "1000", "--port", "41730",
      ])
        == .query(
          CLIQuery(
            connection: "6F1E3C2A", sql: .file("q.sql"), format: .csv, maxRows: 1000,
            port: 41730)))
    #expect(
      try CLICommand.parse(["query", "--connection", "Prod", "--max-rows", "1", "--", "-- x"])
        == .query(
          CLIQuery(connection: "Prod", sql: .text("-- x"), format: .table, maxRows: 1, port: nil)))
    for format in ["csv", "tsv", "json", "jsonl", "table"] {
      let command = try CLICommand.parse(["query", "--connection", "P", "--format", format, "x"])
      guard case .query(let query) = command else {
        Issue.record("\(format) did not parse as query")
        continue
      }
      #expect(query.format.rawValue == format)
    }
    #expect(CLIFormat.allCases.map(\.rawValue) == ["csv", "tsv", "json", "jsonl", "table"])
    #expect(try CLICommand.parse(["--help"]) == .help)
    #expect(try CLICommand.parse(["-h"]) == .help)
    #expect(try CLICommand.parse(["query", "--bogus", "--help"]) == .help)
    #expect(try CLICommand.parse(["--version"]) == .version)
  }

  @Test(
    "A bad command line is a usage error (exit 1)",
    arguments: [
      [] as [String],
      ["frobnicate"],
      ["connections", "--bogus", "1"],
      ["connections", "extra"],
      ["pair", "ABCD-1234"],
      ["pair", "", "--port", "41730"],
      ["pair", "ABCD", "1234", "--port", "41730"],
      ["pair", "ABCD-1234", "--port"],
      ["pair", "ABCD-1234", "--port", "0"],
      ["pair", "ABCD-1234", "--port", "65536"],
      ["connections", "--port", "1", "--port", "2"],
      ["query", "--connection", "P", "--max-rows", "0", "x"],
      ["query", "--connection", "P", "--max-rows", "1001", "x"],
      ["query", "--connection", "P", "--max-rows", "ten", "x"],
      ["query", "--connection", "P", "--format", "xml", "x"],
      ["query", "--connection", "P", "--format", "csv", "--format", "tsv", "x"],
      ["query", "--connection", "P"],
      ["query", "--connection", "P", "-f", "q.sql", "x"],
      ["query", "--connection", "P", "x", "y"],
      ["query", "x"],
    ])
  func badFlags(_ arguments: [String]) {
    #expect(throws: CLIUsageError.self) { try CLICommand.parse(arguments) }
  }

  @Test("Exit codes are the documented numbers")
  func exitCodes() {
    #expect(
      [CLIExitCode.ok, .usage, .unavailable, .refused, .queryFailed].map(\.rawValue)
        == [0, 1, 2, 3, 4])
  }

  // MARK: - Exit-code mapping

  /// Every `HeadlessAccessRule.Refusal` the command line can get, by exhaustive switch
  private static func reachesCLI(_ refusal: HeadlessAccessRule.Refusal) -> Bool {
    switch refusal {
    // Shortcuts only: the command line's caller is never turned off
    case .shortcutsOff: false
    case .ambiguousName, .notFound, .notAllowlisted, .locked, .aiAccessNever: true
    }
  }

  /// The exit `run_query` / `list_connections` errors map to; nil for errors the command line's
  /// tools cannot get (other tools, writes). An exhaustive switch, so a new case must be placed.
  private static func expectedExit(_ error: MCPToolError) -> CLIExitCode? {
    switch error {
    case .missingArgument, .connectionNotAvailable, .aiAccessNotApproved, .emptyStatement,
      .multipleStatements, .notRead, .sideEffectFunction, .serverSideJavaScript, .cliReadOnly:
      .refused
    case .unknownTool, .tableNotFound, .ambiguousTable, .writeToolsOff, .writeNotAllowed,
      .writeMultipleStatements, .writeIsRead, .writeNotVerifiable, .writeOutOfScope,
      .writeBlockedByProtection, .writeCommitStyle, .writeCommitStyleDefault, .writeDenied,
      .writeHiddenCharacters, .writeNonASCIIWord, .writeTooLong, .writeTooManyWaiting,
      .writeConnectionChanged, .writeOutcomeUnknown:
      nil
    }
  }

  private static func expectedExit(_ error: MCPConnectionError) -> CLIExitCode {
    switch error {
    case .stopped: .unavailable
    case .connectFailed: .queryFailed
    case .unknownConnection, .duckDBNotSupported, .certificateNotSaved, .sshCredentialNotSaved,
      .sshHostKeyNotTrusted, .passwordCommand, .commandRefused, .cursorRefused:
      .refused
    }
  }

  @Test("Every app refusal the command line can get exits 3; a database error exits 4")
  func refusalTextsRecognised() {
    let refusals: [HeadlessAccessRule.Refusal] = [
      .shortcutsOff, .ambiguousName, .notFound, .notAllowlisted, .locked, .aiAccessNever,
    ]
    for refusal in refusals where Self.reachesCLI(refusal) {
      let text = refusal.localizedDescription
      #expect(CLIClient.failure(forToolError: text).exitCode == .refused, "\(text)")
    }
    let toolErrors: [MCPToolError] = [
      .unknownTool, .missingArgument("connection_id"), .missingArgument("sql"),
      .missingArgument("max_rows"), .connectionNotAvailable, .aiAccessNotApproved,
      .emptyStatement, .multipleStatements, .notRead, .sideEffectFunction,
      .serverSideJavaScript, .tableNotFound, .ambiguousTable, .writeToolsOff, .writeNotAllowed,
      .writeMultipleStatements, .writeIsRead, .writeNotVerifiable, .writeOutOfScope(needed: .data),
      .writeBlockedByProtection("x"), .writeCommitStyle, .writeCommitStyleDefault, .writeDenied,
      .writeHiddenCharacters, .writeNonASCIIWord, .writeTooLong, .writeTooManyWaiting,
      .writeConnectionChanged, .writeOutcomeUnknown, .cliReadOnly,
    ]
    for error in toolErrors {
      guard let exit = Self.expectedExit(error) else { continue }
      let text = error.localizedDescription
      #expect(CLIClient.failure(forToolError: text).exitCode == exit, "\(text)")
    }
    let connectionErrors: [MCPConnectionError] = [
      .unknownConnection, .connectFailed, .stopped, .duckDBNotSupported, .certificateNotSaved,
      .sshCredentialNotSaved, .sshHostKeyNotTrusted, .passwordCommand, .commandRefused,
      .cursorRefused,
    ]
    for error in connectionErrors {
      let text = error.localizedDescription
      #expect(
        CLIClient.failure(forToolError: text).exitCode == Self.expectedExit(error), "\(text)")
    }
    let vault = VaultConnectionRefusal().localizedDescription
    #expect(CLIClient.failure(forToolError: vault).exitCode == .refused, "\(vault)")
    #expect(
      CLIClient.failure(forToolError: "ERROR: relation \"orders\" does not exist").exitCode
        == .queryFailed)
    #expect(!CLIClient.isRefusal("ERROR: syntax error at or near \"SELEC\""))
  }

  // MARK: - Credentials file

  private func temporaryStore() throws -> (CLICredentialStore, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CLIContractTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (
      CLICredentialStore(directory: root.appendingPathComponent("Dblore CLI", isDirectory: true)),
      root
    )
  }

  private func mode(_ path: String) -> mode_t {
    var info = stat()
    _ = lstat(path, &info)
    return info.st_mode & 0o777
  }

  private static let credentials = CLICredentials(
    token: "tok", proofKey: MCPTokenStoreFactory.base64URL(Array(repeating: 1, count: 32)),
    port: 41730, id: "id-1")

  @Test("save creates a 0700 folder and a 0600 file, and load reads it back")
  func credentialsSaved() throws {
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.save(Self.credentials)
    #expect(mode(store.directory.path) == 0o700)
    #expect(mode(store.fileURL.path) == 0o600)
    #expect(
      try store.load()
        == CLICredentialStore.Loaded(credentials: Self.credentials, fixedPermissions: false))
    #expect(!Self.credentials.description.contains("tok"))
  }

  @Test("A file or folder other users may read is made private again on load")
  func credentialsPermissionsFixed() throws {
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.save(Self.credentials)
    #expect(chmod(store.fileURL.path, 0o644) == 0)
    #expect(try store.load()?.fixedPermissions == true)
    #expect(mode(store.fileURL.path) == 0o600)
    #expect(chmod(store.directory.path, 0o755) == 0)
    #expect(try store.load()?.fixedPermissions == true)
    #expect(mode(store.directory.path) == 0o700)
    #expect(try store.load()?.fixedPermissions == false)
  }

  @Test("A file other users could write is refused (exit 3), not repaired")
  func credentialsWritableRefused() throws {
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.save(Self.credentials)
    for writable in [0o620, 0o602] as [mode_t] {
      #expect(chmod(store.fileURL.path, writable) == 0)
      let failure = try #require(throws: CLIFailure.self) { try store.load() }
      #expect(failure.exitCode == .refused)
      #expect(failure.message.hasPrefix("The credentials file was writable by other users"))
      #expect(mode(store.fileURL.path) == writable)
    }
  }

  @Test("A symbolic link for the file or the folder is refused")
  func credentialsSymlinksRefused() throws {
    let (store, root) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = CLICredentialStore(directory: root.appendingPathComponent("real", isDirectory: true))
    try real.save(Self.credentials)

    try FileManager.default.createSymbolicLink(
      at: store.directory, withDestinationURL: real.directory)
    #expect(throws: CLIFailure.self) { try store.load() }
    #expect(throws: CLIFailure.self) { try store.save(Self.credentials) }

    try FileManager.default.removeItem(at: store.directory)
    try FileManager.default.createDirectory(
      at: store.directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: real.fileURL)
    #expect(throws: CLIFailure.self) { try store.load() }
  }

  @Test("A folder of another user is refused")
  func credentialsForeignFolderRefused() throws {
    // load() of a missing file returns nil before it checks the folder, and a file of ours in
    // a folder of another user needs root, so save() covers the folder check.
    let store = CLICredentialStore(directory: URL(fileURLWithPath: "/usr", isDirectory: true))
    let failure = try #require(throws: CLIFailure.self) { try store.save(Self.credentials) }
    #expect(failure.message == "/usr is not a folder of yours.")
  }
}
