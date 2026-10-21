// MCPClientSpikeTests.swift
// Spike 3.4: an MCP Streamable HTTP client (spec 2025-06-18) against Dblore's own MCP server,
// the SSE response shape a client must read, and whether one slow request holds up another.
//
// Observed on the app's server (MCPServerController -> MCPJSONRPC -> MCPHTTPServer):
// - initialize: 200, `Content-Type: application/json`, no `Mcp-Session-Id` (stateless
//   transport, one SDK Server per request), the requested 2025-06-18 is echoed.
// - notifications/initialized: 202 with an empty body.
// - tools/list, tools/call: 200 JSON. `MCP-Protocol-Version` is checked when present (an
//   unsupported one is 400 with a JSON-RPC -32600 error, id null, listing 2024-11-05,
//   2025-03-26, 2025-06-18, 2025-11-25); a request without it is served.
// - GET /mcp: 405 with `Allow: POST` (no server-to-client stream, no session DELETE).
// - tools/call list_connections works without a database; list_tables on an id that is not
//   allowlisted is a well-formed tool error (result.isError true, content[] text), not a
//   JSON-RPC error.
// - The server never answers text/event-stream, so the SSE shape is pinned from a fixture.
//   AISSEParser frames SSE lines but hands each event's JSON to an AI provider decoder: an MCP
//   result yields nothing on every wire, and a JSON-RPC error object throws `.provider` on the
//   chat-completions wire (tested; the Gemini wire reads `error` the same way, by source). A
//   client needs its own event splitter (blank line ends an event, `data:` lines joined with
//   "\n", event name defaults to `message`, comments and `id:` skipped) that returns the raw
//   JSON-RPC messages, as `sseEvents(_:)` here does.
// - Concurrency: each request runs in its own Task (`MCPRequestTasks.run`, called from
//   `MCPHTTPConnectionHandler.dispatch`), so a slow tools/call on one connection does not hold
//   up a tools/list on another. Requests on one keep-alive connection are serialized by the
//   HTTP/1.1 pipeline (`configureHTTPServerPipeline()` in `MCPHTTPServer.bind`, see
//   `MCPHTTPConnectionHandler`); URLSession does not pipeline, it opens another connection.
//   Measured 2026-10-21: tools/list 8 ms while a 2 s tools/call ran (call 2.05 s); two 2 s calls together 2.02 s.
//
// MCPConnectionPool (task 24.3): see the phase 3 Decision record in the batch 7 plan.

import Foundation
import Testing
import os

@testable import Dblore

/// Writes a spike measurement to the unified log (the test host's stdout is not kept):
/// `log show --last 10m --predicate 'category == "MCPClientSpike"'`.
private func report(_ message: String) {
  Logger(subsystem: "ace.thi.DbloreTests", category: "MCPClientSpike")
    .notice("\(message, privacy: .public)")
}

private struct HTTPReply: Sendable {
  let status: Int
  let response: HTTPURLResponse?
  let body: Data
  let elapsed: Duration

  var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
  var result: [String: Any]? { json?["result"] as? [String: Any] }

  func header(_ name: String) -> String? { response?.value(forHTTPHeaderField: name) }
}

/// A test-local Streamable HTTP client: one POST per JSON-RPC message, a new URLSession (so a
/// new connection) per request.
private struct MCPTestClient: Sendable {
  let port: Int
  let token: String

  static let timeout: TimeInterval = 120

  func send(
    _ body: String, method: String = "POST", protocolVersion: String? = "2025-06-18"
  ) async throws -> HTTPReply {
    var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")))
    request.httpMethod = method
    if method == "POST" { request.httpBody = Data(body.utf8) }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let protocolVersion {
      request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
    }
    request.timeoutInterval = Self.timeout
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = Self.timeout
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let clock = ContinuousClock()
    let start = clock.now
    let (data, response) = try await session.data(for: request)
    let http = response as? HTTPURLResponse
    return HTTPReply(
      status: http?.statusCode ?? -1, response: http, body: data, elapsed: clock.now - start)
  }

  static func rpc(_ method: String, id: Int, params: String = "{}") -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
  }
}

/// Counts the calls that entered the tool handler.
private actor Rendezvous {
  let parties: Int
  private var arrived = 0

  init(parties: Int) { self.parties = parties }

  func arrive() { arrived += 1 }
  var met: Bool { arrived >= parties }
}

/// Tools whose calls take `delay`, or, with a barrier, wait until the barrier's parties have
/// all entered the handler (a tool error after 10 s, so a serial server fails); tools/list
/// answers at once.
private struct SlowTools: MCPToolCalling {
  var delay: Duration = .zero
  var barrier: Rendezvous?

  var tools: [MCPToolDefinition] { MCPToolService.tools }

