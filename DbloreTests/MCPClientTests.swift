// MCPClientTests.swift
// The outside MCP client (Streamable HTTP, spec 2025-06-18): a round trip against Dblore's own
// server on loopback, URL refusals made before any request, the 1 MiB response cap (by
// Content-Length and while streaming), refused redirects, SSE responses, the session id and
// the re-initialize after a 404, tools/list pages and caps, hidden characters stripped from
// server text, stable fingerprints, and the tool gate checked on the live server before any
// request. Fakes are local listeners only.

import Darwin
import Foundation
import Testing

@testable import Dblore

/// The requests a fake server saw, in order.
private final class RequestLog: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [MCPHTTPRequest] = []

  func append(_ request: MCPHTTPRequest) { lock.withLock { requests.append(request) } }
  var all: [MCPHTTPRequest] { lock.withLock { requests } }
}

/// A switch shared with a fake server's handler.
private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isOn: Bool {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}

/// The live copy of a server, as the store would hand it to `callTool`.
@MainActor
private final class LiveServer {
  var value: OutsideMCPServer?

  init(_ value: OutsideMCPServer?) { self.value = value }

  var current: @MainActor @Sendable (UUID) -> OutsideMCPServer? { { [self] _ in value } }
}

/// A counter shared with a fake server's handler.
private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}

extension MCPHTTPRequest {
  fileprivate func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  fileprivate var message: [String: Any] {
    (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
  }

  fileprivate var rpcID: Int { message["id"] as? Int ?? -1 }
  fileprivate var rpcMethod: String { message["method"] as? String ?? "" }
  fileprivate var params: [String: Any] { message["params"] as? [String: Any] ?? [:] }
}

private func json(_ body: String, headers: [String: String] = [:]) -> MCPHTTPResponse {
  var headers = headers
  headers["Content-Type"] = "application/json"
  return MCPHTTPResponse(status: 200, headers: headers, body: Data(body.utf8))
}

private func result(
  _ request: MCPHTTPRequest, _ result: String, headers: [String: String] = [:]
)
  -> MCPHTTPResponse
{
  json(#"{"jsonrpc":"2.0","id":\#(request.rpcID),"result":\#(result)}"#, headers: headers)
}

private let initializeResult =
  #"{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"#
  + #""serverInfo":{"name":"Fake","version":"1"}}"#

private let fakeToken = "fake-token"
private let fakeServerID = UUID()

/// An enabled server at `url` with `tools` ticked as listed, with the id of every fake client.
private func server(
  _ url: URL, allowing tools: [MCPClientTool], id: UUID = fakeServerID
) -> OutsideMCPServer {
  OutsideMCPServer(
    id: id, name: "Fake", url: url.absoluteString, isEnabled: true,
    allowedTools: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.fingerprint) }))
}

/// A provider that always hands back `server`.
private func live(_ server: OutsideMCPServer?) -> @MainActor @Sendable (UUID) -> OutsideMCPServer? {
  { _ in server }
}

private func fakeClient(_ url: URL) throws -> MCPClient {
  try MCPClient(url: url, token: fakeToken, serverID: fakeServerID)
}

