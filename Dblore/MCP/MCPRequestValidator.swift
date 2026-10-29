// MCPRequestValidator.swift
// Checks an MCP HTTP request head before any body is read. Three routes, all POST (the query
// string is ignored): `/mcp` for JSON-RPC, and `/cli/pair` and `/cli/hello` for the command-line
// tool (`MCPCLIPairingService`), which carry no bearer, take a body of at most 4 KB and are
// answered with `Connection: close`. Checks run in this order, and the first failure answers:
//   1. Host: exactly one, `127.0.0.1:<port>` or `localhost:<port>` (case-insensitive); missing or
//      repeated -> 400, anything else -> 403 (DNS rebinding).
//   2. Origin: when present, `http://127.0.0.1:<port>` or `http://localhost:<port>`; anything
//      else (`null`, https, another host or port) -> 403. Non-browser clients send none.
//   3. Path: none of the three -> 404.
//   4. Method: not POST -> 405 with `Allow: POST` (no GET stream, no DELETE session).
//   5. `/mcp` only: `Authorization: Bearer <token>`, the MCP token (caller mcp) or a paired
//      command-line tool's token (caller cli, `MCPCLITokenRegistry`, read without the Keychain),
//      each compared in constant time -> 401 with `WWW-Authenticate: Bearer`.
//   6. `Content-Type: application/json` (parameters allowed) -> 415, which refuses CORS simple
//      requests.
//   7. Content-Length over the route's limit -> 413, invalid -> 400. Chunked bodies are capped
//      by the listener while they stream.
// The IPv6 loopback is not allowed: the listener binds 127.0.0.1 only.

import CryptoKit
import Foundation
import NIOHTTP1

/// Who sent an authorized `/mcp` request
nonisolated enum MCPCallerKind: Sendable, Equatable {
  /// An MCP client with the MCP token
  case mcp
  /// A paired command-line tool with its own token
  case cli
}

/// What a request head that passed validation asks for
nonisolated enum MCPRoute: Sendable, Equatable {
  case mcp(caller: MCPCallerKind)
  case cliPair
  case cliHello

  /// The route's path, without a query string
  var path: String {
    switch self {
    case .mcp: MCPRequestValidator.path
    case .cliPair: MCPRequestValidator.pairPath
    case .cliHello: MCPRequestValidator.helloPath
    }
  }

  /// The command-line tool's routes carry no bearer and close their connection.
  var isCLI: Bool {
    if case .mcp = self { return false }
    return true
  }
}

nonisolated struct MCPRequestValidator: Sendable {
  static let path = "/mcp"
  static let pairPath = "/cli/pair"
  static let helloPath = "/cli/hello"
  static let defaultBodyLimit = 1_048_576
  /// Body cap of `/cli/pair` and `/cli/hello`
  static let cliBodyLimit = 4_096

  enum Outcome: Equatable, Sendable {
    case proceed(MCPRoute)
    case reject(MCPHTTPResponse)
  }

  let port: Int
  let token: String
  /// Body cap of `/mcp`
  let bodyLimit: Int
  /// The paired command-line tools' tokens, updated in place by pair and revoke
  var cliTokens = MCPCLITokenRegistry()

  func validate(_ head: HTTPRequestHead) -> Outcome {
    let headers = head.headers
    let hosts = headers["Host"]
    guard hosts.count == 1 else { return .reject(.text(400, "Bad Request: Host required")) }
    let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
    guard allowedHosts.contains(hosts[0].lowercased()) else {
      return .reject(.text(403, "Forbidden: Host not allowed"))
    }
    let origins = headers["Origin"]
    if !origins.isEmpty {
      let allowedOrigins = ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]
      guard origins.count == 1, allowedOrigins.contains(origins[0].lowercased()) else {
        return .reject(.text(403, "Forbidden: Origin not allowed"))
      }
    }
    var route: MCPRoute
    switch Self.path(of: head.uri) {
    case Self.path: route = .mcp(caller: .mcp)
    case Self.pairPath: route = .cliPair
    case Self.helloPath: route = .cliHello
    default: return .reject(.text(404, "Not Found"))
    }
    guard head.method == .POST else {
      return .reject(.text(405, "Method Not Allowed", headers: ["Allow": "POST"]))
    }
    if !route.isCLI {
      guard let caller = caller(headers["Authorization"]) else {
        return .reject(.text(401, "Unauthorized", headers: ["WWW-Authenticate": "Bearer"]))
      }
      route = .mcp(caller: caller)
    }
    guard isJSON(headers["Content-Type"]) else {
      return .reject(.text(415, "Unsupported Media Type: use application/json"))
    }
    let lengths = headers["Content-Length"]
    if !lengths.isEmpty {
      guard lengths.count == 1, let length = Int(lengths[0]), length >= 0 else {
        return .reject(.text(400, "Bad Request: invalid Content-Length"))
      }
      guard length <= bodyLimit(of: route) else {
        return .reject(.text(413, "Payload Too Large"))
      }
    }
    return .proceed(route)
  }

  /// The most body bytes `route` takes
  func bodyLimit(of route: MCPRoute) -> Int {
    route.isCLI ? Self.cliBodyLimit : bodyLimit
  }

  /// `uri` without its query string
  static func path(of uri: String) -> String {
    String(uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
  }

  /// The bearer is compared with the MCP token and with every paired token, whichever matches,
  /// so the time does not tell which kind it is.
  private func caller(_ values: [String]) -> MCPCallerKind? {
    guard values.count == 1 else { return nil }
    let parts = values[0].split(separator: " ", maxSplits: 1)
    guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
    let bearer = parts[1].trimmingCharacters(in: .whitespaces)
    let isMCP = Self.constantTimeEquals(bearer, token) && !token.isEmpty
    let pairedID = cliTokens.pairedID(for: bearer)
    if isMCP { return .mcp }
    return pairedID == nil ? nil : .cli
  }

  private func isJSON(_ values: [String]) -> Bool {
    guard values.count == 1 else { return false }
    let mediaType = values[0].split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[
      0]
    return mediaType.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
  }

  /// Compares SHA-256 digests with a fixed-length XOR fold, so the time depends on neither the
  /// first differing byte nor the length of the expected token.
  static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(SHA256.hash(data: Data(lhs.utf8)))
    let right = Array(SHA256.hash(data: Data(rhs.utf8)))
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
  }
}
