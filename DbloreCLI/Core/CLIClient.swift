// CLIClient.swift
// Talks to Dblore's MCP server on 127.0.0.1 only (never another host, no proxy, no redirect).
// Wire format (shared with the app's `MCPCLIPairingService`, permanent):
// - POST /cli/pair `{"code"}` -> 200 `{"token", "proofKey", "port", "id"}`; a pairing whose
//   port is not the port dialed is refused and not saved.
// - POST /cli/hello `{"id", "nonce": <32 random bytes, unpadded base64url>}` -> 200
//   `{"proof"}`, the HMAC-SHA256 (RFC 2104) keyed with the 32 bytes of the proof key over UTF-8
//   "dblore-cli-hello-v1", the nonce bytes and the dialed port as a big-endian UInt16. Every
//   command checks it before it sends the token, so neither a program squatting the port nor
//   one relaying to the real port receives it. A 401 means Dblore does not know this pairing.
// - POST /mcp, JSON-RPC tools/call with `Authorization: Bearer <token>`. A tool's refusal
//   and a failed query both come back as an isError text: the refusals are told apart by their
//   fixed texts (`refusalTexts`, from the app's MCP errors), anything else is a query error.
// The token and the proof key are never printed, and no response body is echoed.

import CryptoKit
import Foundation
import Security

/// What a command ends with when it does not succeed: printed on stderr, then exit `exitCode`
nonisolated struct CLIFailure: Error, Equatable, Sendable {
  let exitCode: CLIExitCode
  let message: String
}

nonisolated struct CLIHTTPResponse: Equatable, Sendable {
  let status: Int
  let body: Data
}

/// Why a POST got no HTTP answer. The client words it per request: before the token is sent
/// (pair, hello) or after (/mcp).
nonisolated enum CLITransportError: Error, Equatable, Sendable {
  /// Nothing listens on the port, or the connection was lost
  case unreachable
  case timedOut
  /// Any other failure, or an answer that is not HTTP
  case failed
}

/// One HTTP POST to 127.0.0.1. Throws `CLITransportError` when no HTTP answer comes back.
nonisolated protocol CLITransport: Sendable {
  func post(
    port: Int, path: String, headers: [String: String], body: Data, timeout: TimeInterval
  ) async throws -> CLIHTTPResponse
}

/// A saved pairing; also the /cli/pair answer
nonisolated struct CLICredentials: Codable, Equatable, Sendable, CustomStringConvertible {
  let token: String
  let proofKey: String
  let port: Int
  let id: String

  /// Never shows the token or the proof key
  var description: String { "CLICredentials(id: \(id), port: \(port))" }
}

/// A tools/call argument
nonisolated enum CLIArgument: Encodable, Equatable, Sendable {
  case string(String)
  case int(Int)

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let text): try container.encode(text)
    case .int(let number): try container.encode(number)
    }
  }
}