/// Starts a fake MCP server on 127.0.0.1 and returns it with its endpoint.
private func startFake(
  _ handler: @escaping MCPHTTPServer.Handler
) async throws -> (MCPHTTPServer, URL) {
  let server = MCPHTTPServer(handler: handler)
  let port = try await server.start(.init(port: 0, token: fakeToken))
  return (server, try #require(URL(string: "http://127.0.0.1:\(port)/mcp")))
}

/// Answers initialize and its notification; everything else goes to `other`.
private func lifecycle(
  _ other: @escaping @Sendable (MCPHTTPRequest) -> MCPHTTPResponse
) -> MCPHTTPServer.Handler {
  { request in
    switch request.rpcMethod {
    case "initialize": result(request, initializeResult)
    case "notifications/initialized": MCPHTTPResponse(status: 202, headers: [:], body: Data())
    default: other(request)
    }
  }
}

/// A one-shot listener on 127.0.0.1 that answers the first request with `Connection: close`,
/// no Content-Length, and SSE comment lines until `total` bytes are sent or the client leaves.
private final class StreamingResponder: @unchecked Sendable {
  let port: Int
  private let fd: Int32

  init() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EBADF) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 4) == 0 else {
      close(fd)
      throw POSIXError(.EADDRINUSE)
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    self.fd = fd
    port = Int(UInt16(bigEndian: addr.sin_port))
  }

  deinit { close(fd) }

  /// Serves one connection on a background queue; gives up after 10 s without a client.
  func serveOnce(total: Int) {
    let fd = self.fd
    DispatchQueue.global().async {
      var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      guard poll(&poller, 1, 10_000) == 1 else { return }
      let client = accept(fd, nil, nil)
      guard client >= 0 else { return }
      defer { close(client) }
      var on: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      var timeout = timeval(tv_sec: 5, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      Self.readRequest(client)
      let head =
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
      guard Self.send(client, Array(head.utf8)) else { return }
      let line = Array((": " + String(repeating: "x", count: 1_021) + "\n").utf8)
      var sent = 0
      while sent < total, Self.send(client, line) { sent += line.count }
    }
  }

  /// Reads the head and the Content-Length body, so the close does not reset unread bytes.
  private static func readRequest(_ client: Int32) {
    var received: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
      guard count > 0 else { return }
      received += buffer[0..<count]
      let text = String(decoding: received, as: UTF8.self)
      guard let end = text.range(of: "\r\n\r\n") else { continue }
      let length =
        text[..<end.lowerBound].split(separator: "\r\n")
        .first { $0.lowercased().hasPrefix("content-length:") }
        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
      if received.count - text[..<end.upperBound].utf8.count >= length { return }
    }
  }

  private static func send(_ client: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let count = bytes[offset...].withUnsafeBytes {
        Darwin.send(client, $0.baseAddress, $0.count, 0)
      }
      guard count > 0 else { return false }
      offset += count
    }
    return true
  }
}

@Suite("MCP client", .serialized)
struct MCPClientTests {
  private let suiteName = "MCPClientTests.\(UUID().uuidString)"

  /// A port nothing listens on right now.
  private func freePort() async throws -> Int {
    let probe = MCPHTTPServer { _ in .text(200, "") }
    let port = try await probe.start(.init(port: 0, token: "probe"))
    await probe.stop()
    return port
  }

