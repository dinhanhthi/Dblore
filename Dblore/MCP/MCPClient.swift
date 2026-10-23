// MCPClient.swift
// A client for outside MCP servers over Streamable HTTP (spec 2025-06-18): one POST per JSON-RPC
// message with `Accept: application/json, text/event-stream`; a request is answered with one
// JSON object or an SSE stream (read with `MCPSSESplitter` until the event carrying its id), a
// notification with 202. initialize sends no `MCP-Protocol-Version`; every later message sends
// the negotiated one, and the `Mcp-Session-Id` the server returned, if any. A 404 to a message
// that carried a session id re-initializes without it and retries that message once, except
// tools/call, which may not be safe to repeat: it throws `sessionExpired` after the new session.
// Safety: https only, or http to 127.0.0.1, ::1 or localhost, checked before any request; no
// credentials in the URL; a static Bearer token (no OAuth); every redirect refused, so the token
// never follows one; 30 s per request, total; responses over 1 MiB refused by Content-Length
// and while they stream. Errors never hold the token, the request or the raw body; a server's
// message is sanitized and capped. Server text (tool names, descriptions, schemas, results) is
// untrusted: hidden characters are stripped and sizes capped here, at the boundary, and a
// tools/call is sent only through `OutsideMCPToolGate`, run on the live server once the call's
// turn comes. Calls on one client run one at a time.

import CryptoKit
import Foundation

nonisolated enum MCPClientError: Error, Equatable, Sendable, LocalizedError {
  case invalidURL
  /// A scheme other than https, or http to a host that is not loopback
  case insecureURL
  case credentialsInURL
  case invalidToken
  case redirectRefused
  case responseTooLarge
  case unauthorized(status: Int)
  case http(status: Int)
  /// A 404 to a message that carried a session id. A new session is started; a tools/call is
  /// not sent again.
  case sessionExpired
  case unexpectedContentType
  case invalidResponse
  case noResponse
  case unsupportedProtocolVersion(String)
  /// A JSON-RPC error; the message is the server's, sanitized and capped
  case rpc(code: Int, message: String)
  case timedOut
  /// A `URLError` code
  case network(code: Int)
  /// `OutsideMCPToolGate` refusals, checked before any request
  case serverDisabled
  /// The server is no longer in Settings > MCP
  case serverRemoved
  case invalidToolName
  case toolNotAllowed
  case toolNotListed
  case toolChanged
  /// The server's id or URL is not this client's
  case wrongServer

  var errorDescription: String? {
    switch self {
    case .invalidURL: "Enter a full URL, such as https://mcp.example.com/mcp."
    case .insecureURL: "Use https. Plain http is allowed only for 127.0.0.1, ::1 and localhost."
    case .credentialsInURL:
      "Remove the user name and password from the URL. Put the token in the Token field."
    case .invalidToken:
      "The token can hold only visible ASCII characters, up to \(MCPClient.maxTokenLength)."
    case .redirectRefused:
      "The server answered with a redirect, which Dblore does not follow. Enter the final URL."
    case .responseTooLarge: "The server's answer is larger than 1 MB."
    case .unauthorized(let status): "The server refused the token (HTTP \(status))."
    case .http(let status): "The server answered HTTP \(status)."
    case .sessionExpired: "The server ended the session. A new one was started; try again."
    case .unexpectedContentType: "The server's answer is neither JSON nor an event stream."
    case .invalidResponse: "The server's answer is not a valid MCP message."
    case .noResponse: "The server closed the stream without an answer."
    case .unsupportedProtocolVersion(let version):
      "The server uses MCP version \(version), which Dblore does not support."
    case .rpc(let code, let message): "The server returned an error (\(code)): \(message)"
    case .timedOut: "The server did not answer within \(Int(MCPClient.timeout)) seconds."
    case .network(let code): URLError(URLError.Code(rawValue: code)).localizedDescription
    case .serverDisabled: "The server is turned off in Settings > MCP."
    case .serverRemoved: "The server was removed in Settings > MCP."
    case .invalidToolName: "The tool name is not valid."
    case .toolNotAllowed: "The tool is not ticked in Settings > MCP."
    case .toolNotListed: "The server no longer lists the tool."
    case .toolChanged:
      "The tool's description or input changed since it was ticked. Review it and tick it again in Settings > MCP."
    case .wrongServer: "The tool belongs to another server."
    }
  }
}

