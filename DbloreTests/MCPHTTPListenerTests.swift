// MCPHTTPListenerTests.swift
// The MCP HTTP listener over a real loopback socket on an ephemeral port: request-head refusals,
// the streamed body limit, the handler hand-off, keep-alive, a client disconnect cancelling its
// handler, the connection and in-flight caps (503), and start/stop lifecycle. Requests are
// written raw so the Host header is exactly what the test sends.

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

  @Test("A client that disconnects while its handler runs cancels the handler")
  func disconnectCancelsHandler() async throws {
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    let started = OSAllocatedUnfairLock(initialState: false)
    let server = MCPHTTPServer { _ in
      started.withLock { $0 = true }
      try? await Task.sleep(for: .seconds(30))
      cancelled.withLock { $0 = Task.isCancelled }
      return .text(200, "")
    }
    let port = try await server.start(configuration())
    let raw = request(port)
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      DispatchQueue.global().async {
        continuation.resume(with: Result { _ = try rawExchange(port, raw, read: false) })
      }
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while !cancelled.withLock({ $0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(started.withLock { $0 })
    #expect(cancelled.withLock { $0 })
    await server.stop()
  }

  @Test("Idle or unauthenticated connections hold no slot, so an agent still gets 200")
  func idleConnectionsHoldNoSlot() async throws {
    let server = makeServer()
    let port = try await server.start(configuration())
    let cap = MCPHTTPServer.maxConnections
    let unauthenticated = request(port, auth: false)
    let held = try await offPool {
      let idle = try holdConnections(port, count: cap)
      let refused = try holdConnections(port, count: cap, sending: unauthenticated)
      return (fds: idle.fds + refused.fds, statuses: refused.statuses)
    }
    defer { for fd in held.fds { close(fd) } }
    #expect(held.statuses == Array(repeating: 401, count: cap))
    #expect(try await exchange(port, request(port)).status == 200)
    await server.stop()
  }

  @Test("Over the connection cap a request gets 503 with Retry-After; a closed slot frees")
  func connectionCap() async throws {
    let server = makeServer()
    let port = try await server.start(configuration())
    let cap = MCPHTTPServer.maxConnections
    let keepAlive = request(port).replacingOccurrences(of: "Connection: close\r\n", with: "")
    let opened = try await offPool { try holdConnections(port, count: cap, sending: keepAlive) }
    var held = opened.fds
    defer { for fd in held { close(fd) } }
    #expect(opened.statuses == Array(repeating: 200, count: cap))
    let refused = try await exchange(port, request(port))
    #expect(refused.status == 503)
    #expect(refused.raw.contains("Retry-After: 2"))
    #expect(refused.raw.contains("Connection: close"))
    #expect(refused.body.contains("\"jsonrpc\":\"2.0\""))
    close(held.removeLast())
    var status = -1
    let deadline = ContinuousClock.now + .seconds(5)
    while status != 200, ContinuousClock.now < deadline, !Task.isCancelled {
      status = try await exchange(port, request(port)).status
      if status != 200 { try await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(status == 200)
    await server.stop()
  }

  @Test("Over the in-flight cap a request gets 503 without running; a finished slot frees")
  func inFlightCap() async throws {
    let started = OSAllocatedUnfairLock(initialState: 0)
    let open = OSAllocatedUnfairLock(initialState: false)
    let server = MCPHTTPServer { _ in
      started.withLock { $0 += 1 }
      while !open.withLock({ $0 }), !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
      }
      return .text(200, "")
    }
    let port = try await server.start(configuration())
    let cap = MCPHTTPServer.maxInFlight
    let raw = request(port)
    async let replies = withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<cap { group.addTask { try await exchange(port, raw).status } }
      return try await group.reduce(into: [Int]()) { $0.append($1) }
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while started.withLock({ $0 }) < cap, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(started.withLock { $0 } == cap)
    let refused = try await exchange(port, raw)
    #expect(refused.status == 503)
    #expect(refused.raw.contains("Retry-After: 2"))
    #expect(refused.raw.contains("Connection: close"))
    #expect(started.withLock { $0 } == cap)
    open.withLock { $0 = true }
    #expect(try await replies == Array(repeating: 200, count: cap))
    #expect(try await exchange(port, raw).status == 200)
    await server.stop()
  }

  // MARK: - Raw socket client

  private func exchange(_ port: Int, _ raw: String) async throws -> RawResponse {
    try await offPool { try rawExchange(port, raw) }
  }

  /// Runs blocking socket work off the cooperative pool, where the handler task runs.
  private func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(with: Result { try body() }) }
    }
  }
}

private struct RawResponse {
  let raw: String
  var status: Int { Int(raw.split(separator: " ").dropFirst().first ?? "") ?? -1 }
  var body: String { raw.components(separatedBy: "\r\n\r\n").dropFirst().joined() }
}

/// Writes `raw` to `address:port`, then reads until the server closes or 5 s pass (without
/// `read`, closes once written).
private func rawExchange(
  _ port: Int, _ raw: String, address: String = "127.0.0.1", read: Bool = true
) throws
  -> RawResponse
{
  let fd = try openConnection(port, address: address)
  defer { close(fd) }
  sendAll(fd, raw)
  guard read else { return RawResponse(raw: "") }
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

/// Opens `count` connections one after another; with `raw`, each sends it and reads its one
/// response before the next opens. The connections stay open; the caller closes them.
private func holdConnections(
  _ port: Int, count: Int, sending raw: String? = nil
) throws
  -> (fds: [Int32], statuses: [Int])
{
  var fds: [Int32] = []
  var statuses: [Int] = []
  do {
    for _ in 0..<count {
      let fd = try openConnection(port)
      fds.append(fd)
      guard let raw else { continue }
      sendAll(fd, raw)
      statuses.append(try readResponse(fd).status)
    }
  } catch {
    for fd in fds { close(fd) }
    throw error
  }
  return (fds, statuses)
}

private func sendAll(_ fd: Int32, _ raw: String) {
  let bytes = Array(raw.utf8)
  var sent = 0
  while sent < bytes.count {
    let count = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    guard count > 0 else { break }
    sent += count
  }
}

/// Reads one response (head plus `Content-Length` body bytes) without waiting for a close.
private func readResponse(_ fd: Int32) throws -> RawResponse {
  var received = [UInt8]()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let text = String(decoding: received, as: UTF8.self)
    if let end = text.range(of: "\r\n\r\n") {
      let length =
        text[..<end.lowerBound].split(separator: "\r\n")
        .first { $0.lowercased().hasPrefix("content-length:") }
        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
      if text[end.upperBound...].utf8.count >= length { return RawResponse(raw: text) }
    }
    let count = recv(fd, &buffer, buffer.count, 0)
    guard count > 0 else { throw POSIXError(.ECONNRESET) }
    received += buffer[0..<count]
  }
}

/// A connected socket to `address:port` with a 5 s read timeout; the caller closes it.
private func openConnection(_ port: Int, address: String = "127.0.0.1") throws -> Int32 {
  let isIPv6 = address.contains(":")
  let fd = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { throw POSIXError(.EBADF) }
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
  guard connected == 0 else {
    let code = POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED
    close(fd)
    throw POSIXError(code)
  }
  return fd
}
