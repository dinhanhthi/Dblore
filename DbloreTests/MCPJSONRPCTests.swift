// MCPJSONRPCTests.swift
// The MCP JSON-RPC handler behind the HTTP listener: initialize and version negotiation, ping,
// tools/list and tools/call against a fake tool service, JSON-RPC errors, the Accept and
// MCP-Protocol-Version headers, and cancellation of a slow tools/call.

import Foundation
import Testing
import os

@testable import Dblore

@Suite("MCP JSON-RPC")
struct MCPJSONRPCTests {
  private struct FakeTools: MCPToolCalling {
    var delay: Duration?

    var tools: [MCPToolDefinition] { MCPToolService.tools }

    func call(_ name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
      if let delay { try? await Task.sleep(for: delay) }
      switch name {
      case "list_connections": return MCPToolResult(text: "[]", isError: false)
      case "run_query":
        return MCPToolResult(
          text: "sql=\(arguments["sql"].map { "\($0)" } ?? "nil")", isError: true)
      default: return MCPToolResult(text: "Unknown tool.", isError: true)
      }
    }
  }

  private func handler(
    delay: Duration? = nil, timeout: Duration = .seconds(60),
    writeTimeout: Duration = .seconds(60)
  ) -> MCPHTTPServer.Handler {
    MCPJSONRPC.handler(
      tools: FakeTools(delay: delay), version: "9.9", timeout: timeout, writeTimeout: writeTimeout)
  }

