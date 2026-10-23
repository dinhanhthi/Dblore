// MCPJSONRPC.swift
// The JSON-RPC side of the MCP endpoint, as the `MCPHTTPServer` handler: swift-sdk's `Server`
// behind a `StatelessHTTPServerTransport` (JSON responses, no SSE, no session). Each request
// gets its own Server and transport: the SDK refuses a second initialize on one Server and keys
// in-flight requests by JSON-RPC id only, so a shared one would break a reconnecting client and
// mix up two clients' ids. The Server is not strict, so tools/list and tools/call work without
// an initialize on the same instance.
// The SDK checks Accept (must include application/json, else 406), Content-Type and
// MCP-Protocol-Version (an unsupported one is 400); Host, Origin and the token were checked by
// the listener. Version negotiation is the SDK's: a supported version is echoed, any other gets
// the SDK's latest.
// A cancelled request (the listener stopping) cancels the tool call's task and stops the
// Server, so the transport returns at once, also for a request the Server never answers; the
// handler then waits for the tool call to end. A request still running after its timeout is
// cancelled that way and answered 504, so a request the SDK never answers cannot hold its task;
// a cancelled write approval is denied. A request is cut after `timeout` (60 s by default, past
// the sessions' 30 s statement timeout) unless it may call execute_write: a tools/call of
// execute_write, or a body that is not one JSON object (a batch, unreadable JSON), gets
// `writeTimeout`, which covers the longest write: queued behind `maxWaiting - 1` requests and
// shown for its own 120 s each (3 x 120 s), then the connect (`writeConnectAllowance`) and the
// sessions' 30 s statement timeout, so an approved write is not cut by the request timeout.
// tools/list is built per request (`listedTools`): execute_write comes and goes with the write
// settings without a restart. A tool call sees the request's User-Agent as
// `MCPToolService.clientName` (shown, not trusted, in the write approval).

import Foundation
import MCP
import os

/// What the JSON-RPC layer needs from the tools; `MCPToolService` in the app, fakes in tests.
nonisolated protocol MCPToolCalling: Sendable {
  var tools: [MCPToolDefinition] { get }
  /// What tools/list shows now; `tools` unless the implementation lists more
  func listedTools() async -> [MCPToolDefinition]
  func call(_ name: String, arguments: [String: JSONValue]) async -> MCPToolResult
}

nonisolated extension MCPToolCalling {
  func listedTools() async -> [MCPToolDefinition] { tools }
}

nonisolated extension MCPToolService: MCPToolCalling {
  var tools: [MCPToolDefinition] { Self.tools }
}

