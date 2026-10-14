// MCPHTTPListenerTests.swift
// The MCP HTTP listener over a real loopback socket on an ephemeral port: request-head refusals,
// the streamed body limit, the handler hand-off, keep-alive, and start/stop lifecycle. Requests
// are written raw so the Host header is exactly what the test sends.

import Darwin
import Foundation
import Testing
import os

@testable import Dblore

@Suite("MCP HTTP listener", .serialized)
struct MCPHTTPListenerTests {
  private let token = "listener-token"

  /// Echoes the body with 200, or answers 202 to `{}` (a notification-shaped message).
  private func makeServer() -> MCPHTTPServer {
    MCPHTTPServer { request in
      guard request.body != Data("{}".utf8) else {
        return MCPHTTPResponse(status: 202, headers: [:], body: Data())
      }
      return MCPHTTPResponse(
        status: 200, headers: ["Content-Type": "application/json"], body: request.body)
    }
  }

  private func configuration(port: Int = 0, bodyLimit: Int = 64) -> MCPHTTPServer.Configuration {
    MCPHTTPServer.Configuration(port: port, token: token, bodyLimit: bodyLimit)
  }

  private func request(
    _ port: Int, method: String = "POST", path: String = "/mcp", host: String? = nil,
    headers: [String] = [], body: String = "{\"id\":1}", auth: Bool = true,
    contentType: String = "application/json"
  ) -> String {
    var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port)")"]
    if auth { lines.append("Authorization: Bearer \(token)") }
    if !contentType.isEmpty { lines.append("Content-Type: \(contentType)") }
    lines += headers
    lines += ["Content-Length: \(body.utf8.count)", "Connection: close", "", body]
    return lines.joined(separator: "\r\n")
  }

  @Test("Refuses bad requests with the right status before the handler runs")
  func refusals() async throws {
    let server = makeServer()
    let port = try await server.start(configuration())
    let cases: [(String, Int)] = [
      (request(port, path: "/other"), 404),
      (request(port, method: "GET", body: ""), 405),
      (request(port, contentType: "text/plain"), 415),
      (request(port, auth: false), 401),
      (request(port, host: "evil.com:\(port)"), 403),
      (request(port, headers: ["Origin: http://evil.com"]), 403),
      (request(port, body: String(repeating: "x", count: 65)), 413),
    ]
    for (raw, expected) in cases {
      let response = try await exchange(port, raw)
      #expect(response.status == expected, "\(raw.prefix(40))")
    }
    await server.stop()
  }

  @Test("A chunked body over the limit is 413 while it streams")
  func chunkedLimit() async throws {
    let server = makeServer()
    let port = try await server.start(configuration())
    let chunk = String(repeating: "x", count: 100)
    let raw = [
      "POST /mcp HTTP/1.1", "Host: localhost:\(port)", "Authorization: Bearer \(token)",
      "Content-Type: application/json", "Transfer-Encoding: chunked", "",
      String(chunk.utf8.count, radix: 16), chunk, "",
    ].joined(separator: "\r\n")
    #expect(try await exchange(port, raw).status == 413)
    await server.stop()
  }

  @Test("Valid requests reach the handler: 200 with its body, 202 for notifications")
  func handler() async throws {
    let server = makeServer()
    let port = try await server.start(configuration())
    let echoed = try await exchange(port, request(port, body: "{\"id\":7}"))
    #expect(echoed.status == 200)
    #expect(echoed.body == "{\"id\":7}")
    #expect(try await exchange(port, request(port, body: "{}")).status == 202)
    await server.stop()
  }

  @Test("Keep-alive: two pipelined requests on one connection both get answers")
  func keepAlive() async throws {
    let server = makeServer()
    let port = try await server.start(configuration())
    let first = request(port, body: "{\"id\":1}")
      .replacingOccurrences(of: "Connection: close\r\n", with: "")
    let response = try await exchange(port, first + request(port, body: "{\"id\":2}"))
    #expect(response.raw.components(separatedBy: "HTTP/1.1 200").count == 3)
    await server.stop()
  }

  @Test("Lifecycle: loopback IPv4 only, port in use throws, stop closes, restart works")
  func lifecycle() async throws {
    let server = makeServer()
    let port = try await server.start(configuration())
    #expect(port > 0)
    #expect(await server.port == port)
    #expect(try await server.start(configuration()) == port)

    let other = makeServer()
    await #expect(throws: (any Error).self) {
      try await other.start(configuration(port: port))
    }
    #expect(await other.port == nil)

    #expect(throws: (any Error).self) { try rawExchange(port, "", address: "::1") }

    await server.stop()
    await server.stop()
    #expect(await server.port == nil)
    #expect(throws: (any Error).self) { try rawExchange(port, request(port)) }

    let restarted = try await server.start(configuration())
    #expect(try await exchange(restarted, request(restarted)).status == 200)
    await server.stop()
  }

  @Test("Stop racing start never leaves a listener behind")
  func stopDuringStart() async throws {
    let server = makeServer()
    for _ in 0..<20 {
      async let started = try? server.start(configuration())
      await server.stop()
      _ = await started
      await server.stop()
      #expect(await server.port == nil)
    }
    let port = try await server.start(configuration())
    #expect(try await exchange(port, request(port)).status == 200)
    await server.stop()
  }

  @Test("stop() while a slow handler runs returns promptly")
  func stopDuringSlowHandler() async throws {
    let started = OSAllocatedUnfairLock(initialState: false)
    let server = MCPHTTPServer { _ in
      started.withLock { $0 = true }
      try? await Task.sleep(for: .seconds(30))
      return .text(200, "")
    }
    let port = try await server.start(configuration())
    async let reply = try? exchange(port, request(port))
    let deadline = ContinuousClock.now + .seconds(5)
    while !started.withLock({ $0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(started.withLock { $0 })
    let stopping = ContinuousClock.now
    await server.stop()
    #expect(ContinuousClock.now - stopping < .seconds(2))
    _ = await reply
    #expect(await server.port == nil)
  }

  // MARK: - Raw socket client

  /// Runs the blocking socket exchange off the cooperative pool, where the handler task runs.
  private func exchange(_ port: Int, _ raw: String) async throws -> RawResponse {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(with: Result { try rawExchange(port, raw) })
      }
    }
  }
}