  private func request(
    _ body: String, accept: String? = "application/json, text/event-stream",
    protocolVersion: String? = nil
  ) -> MCPHTTPRequest {
    var headers = ["Content-Type": "application/json", "Host": "127.0.0.1:41730"]
    if let accept { headers["Accept"] = accept }
    if let protocolVersion { headers["MCP-Protocol-Version"] = protocolVersion }
    return MCPHTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data(body.utf8))
  }

  private func rpc(_ method: String, id: Int = 1, params: String? = nil) -> String {
    let params = params.map { #","params":\#($0)"# } ?? ""
    return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"\#(params)}"#
  }

  private func initialize(_ version: String) -> String {
    rpc(
      "initialize",
      params: #"{"protocolVersion":"\#(version)","capabilities":{},"#
        + #""clientInfo":{"name":"test","version":"1"}}"#)
  }

  private func json(_ response: MCPHTTPResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }

  private func result(_ response: MCPHTTPResponse) throws -> [String: Any] {
    try #require(json(response)["result"] as? [String: Any])
  }

  private func errorCode(_ response: MCPHTTPResponse) throws -> Int? {
    (try json(response)["error"] as? [String: Any])?["code"] as? Int
  }

  @Test(
    "initialize echoes a supported protocol version; an unknown one gets the latest",
    arguments: [
      ("2025-06-18", "2025-06-18"), ("2025-03-26", "2025-03-26"), ("1999-01-01", "2025-11-25"),
    ])
  func initializeNegotiates(requested: String, negotiated: String) async throws {
    let response = await handler()(request(initialize(requested)))
    #expect(response.status == 200)
    #expect(response.headers["Content-Type"] == "application/json")
    let result = try result(response)
    #expect(result["protocolVersion"] as? String == negotiated)
    let info = try #require(result["serverInfo"] as? [String: Any])
    #expect(info["name"] as? String == "Dblore")
    #expect(info["version"] as? String == "9.9")
    let capabilities = try #require(result["capabilities"] as? [String: Any])
    #expect(capabilities["tools"] != nil)
    #expect(Set(capabilities.keys) == ["tools"])
  }

  @Test("A second initialize on the same handler succeeds (stateless endpoint)")
  func initializeTwice() async throws {
    let handle = handler()
    for _ in 0..<2 {
      let response = await handle(request(initialize("2025-06-18")))
      #expect(try result(response)["protocolVersion"] as? String == "2025-06-18")
    }
  }

  @Test("notifications/initialized is 202 with an empty body")
  func initializedNotification() async {
    let response = await handler()(
      request(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    #expect(response.status == 202)
    #expect(response.body.isEmpty)
  }

  @Test("ping answers an empty result")
  func ping() async throws {
    let response = await handler()(request(rpc("ping", id: 7)))
    #expect(response.status == 200)
    #expect(try json(response)["id"] as? Int == 7)
    #expect(try result(response).isEmpty)
  }

  @Test("tools/list returns the four tools with their input schemas")
  func toolsList() async throws {
    let response = await handler()(request(rpc("tools/list")))
    let tools = try #require(try result(response)["tools"] as? [[String: Any]])
    #expect(
      tools.compactMap { $0["name"] as? String }
        == ["list_connections", "list_tables", "describe_table", "run_query"])
    let runQuery = try #require(tools.last)
    #expect((runQuery["description"] as? String)?.contains("untrusted") == true)
    let schema = try #require(runQuery["inputSchema"] as? [String: Any])
    #expect(schema["type"] as? String == "object")
    #expect(Set(schema["required"] as? [String] ?? []) == ["connection_id", "sql"])
    let maxRows = try #require(
      (schema["properties"] as? [String: Any])?["max_rows"] as? [String: Any])
    #expect(maxRows["maximum"] as? Int == 1_000)
  }

  @Test("tools/call maps the tool result to one text content and isError")
  func toolsCall() async throws {
    let handle = handler()
    let success = try result(
      await handle(request(rpc("tools/call", params: #"{"name":"list_connections"}"#))))
    #expect(success["isError"] as? Bool ?? false == false)
    let content = try #require(success["content"] as? [[String: Any]])
    #expect(content.count == 1)
    #expect(content.first?["type"] as? String == "text")
    #expect(content.first?["text"] as? String == "[]")

    let failure = try result(
      await handle(
        request(
          rpc("tools/call", params: #"{"name":"run_query","arguments":{"sql":"select 1"}}"#))))
    #expect(failure["isError"] as? Bool == true)
    let text = (failure["content"] as? [[String: Any]])?.first?["text"] as? String
    #expect(text == #"sql=string("select 1")"#)
  }

  @Test("An unknown tool is an isError result, not a JSON-RPC error")
  func unknownTool() async throws {
    let response = await handler()(request(rpc("tools/call", params: #"{"name":"nope"}"#)))
    #expect(try errorCode(response) == nil)
    #expect(try result(response)["isError"] as? Bool == true)
  }

  @Test("An unknown method is -32601 in a 200 response")
  func unknownMethod() async throws {
    let response = await handler()(request(rpc("resources/list", id: 3)))
    #expect(response.status == 200)
    #expect(try errorCode(response) == -32601)
    #expect(try json(response)["id"] as? Int == 3)
  }

  @Test(
    "Malformed JSON, an empty body and a batch array are 400 with -32700",
    arguments: ["{not json", "", #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#])
  func parseError(body: String) async throws {
    let response = await handler()(request(body))
    #expect(response.status == 400)
    #expect(try errorCode(response) == -32700)
  }

  @Test("Accept must include application/json: combined passes, missing or SSE-only is 406")
  func acceptHeader() async throws {
    let handle = handler()
    #expect(await handle(request(rpc("ping"), accept: "application/json")).status == 200)
    #expect(
      await handle(request(rpc("ping"), accept: "application/json, text/event-stream")).status
        == 200)
    let missing = await handle(request(rpc("ping"), accept: nil))
    #expect(missing.status == 406)
    #expect(try errorCode(missing) == -32600)
    #expect(await handle(request(rpc("ping"), accept: "text/event-stream")).status == 406)
  }

  @Test("MCP-Protocol-Version after initialize: supported or absent passes, unknown is 400")
  func protocolVersionHeader() async throws {
    let handle = handler()
    for version in ["2025-06-18", "2025-03-26", nil] {
      #expect(await handle(request(rpc("tools/list"), protocolVersion: version)).status == 200)
    }
    let unknown = await handle(request(rpc("tools/list"), protocolVersion: "1999-01-01"))
    #expect(unknown.status == 400)
    #expect(try errorCode(unknown) == -32600)
    // initialize carries its version in the body, so the header is not checked.
    #expect(
      await handle(request(initialize("2025-06-18"), protocolVersion: "1999-01-01")).status
        == 200)
  }

  @Test("Cancelling a slow tools/call returns promptly")
  func cancellation() async {
    let handle = handler(delay: .seconds(30))
    let call = request(rpc("tools/call", params: #"{"name":"list_connections"}"#))
    let start = ContinuousClock.now
    let task = Task { await handle(call) }
    try? await Task.sleep(for: .milliseconds(200))
    task.cancel()
    _ = await task.value
    #expect(ContinuousClock.now - start < .seconds(5))
  }

  @Test("A request still running after the timeout is cancelled and answered 504")
  func timeout() async {
    let handle = handler(delay: .seconds(30), timeout: .milliseconds(300))
    let start = ContinuousClock.now
    let response = await handle(
      request(rpc("tools/call", params: #"{"name":"list_connections"}"#)))
    #expect(response.status == 504)
    #expect(ContinuousClock.now - start < .seconds(5))
  }

  @Test("An execute_write call gets the write timeout, not the short one")
  func writeTimeout() async {
    let handle = handler(
      delay: .seconds(1), timeout: .milliseconds(300), writeTimeout: .seconds(3))
    let response = await handle(
      request(rpc("tools/call", params: #"{"name":"execute_write"}"#)))
    #expect(response.status == 200)
  }

  @Test(
    "Only a body that cannot call execute_write gets the short timeout",
    arguments: [
      (
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_connections"}}"#,
        true
      ),
      (#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, true),
      (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"execute_write"}}"#, false),
      (
        #"[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"execute_write"}}]"#,
        false
      ),
      ("{not json", false),
    ])
  func shortTimeoutOnlyWithoutWrite(body: String, short: Bool) {
    #expect(MCPJSONRPC.cannotCallWrite(Data(body.utf8)) == short)
  }

  @Test(
    "Cancelling a request the SDK never answers returns promptly",
    arguments: [
      #"{"jsonrpc":"2.0","id":1,"method":"ping","result":{}}"#,
      #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
    ])
  func cancellationUnanswered(body: String) async throws {
    let handle = handler()
    let returned = OSAllocatedUnfairLock(initialState: false)
    let call = request(body)
    let task = Task {
      _ = await handle(call)
      returned.withLock { $0 = true }
    }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()
    let deadline = ContinuousClock.now + .seconds(5)
    while !returned.withLock({ $0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(returned.withLock { $0 })
  }
}
