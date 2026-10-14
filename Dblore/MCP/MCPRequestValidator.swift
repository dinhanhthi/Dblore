// MCPRequestValidator.swift
// Checks an MCP HTTP request head before any body is read. The only endpoint is `POST /mcp`
// (the query string is ignored). Checks run in this order, and the first failure answers:
//   1. Host: exactly one, `127.0.0.1:<port>` or `localhost:<port>` (case-insensitive); missing or
//      repeated -> 400, anything else -> 403 (DNS rebinding).
//   2. Origin: when present, `http://127.0.0.1:<port>` or `http://localhost:<port>`; anything
//      else (`null`, https, another host or port) -> 403. Non-browser clients send none.
//   3. Path: not `/mcp` -> 404.
//   4. Method: not POST -> 405 with `Allow: POST` (no GET stream, no DELETE session).
//   5. `Authorization: Bearer <token>`, compared in constant time -> 401 with
//      `WWW-Authenticate: Bearer`.
//   6. `Content-Type: application/json` (parameters allowed) -> 415, which refuses CORS simple
//      requests.
//   7. Content-Length over `bodyLimit` -> 413, invalid -> 400. Chunked bodies are capped by the
//      listener while they stream.
// The IPv6 loopback is not allowed: the listener binds 127.0.0.1 only.

import CryptoKit
import Foundation
import NIOHTTP1

nonisolated struct MCPRequestValidator: Sendable {
  static let path = "/mcp"
  static let defaultBodyLimit = 1_048_576

  enum Outcome: Equatable, Sendable {
    case proceed
    case reject(MCPHTTPResponse)
  }

  let port: Int
  let token: String
  let bodyLimit: Int

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
    let path = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
    guard path == Self.path else { return .reject(.text(404, "Not Found")) }
    guard head.method == .POST else {
      return .reject(.text(405, "Method Not Allowed", headers: ["Allow": "POST"]))
    }
    guard authorized(headers["Authorization"]) else {
      return .reject(.text(401, "Unauthorized", headers: ["WWW-Authenticate": "Bearer"]))
    }
    guard isJSON(headers["Content-Type"]) else {
      return .reject(.text(415, "Unsupported Media Type: use application/json"))
    }
    let lengths = headers["Content-Length"]
    if !lengths.isEmpty {
      guard lengths.count == 1, let length = Int(lengths[0]), length >= 0 else {
        return .reject(.text(400, "Bad Request: invalid Content-Length"))
      }
      guard length <= bodyLimit else { return .reject(.text(413, "Payload Too Large")) }
    }
    return .proceed
  }

  private func authorized(_ values: [String]) -> Bool {
    guard !token.isEmpty, values.count == 1 else { return false }
    let parts = values[0].split(separator: " ", maxSplits: 1)
    guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
    return Self.constantTimeEquals(parts[1].trimmingCharacters(in: .whitespaces), token)
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