nonisolated enum MCPJSONRPC {
  static let serverName = "Dblore"

  /// Timeout of every request that cannot call execute_write
  static let defaultTimeout = Duration.seconds(60)

  /// What `writeTimeout` leaves for the writable manager's connect after an approval
  static let writeConnectAllowance = Duration.seconds(60)

  /// Timeout of a request that may call execute_write
  static let writeTimeout =
    MCPWriteApprovalCenter.defaultTimeout * MCPWriteApprovalCenter.maxWaiting
    + writeConnectAllowance + .seconds(MCPConnectionPool.statementTimeoutSeconds)

  /// Longest client name passed on from User-Agent
  private static let maxClientNameCharacters = 80

  static func handler(
    tools: any MCPToolCalling,
    version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
    timeout: Duration = defaultTimeout, writeTimeout: Duration = writeTimeout
  ) -> MCPHTTPServer.Handler {
    { request in
      let limit = cannotCallWrite(request.body) ? timeout : writeTimeout
      return await withTaskGroup(of: MCPHTTPResponse?.self) { group in
        group.addTask { await handle(request, tools: tools, version: version) }
        group.addTask {
          try? await Task.sleep(for: limit)
          return nil
        }
        // The first to finish wins; the other is cancelled (and awaited by the group).
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
          ?? response(.error(statusCode: 504, .internalError("The request timed out.")))
      }
    }
  }

  private static func handle(
    _ request: MCPHTTPRequest, tools: any MCPToolCalling, version: String
  ) async -> MCPHTTPResponse {
    let call = MCPToolCall()
    let client = clientName(request.headers)
    let server = MCP.Server(
      name: serverName, version: version, capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in
      ListTools.Result(
        tools: await tools.listedTools().map {
          Tool(
            name: $0.name, description: $0.description,
            inputSchema: convert($0.inputSchema) ?? .object([:]))
        })
    }
    await server.withMethodHandler(CallTool.self) { params in
      let arguments: [String: JSONValue] = convert(params.arguments ?? [:]) ?? [:]
      let result = await MCPToolService.$clientName.withValue(client) {
        await call.run { await tools.call(params.name, arguments: arguments) }
      }
      return CallTool.Result(
        content: [.text(text: result.text, annotations: nil, _meta: nil)], isError: result.isError)
    }
    // No OriginValidator: the listener already checked Origin against its bound port.
    let transport = StatelessHTTPServerTransport(
      validationPipeline: StandardValidationPipeline(validators: [
        AcceptHeaderValidator(mode: .jsonOnly), ContentTypeValidator(),
        ProtocolVersionValidator(),
      ]))
    do {
      try await server.start(transport: transport)
    } catch {
      await server.stop()
      return response(.error(statusCode: 500, .internalError("The MCP server could not start.")))
    }
    let sdkResponse = await withTaskCancellationHandler {
      await transport.handleRequest(
        HTTPRequest(
          method: request.method, headers: request.headers, body: request.body,
          path: request.path))
    } onCancel: {
      call.cancel()
      // Ends the wait on a request the Server never answers (500 "Connection closed").
      Task { await server.stop() }
    }
    await server.stop()
    await call.wait()
    return response(sdkResponse)
  }

  /// `body` is one JSON object that is not a tools/call of execute_write. Anything else (a
  /// batch, unreadable JSON) may call it, so it keeps `writeTimeout`: a misread body gets the
  /// longer wait, never cuts an approved write short.
  static func cannotCallWrite(_ body: Data) -> Bool {
    guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      return false
    }
    guard message["method"] as? String == "tools/call" else { return true }
    return (message["params"] as? [String: Any])?["name"] as? String != "execute_write"
  }

  /// The User-Agent (any case), printable ASCII only and cut, or the default name.
  private static func clientName(_ headers: [String: String]) -> String {
    let agent =
      headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?
      .value ?? ""
    let printable = String(
      String.UnicodeScalarView(agent.unicodeScalars.filter { (0x20...0x7E).contains($0.value) })
    )
    .trimmingCharacters(in: .whitespaces)
    return printable.isEmpty
      ? MCPToolService.clientName : String(printable.prefix(maxClientNameCharacters))
  }

  private static func response(_ response: HTTPResponse) -> MCPHTTPResponse {
    switch response {
    case .stream:
      // The stateless transport never streams.
      return Self.response(.error(statusCode: 500, .internalError("Streaming is not supported.")))
    default:
      return MCPHTTPResponse(
        status: response.statusCode, headers: response.headers, body: response.bodyData ?? Data())
    }
  }

  /// Between the two Codable JSON models (`JSONValue` and the SDK's `Value`).
  private static func convert<Input: Encodable, Output: Decodable>(_ value: Input) -> Output? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(Output.self, from: data)
  }
}

/// The tool call of one request, so cancelling the request cancels the call; a cancel before
/// the call starts cancels it as it starts.
private nonisolated final class MCPToolCall: Sendable {
  private struct State {
    var cancelled = false
    var task: Task<MCPToolResult, Never>?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  func run(_ body: @escaping @Sendable () async -> MCPToolResult) async -> MCPToolResult {
    let task = Task { await body() }
    state.withLock { state in
      state.task = task
      if state.cancelled { task.cancel() }
    }
    return await task.value
  }

  /// Waits for a call still running after its request was cancelled.
  func wait() async {
    _ = await state.withLock { $0.task }?.value
  }

  func cancel() {
    let task = state.withLock { state in
      state.cancelled = true
      return state.task
    }
    task?.cancel()
  }
}