nonisolated struct MCPServerInfo: Equatable, Sendable {
  var name: String
  var version: String
  var protocolVersion: String
}

/// A tool as the server lists it, sanitized by the client but still untrusted. The name is
/// `[A-Za-z0-9_.-]{1,128}`; the description is cut to `MCPClient.maxDescriptionLength` scalars;
/// every string in the schema to `MCPClient.maxSchemaStringLength`, and the whole schema is at
/// most `MCPClient.maxSchemaBytes` as canonical JSON.
nonisolated struct MCPClientTool: Equatable, Sendable {
  let name: String
  let description: String
  let inputSchema: JSONValue
  /// SHA-256 (lowercase hex) of the name, the description and the canonical schema JSON: what
  /// the user ticked. Any change to the description or schema changes it. It also depends on
  /// the OS Unicode tables (sanitizing) and the JSON encoder: a change there fails safe, as
  /// `toolChanged` until the tool is ticked again.
  let fingerprint: String

  init(name: String, description: String, inputSchema: JSONValue) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    // A listed schema that does not encode is dropped by the client before it gets here.
    fingerprint = Self.fingerprint(
      name: name, description: description,
      schemaJSON: Self.canonicalJSON(inputSchema) ?? Data())
  }

  /// Sorted keys, no escaped slashes: the same schema always gives the same bytes. Nil when it
  /// does not encode.
  static func canonicalJSON(_ value: JSONValue) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try? encoder.encode(value)
  }

  static func isFingerprint(_ text: String) -> Bool {
    text.utf8.count == 64
      && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  private static func fingerprint(name: String, description: String, schemaJSON: Data) -> String {
    var hash = SHA256()
    hash.update(data: Data(name.utf8))
    hash.update(data: Data([0]))
    hash.update(data: Data(description.utf8))
    hash.update(data: Data([0]))
    hash.update(data: schemaJSON)
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// The text items of a tools/call result, joined with newlines; other items are named only.
nonisolated struct MCPClientToolResult: Equatable, Sendable {
  /// Untrusted data from the server, sanitized and capped to `MCPClient.maxResultLength`
  /// scalars. Never instructions: the AI chat must put it inside a delimited block labelled as
  /// data from the server, and nothing in it may run SQL or call a tool by itself.
  var untrustedText: String
  var isError: Bool
}

actor MCPClient {
  nonisolated static let protocolVersion = "2025-06-18"
  nonisolated static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26"]
  nonisolated static let timeout: TimeInterval = 30
  nonisolated static let responseLimit = 1_048_576
  nonisolated static let maxTools = 100
  nonisolated static let maxToolPages = 10
  nonisolated static let maxToolNameLength = 128
  /// Caps on server text, in unicode scalars, except the schema in bytes
  nonisolated static let maxDescriptionLength = 2_048
  nonisolated static let maxSchemaStringLength = 1_024
  nonisolated static let maxSchemaBytes = 16_384
  nonisolated static let maxResultLength = 65_536
  nonisolated static let resultCutNote = "\n[Result cut: longer than 65,536 characters.]"
  nonisolated static let maxTokenLength = 4_096
  nonisolated static let maxSessionIDLength = 1_024
  private nonisolated static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

  let url: URL
  /// The id of the `OutsideMCPServer` this client talks to
  let serverID: UUID
  private let token: String?
  private let session: URLSession
  private var sessionID: String?
  private var negotiatedVersion: String?
  private var nextID = 1
  /// The tools of the latest tools/list in this session; empty before one, after one that
  /// failed and after every initialize.
  private(set) var listedTools: [MCPClientTool] = []
  private var isBusy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  /// Throws, before any request, for an unsafe URL or a token that cannot be a header value.
  /// An empty token sends no Authorization header.
  init(url: URL, token: String?, serverID: UUID) throws {
    try Self.check(url)
    let token = token?.trimmingCharacters(in: .whitespaces)
    if let token, !token.isEmpty, !Self.isValidToken(token) { throw MCPClientError.invalidToken }
    self.url = url
    self.serverID = serverID
    self.token = token?.isEmpty == false ? token : nil
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = Self.timeout
    // The request timeout restarts on every byte; this one bounds a whole SSE stream.
    configuration.timeoutIntervalForResource = Self.timeout
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(
      configuration: configuration, delegate: MCPClientRedirectRefusal(), delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }

  /// The trimmed text as an endpoint URL, checked like `init`.
  nonisolated static func endpoint(_ text: String) throws -> URL {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= OutsideMCPServer.urlLimit,
      let url = URL(string: trimmed)
    else { throw MCPClientError.invalidURL }
    try check(url)
    return url
  }

  /// https, or http to exactly 127.0.0.1, ::1 or localhost; no user name or password.
  nonisolated static func check(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased(),
      let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
    else { throw MCPClientError.invalidURL }
    guard url.user == nil, url.password == nil else { throw MCPClientError.credentialsInURL }
    switch scheme {
    case "https":
      return
    case "http":
      let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      guard loopbackHosts.contains(bare) else { throw MCPClientError.insecureURL }
    default:
      throw MCPClientError.insecureURL
    }
  }

  /// Visible ASCII (0x21-0x7E) only, so it cannot break the header.
  nonisolated static func isValidToken(_ token: String) -> Bool {
    !token.isEmpty && token.utf8.count <= maxTokenLength && isVisibleASCII(token)
  }

  /// `[A-Za-z0-9_.-]`, 1 to 128 characters.
  nonisolated static func isValidToolName(_ name: String) -> Bool {
    (1...maxToolNameLength).contains(name.utf8.count)
      && name.utf8.allSatisfy {
        (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
          || $0 == 0x5F || $0 == 0x2E || $0 == 0x2D
      }
  }

  private nonisolated static func isVisibleASCII(_ text: String) -> Bool {
    text.utf8.allSatisfy { (0x21...0x7E).contains($0) }
  }

  // MARK: - Lifecycle and methods

  /// initialize, then notifications/initialized. Starts a new session.
  func connect() async throws -> MCPServerInfo {
    await acquire()
    defer { release() }
    return try await initialize()
  }

  /// A new session needs its own tools/list before any tools/call.
  private func initialize() async throws -> MCPServerInfo {
    listedTools = []
    sessionID = nil
    negotiatedVersion = nil
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    let (result, returnedSession) = try await send(
      "initialize",
      params: .object([
        "protocolVersion": .string(Self.protocolVersion),
        "capabilities": .object([:]),
        "clientInfo": .object(["name": .string("Dblore"), "version": .string(version)]),
      ]))
    if let returnedSession {
      guard returnedSession.utf8.count <= Self.maxSessionIDLength,
        Self.isVisibleASCII(returnedSession)
      else { throw MCPClientError.invalidResponse }
      sessionID = returnedSession
    }
    guard case .string(let negotiated)? = result["protocolVersion"] else {
      throw MCPClientError.invalidResponse
    }
    guard Self.supportedProtocolVersions.contains(negotiated) else {
      throw MCPClientError.unsupportedProtocolVersion(OutsideMCPText.display(negotiated, limit: 32))
    }
    negotiatedVersion = negotiated
    do {
      try await notify("notifications/initialized")
    } catch {
      negotiatedVersion = nil
      throw error
    }
    var name = ""
    var serverVersion = ""
    if case .object(let info)? = result["serverInfo"] {
      if case .string(let value)? = info["name"] {
        name = OutsideMCPText.display(value, limit: 128)
      }
      if case .string(let value)? = info["version"] {
        serverVersion = OutsideMCPText.display(value, limit: 64)
      }
    }
    return MCPServerInfo(name: name, version: serverVersion, protocolVersion: negotiated)
  }

  /// Follows `nextCursor` up to `maxToolPages` pages and `maxTools` tools; a repeated cursor
  /// ends the list. Tools with a bad or repeated name, or a schema that does not encode or is
  /// over `maxSchemaBytes`, are dropped. The result becomes `listedTools`, the list `callTool` checks against.
  func listTools() async throws -> [MCPClientTool] {
    await acquire()
    defer { release() }
    listedTools = []
    let tools = try await fetchTools()
    listedTools = tools
    return tools
  }

  private func fetchTools() async throws -> [MCPClientTool] {
    var tools: [MCPClientTool] = []
    var names = Set<String>()
    var cursor: String?
    var cursors = Set<String>()
    for _ in 0..<Self.maxToolPages {
      let params: [String: JSONValue] = cursor.map { ["cursor": .string($0)] } ?? [:]
      let result = try await request("tools/list", params: .object(params))
      guard case .array(let items)? = result["tools"] else { throw MCPClientError.invalidResponse }
      for item in items {
        guard let tool = Self.tool(item), names.insert(tool.name).inserted else { continue }
        tools.append(tool)
        if tools.count == Self.maxTools { return tools }
      }
      guard case .string(let next)? = result["nextCursor"], !next.isEmpty,
        cursors.insert(next).inserted
      else { break }
      cursor = next
    }
    return tools
  }

  /// The only way to send a tools/call. Once the call's turn comes, `current` is asked for the
  /// live server with this client's `serverID` (the store's copy, read on the main actor); it
  /// must still exist, have this client's id and URL, and the tool pass `OutsideMCPToolGate`
  /// against `listedTools`, all before any request. So a server turned off or a tool unticked
  /// while the call waited is refused. An expired session is renewed but the call is not
  /// repeated.
  func callTool(
    _ name: String, arguments: [String: JSONValue],
    current: @MainActor @Sendable (UUID) -> OutsideMCPServer?
  ) async throws -> MCPClientToolResult {
    await acquire()
    defer { release() }
    guard let server = await current(serverID) else { throw MCPClientError.serverRemoved }
    guard server.id == serverID, (try? Self.endpoint(server.url)) == url else {
      throw MCPClientError.wrongServer
    }
    let tool = try OutsideMCPToolGate.allowedTool(name, on: server, listed: listedTools)
    return try await send(tool: tool.name, arguments: arguments)
  }

  private func send(
    tool name: String, arguments: [String: JSONValue]
  ) async throws -> MCPClientToolResult {
    guard Self.isValidToolName(name) else { throw MCPClientError.invalidToolName }
    let result = try await request(
      "tools/call", params: .object(["name": .string(name), "arguments": .object(arguments)]),
      repeatsAfterNewSession: false)
    guard case .array(let content)? = result["content"] else {
      throw MCPClientError.invalidResponse
    }
    let parts = content.compactMap { item -> String? in
      guard case .object(let fields) = item, case .string(let type)? = fields["type"] else {
        return nil
      }
      if type == "text", case .string(let text)? = fields["text"] { return text }
      return "[\(OutsideMCPText.display(type, limit: 32)) content omitted]"
    }
    return MCPClientToolResult(
      untrustedText: OutsideMCPText.untrusted(
        parts.joined(separator: "\n"), limit: Self.maxResultLength, note: Self.resultCutNote),
      isError: result["isError"] == .bool(true))
  }

  private nonisolated static func tool(_ item: JSONValue) -> MCPClientTool? {
    guard case .object(let fields) = item, case .string(let name)? = fields["name"],
      isValidToolName(name)
    else { return nil }
    var description = ""
    if case .string(let text)? = fields["description"] {
      description = OutsideMCPText.untrusted(text, limit: maxDescriptionLength)
    }
    let schema: JSONValue
    if case .object(let object)? = fields["inputSchema"] {
      schema = sanitized(.object(object))
    } else {
      schema = .object(["type": .string("object")])
    }
    guard let json = MCPClientTool.canonicalJSON(schema), json.count <= maxSchemaBytes else {
      return nil
    }
    return MCPClientTool(name: name, description: description, inputSchema: schema)
  }

  /// Every string capped and stripped of hidden characters. A key that would change is
  /// dropped with its value, so two keys can never merge into one.
  private nonisolated static func sanitized(_ value: JSONValue) -> JSONValue {
    switch value {
    case .string(let text):
      return .string(OutsideMCPText.untrusted(text, limit: maxSchemaStringLength))
    case .array(let items):
      return .array(items.map(sanitized))
    case .object(let fields):
      var kept: [String: JSONValue] = [:]
      for (key, nested) in fields
      where !key.isEmpty && OutsideMCPText.untrusted(key, limit: maxSchemaStringLength) == key {
        kept[key] = sanitized(nested)
      }
      return .object(kept)
    case .null, .bool, .number:
      return value
    }
  }

  // MARK: - Transport

  /// Connects first when needed. An expired session is re-initialized, then the message is
  /// sent once more, or, when it must not repeat, `sessionExpired` is thrown.
  private func request(
    _ method: String, params: JSONValue?, repeatsAfterNewSession: Bool = true
  ) async throws -> [String: JSONValue] {
    if negotiatedVersion == nil { _ = try await initialize() }
    do {
      return try await send(method, params: params).result
    } catch MCPClientError.sessionExpired {
      _ = try await initialize()
      guard repeatsAfterNewSession else { throw MCPClientError.sessionExpired }
      return try await send(method, params: params).result
    }
  }

  /// One public call at a time, in arrival order: the actor alone would let calls interleave
  /// at every await, and two could each start a session.
  private func acquire() async {
    guard isBusy else {
      isBusy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  /// Hands the turn to the next waiting call, if any.
  private func release() {
    if waiters.isEmpty {
      isBusy = false
    } else {
      waiters.removeFirst().resume()
    }
  }

  private func send(
    _ method: String, params: JSONValue?
  ) async throws
    -> (result: [String: JSONValue], sessionID: String?)
  {
    let id = nextID
    nextID += 1
    let reply = try await Self.exchange(
      makeRequest(Envelope(id: id, method: method, params: params)), id: id,
      sentSession: sessionID != nil, session: session)
    guard let message = reply.message else { throw MCPClientError.noResponse }
    return (try Self.result(of: message), reply.sessionID)
  }

  private func notify(_ method: String) async throws {
    _ = try await Self.exchange(
      makeRequest(Envelope(id: nil, method: method, params: nil)), id: nil,
      sentSession: sessionID != nil, session: session)
  }

  private func makeRequest(_ envelope: Envelope) throws -> URLRequest {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let negotiatedVersion {
      request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
    }
    if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
    request.httpBody = try JSONEncoder().encode(envelope)
    return request
  }

  private nonisolated struct Envelope: Encodable {
    let jsonrpc = "2.0"
    let id: Int?
    let method: String
    let params: JSONValue?
  }

  private nonisolated struct Reply: Sendable {
    /// The JSON-RPC response to the request; nil for a notification
    let message: [String: JSONValue]?
    let sessionID: String?
  }

  /// One POST, off the actor so the byte loop does not hop. A request waits for the message
  /// with its id; a notification reads no body.
  @concurrent
  private nonisolated static func exchange(
    _ request: URLRequest, id: Int?, sentSession: Bool, session: URLSession
  ) async throws -> Reply {
    do {
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      guard let http = response as? HTTPURLResponse else { throw MCPClientError.invalidResponse }
      try checkStatus(http, requested: request.url, sentSession: sentSession)
      let returnedSession = http.value(forHTTPHeaderField: "Mcp-Session-Id")
      guard let id else { return Reply(message: nil, sessionID: returnedSession) }
      if http.expectedContentLength > Int64(responseLimit) {
        throw MCPClientError.responseTooLarge
      }
      let mediaType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
        .split(separator: ";", maxSplits: 1).first.map {
          $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
      let message: [String: JSONValue]?
      switch mediaType {
      case "application/json": message = try await readJSON(bytes, id: id)
      case "text/event-stream": message = try await readEvents(bytes, id: id)
      default: throw MCPClientError.unexpectedContentType
      }
      return Reply(message: message, sessionID: returnedSession)
    } catch {
      throw mapped(error)
    }
  }

  private nonisolated static func checkStatus(
    _ http: HTTPURLResponse, requested: URL?, sentSession: Bool
  ) throws {
    switch http.statusCode {
    case 200..<300: break
    case 300..<400: throw MCPClientError.redirectRefused
    case 401, 403: throw MCPClientError.unauthorized(status: http.statusCode)
    case 404 where sentSession: throw MCPClientError.sessionExpired
    default: throw MCPClientError.http(status: http.statusCode)
    }
    // The redirect delegate refuses every redirect; this also holds if it ever did not.
    guard let final = http.url, let requested, final.scheme == requested.scheme,
      final.host == requested.host, final.port == requested.port
    else { throw MCPClientError.redirectRefused }
  }

  private nonisolated static func readJSON(
    _ bytes: URLSession.AsyncBytes, id: Int
  ) async throws
    -> [String: JSONValue]
  {
    var data = Data()
    for try await byte in bytes {
      guard data.count < responseLimit else { throw MCPClientError.responseTooLarge }
      data.append(byte)
    }
    guard let message = response(in: data, id: id) else { throw MCPClientError.invalidResponse }
    return message
  }

  /// Skips notifications, server requests and responses to other ids.
  private nonisolated static func readEvents(
    _ bytes: URLSession.AsyncBytes, id: Int
  )
    async throws -> [String: JSONValue]
  {
    var splitter = MCPSSESplitter()
    var count = 0
    for try await byte in bytes {
      count += 1
      guard count <= responseLimit else { throw MCPClientError.responseTooLarge }
      if let event = splitter.feed(byte), let message = response(in: event, id: id) {
        return message
      }
    }
    if let event = splitter.finish(), let message = response(in: event, id: id) {
      return message
    }
    throw MCPClientError.noResponse
  }

  private nonisolated static func response(in event: MCPSSEEvent, id: Int) -> [String: JSONValue]? {
    guard event.event == "message" else { return nil }
    return response(in: Data(event.data.utf8), id: id)
  }

  /// The JSON-RPC response with `id`: a result or an error.
  private nonisolated static func response(in data: Data, id: Int) -> [String: JSONValue]? {
    guard let message = try? JSONDecoder().decode([String: JSONValue].self, from: data),
      message["id"] == .number(Double(id)), message["result"] != nil || message["error"] != nil
    else { return nil }
    return message
  }

  private nonisolated static func result(
    of message: [String: JSONValue]
  ) throws
    -> [String: JSONValue]
  {
    if case .object(let error)? = message["error"] {
      var code = 0
      var text = ""
      if case .number(let value)? = error["code"], let exact = Int(exactly: value) { code = exact }
      if case .string(let value)? = error["message"] { text = value }
      throw MCPClientError.rpc(code: code, message: OutsideMCPText.display(text, limit: 300))
    }
    guard case .object(let result)? = message["result"] else {
      throw MCPClientError.invalidResponse
    }
    return result
  }

  private nonisolated static func mapped(_ error: any Error) -> any Error {
    if error is MCPClientError || error is CancellationError { return error }
    guard let urlError = error as? URLError else { return MCPClientError.invalidResponse }
    switch urlError.code {
    case .timedOut: return MCPClientError.timedOut
    case .cancelled: return CancellationError()
    default: return MCPClientError.network(code: urlError.code.rawValue)
    }
  }
}

/// Refuses every redirect: the 3xx itself becomes the response, which the client refuses.
private nonisolated final class MCPClientRedirectRefusal: NSObject, URLSessionTaskDelegate,
  Sendable
{
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// One event of a `text/event-stream`.
nonisolated struct MCPSSEEvent: Equatable, Sendable {
  var event: String
  var data: String
}

/// Splits a `text/event-stream` into events, byte by byte (HTML SSE rules, minus `retry` and
/// last-event-id tracking): lines end with CR, LF or CRLF; a blank line ends an event; `data:`
/// lines are joined with "\n"; the event name defaults to `message`; comments, `id:` and
/// unknown fields are skipped; an event with no data is not dispatched.
nonisolated struct MCPSSESplitter: Sendable {
  private var line: [UInt8] = []
  private var afterCR = false
  private var name: String?
  private var data: [String] = []

  /// The event a blank line just ended, if any.
  mutating func feed(_ byte: UInt8) -> MCPSSEEvent? {
    if afterCR {
      afterCR = false
      if byte == 0x0A { return nil }
    }
    switch byte {
    case 0x0D:
      afterCR = true
      return endLine()
    case 0x0A:
      return endLine()
    default:
      line.append(byte)
      return nil
    }
  }

  /// The event still open when the stream ends: some servers skip the last blank line.
  mutating func finish() -> MCPSSEEvent? {
    if !line.isEmpty { _ = endLine() }
    return dispatch()
  }

  private mutating func endLine() -> MCPSSEEvent? {
    guard !line.isEmpty else { return dispatch() }
    let text = String(decoding: line, as: UTF8.self)
    line.removeAll(keepingCapacity: true)
    guard !text.hasPrefix(":") else { return nil }
    let field = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    var value = field.count > 1 ? field[1] : ""
    if value.hasPrefix(" ") { value = value.dropFirst() }
    switch field[0] {
    case "event": name = String(value)
    case "data": data.append(String(value))
    default: break
    }
    return nil
  }

  private mutating func dispatch() -> MCPSSEEvent? {
    defer {
      name = nil
      data = []
    }
    guard !data.isEmpty else { return nil }
    let event = name.flatMap { $0.isEmpty ? nil : $0 } ?? "message"
    return MCPSSEEvent(event: event, data: data.joined(separator: "\n"))
  }
}