  @MainActor
  private func waitForRunning(_ controller: MCPServerController) async throws -> Int {
    let deadline = ContinuousClock.now + .seconds(120)
    while ContinuousClock.now < deadline {
      if case .running(let port) = controller.status { return port }
      if case .failed(let message) = controller.status {
        Issue.record("MCP server failed: \(message)")
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw CancellationError()
  }

  @MainActor
  @Test("Initialize, tools/list and tools/call against Dblore's own MCP server")
  func roundTrip() async throws {
    let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let entry = ConnectionHistoryEntry(
      config: ConnectionConfig(
        databaseType: .postgresql, host: "db.internal", port: 5432, database: "app",
        username: "u", name: "Orders"))
    settings.mcpAllowedConnectionIDs = [entry.id]
    settings.mcpPort = try await freePort()
    settings.mcpEnabled = true
    let controller = MCPServerController(
      settings: settings, tokens: InMemoryMCPTokenStore(), savedConnections: { [entry] },
      password: { _ in nil }, recorder: InMemoryQueryHistoryRecorder())
    controller.activate()
    do {
      let port = try await waitForRunning(controller)
      let client = try MCPClient(
        url: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")),
        token: await controller.token(), serverID: fakeServerID)

      let info = try await client.connect()
      #expect(info.name == "Dblore")
      #expect(info.protocolVersion == "2025-06-18")

      let tools = try await client.listTools()
      let listConnections = try #require(tools.first { $0.name == "list_connections" })
      #expect(tools.allSatisfy { !$0.description.isEmpty })

      let call = try await client.callTool(
        "list_connections", arguments: [:],
        current: live(server(client.url, allowing: [listConnections])))
      #expect(!call.isError)
      #expect(call.untrustedText.contains(entry.id.uuidString))

      // A wrong token is refused by the server, and the error names no token.
      let refused = try MCPClient(
        url: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")), token: "wrong-token",
        serverID: fakeServerID)
      await #expect(throws: MCPClientError.unauthorized(status: 401)) {
        try await refused.connect()
      }
    } catch {
      await controller.stop()
      throw error
    }
    await controller.stop()
  }

  @Test("Plain http to a non-loopback host, other schemes and credentials in the URL are refused")
  func refusesUnsafeURLs() throws {
    let refused: [(String, MCPClientError)] = [
      ("http://example.com/mcp", .insecureURL),
      ("http://192.168.1.5:8080/mcp", .insecureURL),
      ("http://127.0.0.1.example.com/mcp", .insecureURL),
      ("ftp://127.0.0.1/mcp", .insecureURL),
      ("https://user:secret@mcp.example.com/mcp", .credentialsInURL),
      ("http://user@127.0.0.1:3000/mcp", .credentialsInURL),
      ("not a url", .invalidURL),
    ]
    for (text, error) in refused {
      #expect(throws: error, "\(text)") { try MCPClient.endpoint(text) }
      if let url = URL(string: text) {
        #expect(throws: error, "\(text)") {
          try MCPClient(url: url, token: "t", serverID: fakeServerID)
        }
      }
    }
    for text in [
      "http://127.0.0.1:3000/mcp", "http://[::1]:3000/mcp", "http://LOCALHOST:3000/mcp",
      "https://mcp.example.com/mcp",
    ] {
      #expect(throws: Never.self, "\(text)") { try MCPClient.endpoint(text) }
    }
    let url = try #require(URL(string: "https://mcp.example.com/mcp"))
    #expect(throws: MCPClientError.invalidToken) {
      try MCPClient(url: url, token: "a\r\nX: y", serverID: fakeServerID)
    }
  }

  @Test("A response over 1 MiB is refused, by Content-Length and while it streams")
  func refusesOversizedResponses() async throws {
    let (server, url) = try await startFake { _ in
      json(String(repeating: " ", count: MCPClient.responseLimit) + "{}")
    }
    let client = try fakeClient(url)
    await #expect(throws: MCPClientError.responseTooLarge) { try await client.connect() }
    await server.stop()

    let responder = try StreamingResponder()
    responder.serveOnce(total: 4 * MCPClient.responseLimit)
    let streamed = try fakeClient(
      try #require(URL(string: "http://127.0.0.1:\(responder.port)/mcp")))
    await #expect(throws: MCPClientError.responseTooLarge) { try await streamed.connect() }
  }

  @Test("A redirect is refused, also to the same host")
  func refusesRedirects() async throws {
    let log = RequestLog()
    let (server, url) = try await startFake { request in
      log.append(request)
      return MCPHTTPResponse(
        status: 307, headers: ["Location": "http://127.0.0.1:9/mcp"], body: Data())
    }
    let client = try fakeClient(url)
    await #expect(throws: MCPClientError.redirectRefused) { try await client.connect() }
    #expect(log.all.count == 1)
    await server.stop()
  }

  @Test("SSE responses: notifications and other ids are skipped, a JSON-RPC error is thrown")
  func readsEventStreams() async throws {
    let (fake, url) = try await startFake(
      lifecycle { request in
        if request.rpcMethod == "tools/list" {
          return result(request, #"{"tools":[{"name":"echo"},{"name":"missing"}]}"#)
        }
        let name = request.params["name"] as? String
        let body =
          name == "echo"
          ? MCPStreamableHTTPFixtures.toolsCallStream(id: request.rpcID)
          : MCPStreamableHTTPFixtures.errorStream(id: request.rpcID)
        return MCPHTTPResponse(
          status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(body.utf8))
      })
    let client = try fakeClient(url)
    let allowed = server(url, allowing: try await client.listTools())
    let call = try await client.callTool(
      "echo", arguments: ["text": .string("hi")], current: live(allowed))
    #expect(call.untrustedText == "ok")
    #expect(!call.isError)
    await #expect(throws: MCPClientError.rpc(code: -32602, message: "Unknown tool")) {
      try await client.callTool("missing", arguments: [:], current: live(allowed))
    }
    await fake.stop()
  }

  @Test("The SSE splitter joins data lines, skips comments and ids, and reads CR, LF and CRLF")
  func splitsEvents() {
    let body =
      ": comment\r\nid: 1\r\nevent: message\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\n"
      + "event: other\ndata: x\n\n" + "retry: 5\rdata:y\r\r" + "data: tail"
    var splitter = MCPSSESplitter()
    var events = Array(body.utf8).compactMap { splitter.feed($0) }
    if let last = splitter.finish() { events.append(last) }
    #expect(
      events == [
        MCPSSEEvent(event: "message", data: "{\"a\":\n1}"),
        MCPSSEEvent(event: "other", data: "x"),
        MCPSSEEvent(event: "message", data: "y"),
        MCPSSEEvent(event: "message", data: "tail"),
      ])
  }

  @Test(
    "A 404 re-initializes without the session id: tools/list is retried, tools/call is not, and the new session needs its own tools/list"
  )
  func reinitializesExpiredSessions() async throws {
    let log = RequestLog()
    let sessions = Counter()
    let (fake, url) = try await startFake { request in
      log.append(request)
      switch request.rpcMethod {
      case "initialize":
        return result(
          request, initializeResult, headers: ["Mcp-Session-Id": "session-\(sessions.next())"])
      case "notifications/initialized":
        return MCPHTTPResponse(status: 202, headers: [:], body: Data())
      default:
        switch (request.header("Mcp-Session-Id"), request.rpcMethod) {
        case ("session-1", _), ("session-2", "tools/call"): return .text(404, "Session expired")
        case ("session-2", "tools/list"), ("session-3", "tools/list"):
          return result(request, #"{"tools":[{"name":"echo"}]}"#)
        case ("session-3", "tools/call"):
          return result(request, #"{"content":[{"type":"text","text":"ok"}]}"#)
        default: return .text(400, "Session required")
        }
      }
    }
    let client = try fakeClient(url)
    let tools = try await client.listTools()
    #expect(tools.map(\.name) == ["echo"])

    let requests = log.all
    #expect(
      requests.map(\.rpcMethod) == [
        "initialize", "notifications/initialized", "tools/list",
        "initialize", "notifications/initialized", "tools/list",
      ])
    #expect(
      requests.map { $0.header("Mcp-Session-Id") } == [
        nil, "session-1", "session-1", nil, "session-2", "session-2",
      ])
    #expect(
      requests.map { $0.header("MCP-Protocol-Version") } == [
        nil, "2025-06-18", "2025-06-18", nil, "2025-06-18", "2025-06-18",
      ])
    #expect(requests.allSatisfy { $0.header("Authorization") == "Bearer \(fakeToken)" })
    #expect(
      requests.allSatisfy {
        $0.header("Accept") == "application/json, text/event-stream"
      })

    // The call may not be safe to repeat: a new session is started, the call is not sent again.
    let allowed = live(server(url, allowing: tools))
    await #expect(throws: MCPClientError.sessionExpired) {
      try await client.callTool("echo", arguments: [:], current: allowed)
    }
    #expect(
      log.all.dropFirst(requests.count).map(\.rpcMethod) == [
        "tools/call", "initialize", "notifications/initialized",
      ])

    // The list of the old session is gone: nothing is sent until tools/list runs again.
    let sent = log.all.count
    await #expect(throws: MCPClientError.toolNotListed) {
      try await client.callTool("echo", arguments: [:], current: allowed)
    }
    #expect(log.all.count == sent)
    _ = try await client.listTools()
    let call = try await client.callTool("echo", arguments: [:], current: allowed)
    #expect(call.untrustedText == "ok")
    await fake.stop()
  }

  @Test(
    "A tool is refused before any request when unlisted, not ticked, off, misnamed, elsewhere or removed"
  )
  func gateRefusesBeforeRequests() async throws {
    let log = RequestLog()
    let listFails = Flag()
    let respond = lifecycle { request in
      listFails.isOn
        ? .text(500, "Broken")
        : result(request, #"{"tools":[{"name":"echo","description":"Echo"}]}"#)
    }
    let (fake, url) = try await startFake { request in
      log.append(request)
      return await respond(request)
    }
    let client = try fakeClient(url)
    let echo = MCPClientTool(name: "echo", description: "Echo", inputSchema: .object([:]))
    let allowed = server(url, allowing: [echo])

    // No tools/list yet: nothing is listed, so nothing is sent.
    await #expect(throws: MCPClientError.toolNotListed) {
      try await client.callTool("echo", arguments: [:], current: live(allowed))
    }
    #expect(log.all.isEmpty)

    let listed = try #require(try await client.listTools().first)
    let sent = log.all.count
    var off = server(url, allowing: [listed])
    off.isEnabled = false
    let refusals: [(String, OutsideMCPServer?, MCPClientError)] = [
      ("other", server(url, allowing: [listed]), .toolNotAllowed),
      ("echo", server(url, allowing: []), .toolNotAllowed),
      ("echo", off, .serverDisabled),
      ("bad name", server(url, allowing: [listed]), .invalidToolName),
      (
        "echo", server(try #require(URL(string: "http://127.0.0.1:9/mcp")), allowing: [listed]),
        .wrongServer
      ),
      ("echo", server(url, allowing: [listed], id: UUID()), .wrongServer),
      ("echo", nil, .serverRemoved),
    ]
    for (name, target, error) in refusals {
      await #expect(throws: error, "\(name)") {
        try await client.callTool(name, arguments: [:], current: live(target))
      }
    }
    #expect(log.all.count == sent)

    // A failed tools/list leaves nothing listed.
    listFails.isOn = true
    await #expect(throws: MCPClientError.http(status: 500)) { try await client.listTools() }
    await #expect(throws: MCPClientError.toolNotListed) {
      try await client.callTool(
        "echo", arguments: [:], current: live(server(url, allowing: [listed])))
    }
    #expect(!log.all.contains { $0.rpcMethod == "tools/call" })
    await fake.stop()
  }

  @MainActor
  @Test("A call that waited for its turn is checked on the live server: unticked or off is refused")
  func waitingCallUsesLiveServer() async throws {
    let log = RequestLog()
    let release = Flag()
    let respond = lifecycle { request in
      request.rpcMethod == "tools/list"
        ? result(request, #"{"tools":[{"name":"echo"},{"name":"slow"}]}"#)
        : result(request, #"{"content":[{"type":"text","text":"ok"}]}"#)
    }
    let (fake, url) = try await startFake { request in
      log.append(request)
      if request.rpcMethod == "tools/call" {
        let deadline = ContinuousClock.now + .seconds(10)
        while !release.isOn, ContinuousClock.now < deadline {
          try? await Task.sleep(for: .milliseconds(10))
        }
      }
      return await respond(request)
    }
    let client = try fakeClient(url)
    let tools = try await client.listTools()
    let calls = { log.all.filter { $0.rpcMethod == "tools/call" }.count }
    let changes: [(String, (inout OutsideMCPServer) -> Void, MCPClientError)] = [
      ("unticked", { $0.allowedTools["echo"] = nil }, .toolNotAllowed),
      ("turned off", { $0.isEnabled = false }, .serverDisabled),
    ]
    for (label, change, error) in changes {
      let state = LiveServer(server(url, allowing: tools))
      release.isOn = false
      let before = calls()
      // The first call holds the client's turn until released; the second waits behind it.
      let first = Task { try await client.callTool("slow", arguments: [:], current: state.current) }
      let deadline = ContinuousClock.now + .seconds(10)
      while calls() == before, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let waiting = Task {
        try await client.callTool("echo", arguments: [:], current: state.current)
      }
      try await Task.sleep(for: .milliseconds(100))
      change(&state.value!)
      release.isOn = true
      #expect(try await first.value.untrustedText == "ok", "\(label)")
      await #expect(throws: error, "\(label)") { try await waiting.value }
      #expect(calls() == before + 1, "\(label)")
    }
    await fake.stop()
  }

  @Test("A ticked tool still matches on a fresh client, and is refused once one schema key changes")
  func fingerprintsAreStable() async throws {
    let changed = Flag()
    let (fake, url) = try await startFake(
      lifecycle { request in
        guard request.rpcMethod == "tools/list" else {
          return result(request, #"{"content":[{"type":"text","text":"ok"}]}"#)
        }
        let schema: [String: Any] = [
          "type": "object",
          "required": ["sql", "limit"],
          "properties": [
            "sql": ["type": "string", "description": "Requête SQL, 日本語, a/b"],
            "limit": [
              "type": "integer", "minimum": 1, (changed.isOn ? "maxItems" : "maximum"): 500,
            ],
            "options": [
              "type": "object",
              "properties": ["dryRun": ["type": "boolean", "default": false]],
            ],
          ],
          "additionalProperties": false,
        ]
        let tools: [[String: Any]] = [
          ["name": "query", "description": "Run", "inputSchema": schema]
        ]
        let data = try! JSONSerialization.data(withJSONObject: ["tools": tools])
        return result(request, String(decoding: data, as: UTF8.self))
      })
    let allowed = live(server(url, allowing: try await fakeClient(url).listTools()))

    let fresh = try fakeClient(url)
    _ = try await fresh.listTools()
    let call = try await fresh.callTool("query", arguments: [:], current: allowed)
    #expect(call.untrustedText == "ok")

    changed.isOn = true
    let later = try fakeClient(url)
    _ = try await later.listTools()
    await #expect(throws: MCPClientError.toolChanged) {
      try await later.callTool("query", arguments: [:], current: allowed)
    }
    await fake.stop()
  }

  @Test("Two tools/list at once on a new client start one session")
  func concurrentCallsShareOneSession() async throws {
    let log = RequestLog()
    let respond = lifecycle { request in result(request, #"{"tools":[{"name":"echo"}]}"#) }
    let (fake, url) = try await startFake { request in
      log.append(request)
      return await respond(request)
    }
    let client = try fakeClient(url)
    async let first = client.listTools()
    async let second = client.listTools()
    let (a, b) = try await (first, second)
    #expect(a == b)
    #expect(log.all.filter { $0.rpcMethod == "initialize" }.count == 1)
    await fake.stop()
  }

  @Test("Hidden characters are stripped from descriptions, schemas and results; caps count scalars")
  func sanitizesServerText() async throws {
    // Tag block (U+E0000-E007F), bidi override and isolate, zero-width space and joiner.
    let hidden = "\u{E0001}\u{E0049}\u{E007F}\u{202E}\u{2066}\u{200B}\u{2060}"
    let combining = String(repeating: "a\u{0301}", count: 50_000)
    let (fake, url) = try await startFake(
      lifecycle { request in
        guard request.rpcMethod == "tools/list" else {
          return result(
            request, #"{"content":[{"type":"text","text":"ok\#(hidden)\nnext"}]}"#)
        }
        let property: [String: Any] = [
          "type": "string", "description": "The\(hidden) text", "enum": ["a\(hidden)b"],
        ]
        let tools: [[String: Any]] = [
          [
            "name": "echo", "description": "Echo\(hidden) text",
            "inputSchema": ["type": "object", "properties": ["text": property]],
          ],
          ["name": "long", "description": combining],
        ]
        let data = try! JSONSerialization.data(withJSONObject: ["tools": tools])
        return result(request, String(decoding: data, as: UTF8.self))
      })
    let client = try fakeClient(url)
    let tools = try await client.listTools()
    let echo = try #require(tools.first { $0.name == "echo" })
    #expect(echo.description == "Echo text")
    guard case .object(let schema) = echo.inputSchema,
      case .object(let properties)? = schema["properties"],
      case .object(let text)? = properties["text"]
    else {
      Issue.record("schema shape")
      return
    }
    #expect(text["description"] == .string("The text"))
    #expect(text["enum"] == .array([.string("ab")]))
    let long = try #require(tools.first { $0.name == "long" })
    #expect(long.description.unicodeScalars.count <= MCPClient.maxDescriptionLength)

    let call = try await client.callTool(
      "echo", arguments: [:], current: live(server(url, allowing: [echo])))
    #expect(call.untrustedText == "ok\nnext")
    await fake.stop()
  }

  @Test("tools/list follows pages up to 100 tools and drops bad names")
  func pagesAndCapsTools() async throws {
    let log = RequestLog()
    let longDescription = String(repeating: "d", count: 10_000)
    let (server, url) = try await startFake(
      lifecycle { request in
        log.append(request)
        let cursor = request.params["cursor"] as? String
        let page = cursor == nil ? 0 : cursor == "p2" ? 1 : 2
        var tools = (0..<60).map { index -> [String: Any] in
          ["name": "t\(page * 60 + index)", "description": longDescription]
        }
        if page == 0 {
          tools += [
            ["name": "bad\u{202E}name"], ["name": String(repeating: "n", count: 129)],
            ["name": "has space"], ["name": "t0"], ["description": "no name"],
          ]
        }
        let object: [String: Any] = ["tools": tools, "nextCursor": "p\(page + 2)"]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return result(request, String(decoding: data, as: UTF8.self))
      })
    let client = try fakeClient(url)
    let tools = try await client.listTools()
    #expect(tools.map(\.name) == (0..<100).map { "t\($0)" })
    #expect(tools.allSatisfy { $0.description.count == MCPClient.maxDescriptionLength })
    #expect(log.all.count == 2)
    await server.stop()
  }
}
