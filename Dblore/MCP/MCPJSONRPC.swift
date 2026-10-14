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
// handler then waits for the tool call to end. A request still running after `timeout` (longer
// than the sessions' 30 s statement timeout) is cancelled that way and answered 504, so a request
// the SDK never answers cannot hold its task.

import Foundation
import MCP
import os

/// What the JSON-RPC layer needs from the tools; `MCPToolService` in the app, fakes in tests.
nonisolated protocol MCPToolCalling: Sendable {
  var tools: [MCPToolDefinition] { get }
  func call(_ name: String, arguments: [String: JSONValue]) async -> MCPToolResult
}

nonisolated extension MCPToolService: MCPToolCalling {
  var tools: [MCPToolDefinition] { Self.tools }
}

nonisolated enum MCPJSONRPC {
  static let serverName = "Dblore"

  static let defaultTimeout = Duration.seconds(60)

  static func handler(
    tools: any MCPToolCalling,
    version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
    timeout: Duration = defaultTimeout
  ) -> MCPHTTPServer.Handler {
    let listed = tools.tools.map {
      Tool(
        name: $0.name, description: $0.description,
        inputSchema: convert($0.inputSchema) ?? .object([:]))
    }
    return { request in
      await withTaskGroup(of: MCPHTTPResponse?.self) { group in
        group.addTask { await handle(request, tools: tools, listed: listed, version: version) }
        group.addTask {
          try? await Task.sleep(for: timeout)
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
    _ request: MCPHTTPRequest, tools: any MCPToolCalling, listed: [Tool], version: String
  ) async -> MCPHTTPResponse {
    let call = MCPToolCall()
    let server = MCP.Server(
      name: serverName, version: version, capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: listed) }
    await server.withMethodHandler(CallTool.self) { params in
      let arguments: [String: JSONValue] = convert(params.arguments ?? [:]) ?? [:]
      let result = await call.run { await tools.call(params.name, arguments: arguments) }
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