  func call(_ name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
    guard let barrier else {
      try? await Task.sleep(for: delay)
      return MCPToolResult(text: "slept", isError: false)
    }
    await barrier.arrive()
    let deadline = ContinuousClock.now + .seconds(10)
    while await !barrier.met, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let met = await barrier.met
    return MCPToolResult(text: met ? "met" : "barrier timed out", isError: !met)
  }
}

/// One SSE event as an MCP client reads it.
private struct SSEEvent: Equatable {
  var event: String
  var data: String
}

/// Splits a `text/event-stream` body into events (HTML SSE rules, minus `retry`).
private func sseEvents(_ body: String) -> [SSEEvent] {
  var events: [SSEEvent] = []
  var name: String?
  var data: [String] = []
  let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(
    separator: "\n", omittingEmptySubsequences: false)
  for line in lines {
    if line.isEmpty {
      if !data.isEmpty {
        events.append(SSEEvent(event: name ?? "message", data: data.joined(separator: "\n")))
      }
      name = nil
      data = []
      continue
    }
    if line.hasPrefix(":") { continue }
    let field = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    var value = field.count > 1 ? field[1] : ""
    if value.hasPrefix(" ") { value = value.dropFirst() }
    switch field[0] {
    case "event": name = String(value)
    case "data": data.append(String(value))
    default: break
    }
  }
  return events
}

@Suite("MCP client spike", .serialized)
struct MCPClientSpikeTests {
  private let suiteName = "MCPClientSpikeTests.\(UUID().uuidString)"

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
  @Test("A Streamable HTTP client completes initialize, tools/list and tools/call")
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
      let client = MCPTestClient(
        port: try await waitForRunning(controller), token: await controller.token())

