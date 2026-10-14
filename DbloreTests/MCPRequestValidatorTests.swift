// MCPRequestValidatorTests.swift
// The request-head checks of the MCP HTTP listener: Host, Origin, path, method, bearer token,
// Content-Type and Content-Length, in that order, before any body is read.

import Foundation
import NIOHTTP1
import Testing

@testable import Dblore

@Suite("MCP request validator")
struct MCPRequestValidatorTests {
  private let port = 41730
  private let token = "s3cret-token"
  private var validator: MCPRequestValidator {
    MCPRequestValidator(port: port, token: token, bodyLimit: 1_048_576)
  }

  private var goodHeaders: [(String, String)] {
    [
      ("Host", "127.0.0.1:\(port)"),
      ("Authorization", "Bearer \(token)"),
      ("Content-Type", "application/json"),
      ("Content-Length", "2"),
    ]
  }

  private func validate(
    method: HTTPMethod = .POST, uri: String = "/mcp", headers: [(String, String)]? = nil,
    replacing overrides: [(String, String?)] = []
  ) -> MCPRequestValidator.Outcome {
    var fields = headers ?? goodHeaders
    for (name, value) in overrides {
      fields.removeAll { $0.0.lowercased() == name.lowercased() }
      if let value { fields.append((name, value)) }
    }
    let head = HTTPRequestHead(
      version: .http1_1, method: method, uri: uri, headers: HTTPHeaders(fields))
    return validator.validate(head)
  }

  private func status(_ outcome: MCPRequestValidator.Outcome) -> Int? {
    if case .reject(let response) = outcome { return response.status }
    return nil
  }

  @Test("A well-formed POST /mcp proceeds; the query string is ignored")
  func proceeds() {
    #expect(validate() == .proceed)
    #expect(validate(uri: "/mcp?x=1") == .proceed)
    #expect(validate(replacing: [("Host", "localhost:\(port)")]) == .proceed)
    #expect(validate(replacing: [("Host", "LocalHost:\(port)")]) == .proceed)
  }

  @Test(
    "Host must be 127.0.0.1:<port> or localhost:<port>",
    arguments: [
      ("127.0.0.1:1234", 403), ("localhost:1234", 403), ("evil.com", 403),
      ("evil.com:41730", 403), ("127.0.0.1", 403), ("[::1]:41730", 403),
    ])
  func hostRefused(host: String, expected: Int) {
    #expect(status(validate(replacing: [("Host", host)])) == expected)
  }

  @Test("A missing or repeated Host is 400")
  func hostMissing() {
    #expect(status(validate(replacing: [("Host", nil)])) == 400)
    #expect(
      status(validate(headers: goodHeaders + [("Host", "127.0.0.1:\(port)")])) == 400)
  }

  @Test("A present Origin must be a local http origin on the same port")
  func origin() {
    #expect(validate(replacing: [("Origin", "http://localhost:\(port)")]) == .proceed)
    #expect(validate(replacing: [("Origin", "http://127.0.0.1:\(port)")]) == .proceed)
    for bad in [
      "http://evil.com", "null", "https://localhost:\(port)", "http://localhost:1234",
      "http://localhost", "http://[::1]:\(port)", "",
    ] {
      #expect(status(validate(replacing: [("Origin", bad)])) == 403, "\(bad)")
    }
  }

  @Test("Unknown paths are 404", arguments: ["/", "/mcp/", "/MCP", "/mcpx", "/other"])
  func unknownPath(uri: String) {
    #expect(status(validate(uri: uri)) == 404)
  }

  @Test("GET and other methods are 405 with Allow: POST")
  func methodNotAllowed() throws {
    for method in [HTTPMethod.GET, .DELETE, .PUT, .OPTIONS] {
      guard case .reject(let response) = validate(method: method) else {
        Issue.record("\(method) proceeded")
        continue
      }
      #expect(response.status == 405)
      #expect(response.headers["Allow"] == "POST")
    }
  }

  @Test("A missing or wrong bearer token is 401 with WWW-Authenticate: Bearer")
  func unauthorized() {
    for value: String? in [
      nil, "Bearer wrong", "Bearer \(token)x", "Bearer", "Bearer ", "Basic \(token)", token,
    ] {
      guard case .reject(let response) = validate(replacing: [("Authorization", value)]) else {
        Issue.record("\(value ?? "nil") proceeded")
        continue
      }
      #expect(response.status == 401)
      #expect(response.headers["WWW-Authenticate"] == "Bearer")
    }
    #expect(validate(replacing: [("Authorization", "bearer \(token)")]) == .proceed)
  }

  @Test("An empty configured token refuses everything")
  func emptyToken() {
    let empty = MCPRequestValidator(port: port, token: "", bodyLimit: 1_048_576)
    let head = HTTPRequestHead(
      version: .http1_1, method: .POST, uri: "/mcp",
      headers: HTTPHeaders([
        ("Host", "127.0.0.1:\(port)"), ("Authorization", "Bearer "),
        ("Content-Type", "application/json"),
      ]))
    #expect(status(empty.validate(head)) == 401)
  }

  @Test("Token comparison is exact for equal, same-length and different-length tokens")
  func constantTimeEquality() {
    #expect(MCPRequestValidator.constantTimeEquals("abc", "abc"))
    #expect(!MCPRequestValidator.constantTimeEquals("abc", "abd"))
    #expect(!MCPRequestValidator.constantTimeEquals("abc", "abcd"))
    #expect(!MCPRequestValidator.constantTimeEquals("", "a"))
  }

  @Test("POST needs Content-Type application/json, else 415")
  func contentType() {
    #expect(
      validate(replacing: [("Content-Type", "application/json; charset=utf-8")]) == .proceed)
    #expect(validate(replacing: [("Content-Type", "Application/JSON")]) == .proceed)
    for bad: String? in [
      nil, "text/plain", "application/x-www-form-urlencoded", "multipart/form-data",
      "application/jsonx", "",
    ] {
      #expect(status(validate(replacing: [("Content-Type", bad)])) == 415, "\(bad ?? "nil")")
    }
  }

  @Test("Content-Length over the limit is 413; an invalid one is 400")
  func contentLength() {
    #expect(validate(replacing: [("Content-Length", "1048576")]) == .proceed)
    #expect(validate(replacing: [("Content-Length", String?.none)]) == .proceed)
    #expect(status(validate(replacing: [("Content-Length", "1048577")])) == 413)
    #expect(status(validate(replacing: [("Content-Length", "-1")])) == 400)
    #expect(status(validate(replacing: [("Content-Length", "abc")])) == 400)
  }

  @Test("Order: Host, Origin, path, method, token, Content-Type, Content-Length")
  func order() {
    let noAuth: [(String, String?)] = [("Authorization", nil)]
    #expect(status(validate(uri: "/x", replacing: noAuth + [("Host", "evil.com")])) == 403)
    #expect(
      status(validate(uri: "/x", replacing: noAuth + [("Origin", "http://evil.com")])) == 403)
    #expect(status(validate(method: .GET, uri: "/x", replacing: noAuth)) == 404)
    #expect(status(validate(method: .GET, replacing: noAuth)) == 405)
    #expect(status(validate(replacing: noAuth + [("Content-Type", "text/plain")])) == 401)
    #expect(
      status(
        validate(replacing: [("Content-Type", "text/plain"), ("Content-Length", "9999999")]))
        == 415)
  }
}