private struct RawResponse {
  let raw: String
  var status: Int { Int(raw.split(separator: " ").dropFirst().first ?? "") ?? -1 }
  var body: String { raw.components(separatedBy: "\r\n\r\n").dropFirst().joined() }
}

/// Writes `raw` to `address:port`, then reads until the server closes or 5 s pass.
private func rawExchange(
  _ port: Int, _ raw: String, address: String = "127.0.0.1"
) throws
  -> RawResponse
{
  let isIPv6 = address.contains(":")
  let fd = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { throw POSIXError(.EBADF) }
  defer { close(fd) }
  var timeout = timeval(tv_sec: 5, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  var noSigPipe: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

  let connected: Int32
  if isIPv6 {
    var addr = sockaddr_in6()
    addr.sin6_family = sa_family_t(AF_INET6)
    addr.sin6_port = in_port_t(UInt16(port).bigEndian)
    inet_pton(AF_INET6, address, &addr.sin6_addr)
    connected = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
  } else {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr(address)
    connected = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  }
  guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }

  let bytes = Array(raw.utf8)
  var sent = 0
  while sent < bytes.count {
    let count = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    guard count > 0 else { break }
    sent += count
  }
  var received = [UInt8]()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let count = recv(fd, &buffer, buffer.count, 0)
    guard count > 0 else { break }
    received += buffer[0..<count]
  }
  guard !received.isEmpty else { throw POSIXError(.ECONNRESET) }
  return RawResponse(raw: String(decoding: received, as: UTF8.self))
}