      let initialize = try await client.send(
        MCPTestClient.rpc(
          "initialize", id: 1,
          params: #"{"protocolVersion":"2025-06-18","capabilities":{},"#
            + #""clientInfo":{"name":"spike","title":"Spike","version":"1"}}"#),
        protocolVersion: nil)
      #expect(initialize.status == 200)
      #expect(initialize.header("Content-Type") == "application/json")
      #expect(initialize.header("Mcp-Session-Id") == nil)
      let initialized = try #require(initialize.result)
      #expect(initialized["protocolVersion"] as? String == "2025-06-18")
      #expect((initialized["serverInfo"] as? [String: Any])?["name"] as? String == "Dblore")
      #expect((initialized["capabilities"] as? [String: Any])?["tools"] != nil)

      let notification = try await client.send(
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
      #expect(notification.status == 202)
      #expect(notification.body.isEmpty)

      let list = try await client.send(MCPTestClient.rpc("tools/list", id: 2))
      #expect(list.status == 200)
      #expect(list.header("Content-Type") == "application/json")
      let tools = try #require(list.result?["tools"] as? [[String: Any]])
      #expect(!tools.isEmpty)
      for tool in tools {
        #expect(tool["name"] is String)
        #expect(tool["description"] is String)
        #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object")
      }

      // MCP-Protocol-Version: absent is served, an unsupported one is refused.
      let unversioned = try await client.send(
        MCPTestClient.rpc("tools/list", id: 3), protocolVersion: nil)
      #expect(unversioned.status == 200)
      let badVersion = try await client.send(
        MCPTestClient.rpc("tools/list", id: 4), protocolVersion: "1.0.0")
      #expect(badVersion.status == 400)

      let call = try await client.send(
        MCPTestClient.rpc(
          "tools/call", id: 5, params: #"{"name":"list_connections","arguments":{}}"#))
      #expect(call.status == 200)
      let callResult = try #require(call.result)
      let content = try #require(callResult["content"] as? [[String: Any]])
      #expect(content.first?["type"] as? String == "text")
      #expect((content.first?["text"] as? String)?.contains(entry.id.uuidString) == true)
      #expect(callResult["isError"] as? Bool != true)

      // A connection-scoped tool on an id that is not allowlisted: a tool error, no DB reached.
      let refused = try await client.send(
        MCPTestClient.rpc(
          "tools/call", id: 6,
          params: #"{"name":"list_tables","arguments":{"connection_id":"\#(UUID().uuidString)"}}"#))
      #expect(refused.status == 200)
      let refusedResult = try #require(refused.result)
      #expect(refusedResult["isError"] as? Bool == true)
      #expect((refusedResult["content"] as? [[String: Any]])?.first?["text"] is String)

      let stream = try await client.send("", method: "GET", protocolVersion: nil)
      #expect(stream.status == 405)
      #expect(stream.header("Allow") == "POST")

      report(
        "MCP-SPIKE roundTrip: initialize \(initialize.status)"
          + " \(initialize.header("Content-Type") ?? "-")"
          + " session=\(initialize.header("Mcp-Session-Id") ?? "none")"
          + " | initialized \(notification.status) | tools/list \(list.status) (\(tools.count) tools)"
          + " | no version \(unversioned.status) | bad version \(badVersion.status)"
          + " \(String(data: badVersion.body, encoding: .utf8) ?? "")"
          + " | tools/call \(call.status) | refused isError=\(refusedResult["isError"] ?? "-")"
          + " | GET \(stream.status)")
    } catch {
      await controller.stop()
      throw error
    }
    await controller.stop()
  }

  @Test("An SSE tools/call stream: AISSEParser drops MCP messages; a plain splitter reads them")
  func sseResponseShape() throws {
    let lines = MCPStreamableHTTPFixtures.toolsCallStream.split(
      separator: "\n", omittingEmptySubsequences: false)
    for wire in [AIWire.chatCompletions, .anthropicMessages, .responses, .geminiGenerateContent] {
      var parser = AISSEParser(wire: wire)
      var deltas: [AIStreamDelta] = []
      for line in lines { deltas += try parser.consume(line: String(line)) }
      #expect(deltas.isEmpty, "\(wire)")
    }
    var chat = AISSEParser(wire: .chatCompletions)
    #expect(throws: AIStreamError.provider("Unknown tool")) {
      for line in MCPStreamableHTTPFixtures.errorStream.split(
        separator: "\n", omittingEmptySubsequences: false)
      {
        _ = try chat.consume(line: String(line))
      }
    }

    let events = sseEvents(MCPStreamableHTTPFixtures.toolsCallStream)
    #expect(events.map(\.event) == ["message", "message"])
    let messages = try events.map {
      try #require(JSONSerialization.jsonObject(with: Data($0.data.utf8)) as? [String: Any])
    }
    #expect(messages.first?["method"] as? String == "notifications/progress")
    #expect(messages.first?["id"] == nil)
    let response = try #require(messages.last)
    #expect(response["id"] as? Int == MCPStreamableHTTPFixtures.responseID)
    let content = (response["result"] as? [String: Any])?["content"] as? [[String: Any]]
    #expect(content?.first?["text"] as? String == "ok")

    let error = try #require(sseEvents(MCPStreamableHTTPFixtures.errorStream).last)
    let errorObject = try #require(
      JSONSerialization.jsonObject(with: Data(error.data.utf8)) as? [String: Any])
    #expect((errorObject["error"] as? [String: Any])?["code"] as? Int == -32602)
  }

  @Test("A slow tools/call does not hold up a tools/list or another call on other connections")
  func slowCallDoesNotBlock() async throws {
    let delay = Duration.seconds(2)
    let server = MCPHTTPServer(
      handler: MCPJSONRPC.handler(tools: SlowTools(delay: delay), version: "spike"))
    let token = "spike-token"
    let client = MCPTestClient(
      port: try await server.start(.init(port: 0, token: token)), token: token)
    let call = MCPTestClient.rpc(
      "tools/call", id: 1, params: #"{"name":"list_connections","arguments":{}}"#)
    let clock = ContinuousClock()

    let start = clock.now
    async let slow = client.send(call)
    // Let the call reach the handler before the list is sent.
    try await Task.sleep(for: .milliseconds(200))
    let list = try await client.send(MCPTestClient.rpc("tools/list", id: 2))
    let listDone = clock.now - start
    let slowReply = try await slow
    let slowDone = clock.now - start
    #expect(list.status == 200)
    #expect(slowReply.status == 200)
    #expect(slowReply.elapsed >= delay)
    #expect(list.elapsed < slowReply.elapsed / 2)
    #expect(listDone < slowDone)

    await server.stop()

    // Each call waits in the handler for the other: a serial server times the first one out.
    let pairServer = MCPHTTPServer(
      handler: MCPJSONRPC.handler(
        tools: SlowTools(barrier: Rendezvous(parties: 2)), version: "spike"))
    let pairClient = MCPTestClient(
      port: try await pairServer.start(.init(port: 0, token: token)), token: token)
    let pairStart = clock.now
    async let first = pairClient.send(call)
    async let second = pairClient.send(
      MCPTestClient.rpc("tools/call", id: 3, params: #"{"name":"list_connections"}"#))
    let (one, two) = try await (first, second)
    let pair = clock.now - pairStart
    #expect(one.status == 200 && two.status == 200)
    for reply in [one, two] {
      let content = reply.result?["content"] as? [[String: Any]]
      #expect(content?.first?["text"] as? String == "met")
    }

    report(
      "MCP-SPIKE concurrency: slow tools/call \(slowReply.elapsed), concurrent tools/list"
        + " \(list.elapsed) (list done at \(listDone), call done at \(slowDone));"
        + " two calls that wait for each other took \(pair) (\(one.elapsed), \(two.elapsed))")
    await pairServer.stop()
  }
}