nonisolated struct CLIClient: Sendable {
  static let notRunning = "Dblore is not running or its MCP server is off (Settings > MCP)."
  static let helloLabel = "dblore-cli-hello-v1"
  /// Pair and hello answer at once
  static let shortTimeout: TimeInterval = 10
  /// Past the server's 60 s request timeout, so its own answer (504) arrives first
  static let toolTimeout: TimeInterval = 75

  let transport: any CLITransport
  var userAgent = "dblore"
  var randomBytes: @Sendable (Int) -> [UInt8] = CLIClient.secureRandomBytes

  /// Redeems `code` on `port` and returns the pairing to save.
  func pair(code: String, port: Int) async throws -> CLICredentials {
    let body = try JSONEncoder().encode(["code": code])
    let response = try await postBeforeToken(port: port, path: "/cli/pair", body: body)
    switch response.status {
    case 200: return try Self.decodePairResponse(response.body, dialedPort: port)
    case 401:
      throw CLIFailure(
        exitCode: .refused,
        message: "The pairing code is wrong, expired or already used. Start a new pairing in "
          + "Dblore (Settings > MCP).")
    default: throw Self.anotherProgram(port)
    }
  }

  /// Checks that Dblore holding `credentials`' proof key answers on `port`. Sends no token.
  func hello(_ credentials: CLICredentials, port: Int) async throws {
    guard let key = Self.data(base64URL: credentials.proofKey), key.count == 32,
      let boundPort = UInt16(exactly: port)
    else { throw Self.unreadableCredentials }
    let nonce = Data(randomBytes(32))
    let body = try JSONEncoder().encode(["id": credentials.id, "nonce": Self.base64URL(nonce)])
    let response = try await postBeforeToken(port: port, path: "/cli/hello", body: body)
    switch response.status {
    case 200:
      guard let answer = try? JSONDecoder().decode([String: String].self, from: response.body),
        let proof = answer["proof"].flatMap(Self.data(base64URL:)),
        Self.isValidHello(proof: proof, key: key, nonce: nonce, port: boundPort)
      else { throw Self.anotherProgram(port) }
    case 401: throw Self.notPaired(port)
    default: throw Self.anotherProgram(port)
    }
  }

  /// Runs tool `name` after the hello check; the tool's text, or a `CLIFailure`.
  func callTool(
    _ name: String, arguments: [String: CLIArgument], credentials: CLICredentials, port: Int
  ) async throws -> String {
    try await hello(credentials, port: port)
    let body = try JSONEncoder().encode(
      ToolCall(params: ToolCall.Params(name: name, arguments: arguments)))
    var headers = headers()
    headers["Authorization"] = "Bearer \(credentials.token)"
    headers["Accept"] = "application/json, text/event-stream"
    let response: CLIHTTPResponse
    do {
      response = try await transport.post(
        port: port, path: "/mcp", headers: headers, body: body, timeout: Self.toolTimeout)
    } catch let error as CLITransportError {
      // The token went out: say nothing about who got it
      switch error {
      case .unreachable:
        throw CLIFailure(
          exitCode: .unavailable,
          message: "Dblore stopped answering on port \(port) before the command finished.")
      case .timedOut:
        throw CLIFailure(
          exitCode: .queryFailed, message: "Dblore did not answer on port \(port) in time.")
      case .failed:
        throw CLIFailure(
          exitCode: .queryFailed,
          message: "The request to Dblore on port \(port) failed before an answer came back.")
      }
    }
    switch response.status {
    case 200: break
    case 401: throw Self.notPaired(port)
    case 503:
      throw CLIFailure(
        exitCode: .unavailable, message: "Dblore's MCP server is busy. Try again in a moment.")
    case 504:
      throw CLIFailure(exitCode: .queryFailed, message: "The request timed out in Dblore.")
    default:
      throw CLIFailure(
        exitCode: .queryFailed, message: "Dblore answered HTTP \(response.status).")
    }
    let (text, isError) = try Self.toolText(from: response.body)
    guard isError else { return text }
    throw Self.failure(forToolError: text)
  }

  /// A pair or hello POST; no token is sent, so an answer that is not HTTP is another program.
  private func postBeforeToken(
    port: Int, path: String, body: Data
  ) async throws
    -> CLIHTTPResponse
  {
    do {
      return try await transport.post(
        port: port, path: path, headers: headers(), body: body, timeout: Self.shortTimeout)
    } catch let error as CLITransportError {
      switch error {
      case .unreachable: throw CLIFailure(exitCode: .unavailable, message: Self.notRunning)
      case .timedOut:
        throw CLIFailure(
          exitCode: .unavailable, message: "Dblore did not answer on port \(port) in time.")
      case .failed: throw Self.anotherProgram(port)
      }
    }
  }

  private func headers() -> [String: String] {
    ["Content-Type": "application/json", "Accept": "application/json", "User-Agent": userAgent]
  }

  // MARK: - Wire format

  /// Decodes a /cli/pair answer; refused when it names another port than `dialedPort` or
  /// is not a whole pairing.
  static func decodePairResponse(_ body: Data, dialedPort: Int) throws -> CLICredentials {
    guard let credentials = try? JSONDecoder().decode(CLICredentials.self, from: body),
      !credentials.token.isEmpty, !credentials.id.isEmpty,
      data(base64URL: credentials.proofKey)?.count == 32
    else { throw anotherProgram(dialedPort) }
    guard credentials.port == dialedPort else {
      throw CLIFailure(
        exitCode: .refused,
        message: "The answer on port \(dialedPort) names port \(credentials.port), so the "
          + "pairing was not saved. Pair again with the command Settings > MCP shows.")
    }
    return credentials
  }

  /// "dblore-cli-hello-v1" || nonce || port (big-endian UInt16)
  static func helloMessage(nonce: Data, port: UInt16) -> Data {
    var message = Data(helloLabel.utf8)
    message.append(nonce)
    message.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)])
    return message
  }

  /// Whether `proof` is the HMAC-SHA256 of the hello message for `nonce` and the dialed `port`,
  /// compared in constant time
  static func isValidHello(proof: Data, key: Data, nonce: Data, port: UInt16) -> Bool {
    HMAC<SHA256>.isValidAuthenticationCode(
      proof, authenticating: helloMessage(nonce: nonce, port: port), using: SymmetricKey(data: key))
  }

  /// The text and isError of a tools/call answer; a JSON-RPC error is a query failure.
  static func toolText(from body: Data) throws -> (text: String, isError: Bool) {
    guard let response = try? JSONDecoder().decode(RPCResponse.self, from: body) else {
      throw unreadableAnswer
    }
    if let error = response.error {
      throw CLIFailure(exitCode: .queryFailed, message: error.message)
    }
    guard let result = response.result else { throw unreadableAnswer }
    let text = result.content.compactMap(\.text).joined(separator: "\n")
    return (text, result.isError ?? false)
  }

  /// A tool's isError text: a refusal (exit 3), the MCP server stopping (exit 2), else a
  /// query error (exit 4).
  static func failure(forToolError text: String) -> CLIFailure {
    if text == stoppedText { return CLIFailure(exitCode: .unavailable, message: text) }
    return CLIFailure(exitCode: isRefusal(text) ? .refused : .queryFailed, message: text)
  }

  static func isRefusal(_ text: String) -> Bool {
    refusalTexts.contains(text) || text.hasSuffix(nothingSent)
      || text.hasPrefix("Missing or invalid argument: ")
  }

  /// The app's text when its MCP server stopped during the call
  static let stoppedText = "The MCP server is stopped."
  /// The end of every refusal of a statement Dblore did not send
  static let nothingSent = "Nothing was sent to the database."
  /// The app's refusal texts that do not end with `nothingSent` (`HeadlessAccessRule.Refusal`,
  /// `MCPToolError`, `MCPConnectionError`)
  static let refusalTexts: Set<String> = [
    "No connection with that name or id is available. In Dblore, check that it is allowed in "
      + "Settings and not locked; the command line also skips connections whose AI access is "
      + "Never.",
    "The connection name is ambiguous; use the id.",
    "No connection with this id is available to MCP. Call list_connections for the ids.",
    "Allow AI access to this connection in Dblore first.",
    "The SQL is empty.",
    "run_query takes exactly one SQL statement.",
    "This connection is not saved in Dblore.",
    "MCP does not support DuckDB connections.",
    "The connection's client certificate is not saved in the Keychain. Connect once in Dblore "
      + "with Remember on.",
    "The connection's SSH password or key is not saved in the Keychain. Connect once in Dblore "
      + "with Remember on.",
    "The SSH server's host key is not trusted yet. Connect once in Dblore and trust it.",
    "This connection uses a password command; open it in Dblore instead.",
    "MCP connections are read-only: only queries are sent.",
    "MCP connections do not use server-side cursors.",
  ]

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// The bytes of unpadded base64url text, nil when it is not one
  static func data(base64URL text: String) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
  }

  /// Bytes from the system CSPRNG (SecRandomCopyBytes)
  static func secureRandomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return bytes
  }

  static func anotherProgram(_ port: Int) -> CLIFailure {
    CLIFailure(
      exitCode: .refused,
      message: "Another program is answering on port \(port), not Dblore. The token was not "
        + "sent to it. Check the port in Dblore (Settings > MCP).")
  }

  static func notPaired(_ port: Int) -> CLIFailure {
    CLIFailure(
      exitCode: .refused,
      message: "Dblore on port \(port) does not know this command-line tool (its pairing was "
        + "revoked, or it was paired with another Dblore). Pair again: run the command "
        + "Settings > MCP shows.")
  }

  static let unreadableCredentials = CLIFailure(
    exitCode: .refused,
    message: "The saved pairing cannot be read. Pair again: run the command Settings > MCP shows.")

  static let unreadableAnswer = CLIFailure(
    exitCode: .queryFailed, message: "Dblore's answer could not be read.")

  private struct ToolCall: Encodable {
    struct Params: Encodable {
      let name: String
      let arguments: [String: CLIArgument]
    }

    let jsonrpc = "2.0"
    let id = 1
    let method = "tools/call"
    let params: Params
  }

  private struct RPCResponse: Decodable {
    struct Result: Decodable {
      struct Content: Decodable {
        let text: String?
      }

      let content: [Content]
      let isError: Bool?
    }

    struct RPCError: Decodable {
      let message: String
    }

    let result: Result?
    let error: RPCError?
  }
}

/// `CLITransport` over URLSession: an ephemeral session with no proxy, cookies, cache or
/// redirects, to http://127.0.0.1:<port> only.
nonisolated struct CLIURLSessionTransport: CLITransport {
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.waitsForConnectivity = false
    session = URLSession(
      configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }

  func post(
    port: Int, path: String, headers: [String: String], body: Data, timeout: TimeInterval
  ) async throws -> CLIHTTPResponse {
    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
      throw CLIFailure(exitCode: .usage, message: "Port \(port) is not valid.")
    }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = body
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw CLITransportError.failed }
      return CLIHTTPResponse(status: http.statusCode, body: data)
    } catch let error as URLError {
      switch error.code {
      case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
        throw CLITransportError.unreachable
      case .timedOut: throw CLITransportError.timedOut
      default: throw CLITransportError.failed
      }
    } catch let error as CLITransportError {
      throw error
    } catch {
      throw CLITransportError.failed
    }
  }
}

/// Every redirect is refused: the answer that asked for it is returned as is.
nonisolated private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
