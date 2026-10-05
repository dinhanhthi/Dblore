// PostgresProbeTimeoutTests.swift
// probe() must time out when startup finishes and SELECT 1 never returns.
// A silent accept only hits attemptConnection; this server completes v3 startup first.

import Darwin
import Foundation
import Testing

@testable import Dblore

/// One client. Answers AuthenticationOk, BackendKeyData, and ReadyForQuery, then does not
/// answer the query. PostgresNIO drops ReadyForQuery when BackendKeyData is missing.
private final class QueryStallServer: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "ace.thi.dblore.query-stall")
  private var listenFD: Int32 = -1
  private var clientFD: Int32 = -1
  private var sawTestQuery = false

  func start() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.ENODEV) }
    var reuse: Int32 = 1
    setsockopt(
      fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
    var noSignal: Int32 = 1
    setsockopt(
      fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 1) == 0 else {
      close(fd)
      throw POSIXError(.EADDRNOTAVAIL)
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &boundAddress) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    guard named == 0 else {
      close(fd)
      throw POSIXError(.EADDRNOTAVAIL)
    }

    lock.lock()
    listenFD = fd
    lock.unlock()
    let port = Int(UInt16(bigEndian: boundAddress.sin_port))
    queue.async { self.serve(listenFD: fd) }
    return port
  }

  func stop() {
    lock.lock()
    let listenFD = self.listenFD
    let clientFD = self.clientFD
    self.listenFD = -1
    self.clientFD = -1
    lock.unlock()
    if listenFD >= 0 { close(listenFD) }
    if clientFD >= 0 { close(clientFD) }
  }

  var didSeeTestQuery: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sawTestQuery
  }

  private func serve(listenFD: Int32) {
    let client = accept(listenFD, nil, nil)
    guard client >= 0 else { return }
    lock.lock()
    let stopped = self.listenFD < 0
    if !stopped { clientFD = client }
    lock.unlock()
    guard !stopped else {
      close(client)
      return
    }
    var noSignal: Int32 = 1
    setsockopt(
      client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
      socklen_t(MemoryLayout.size(ofValue: noSignal)))
    guard readStartup(client), writeAll(client, Self.startupComplete) else { return }
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let needle = Data("SELECT 1 as test".utf8)
    while true {
      let count = read(client, &buffer, buffer.count)
      if count <= 0 { return }
      pending.append(contentsOf: buffer.prefix(count))
      if pending.range(of: needle) != nil {
        lock.lock()
        sawTestQuery = true
        lock.unlock()
        return
      }
    }
  }

  /// AuthenticationOk, BackendKeyData, ReadyForQuery (idle).
  private static let startupComplete: [UInt8] = {
    func int32(_ value: UInt32) -> [UInt8] {
      [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value),
      ]
    }
    func message(_ id: UInt8, _ payload: [UInt8]) -> [UInt8] {
      [id] + int32(UInt32(4 + payload.count)) + payload
    }
    return message(UInt8(ascii: "R"), int32(0))
      + message(UInt8(ascii: "K"), int32(1) + int32(1))
      + message(UInt8(ascii: "Z"), [UInt8(ascii: "I")])
  }()

  private func readStartup(_ fd: Int32) -> Bool {
    guard let header = readExact(fd, 4) else { return false }
    let length =
      (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
    guard length >= 8, length <= 8192 else { return false }
    return readExact(fd, length - 4) != nil
  }

  private func readExact(_ fd: Int32, _ count: Int) -> [UInt8]? {
    var result: [UInt8] = []
    result.reserveCapacity(count)
    var buffer = [UInt8](repeating: 0, count: count)
    var remaining = count
    while remaining > 0 {
      let count = read(fd, &buffer, remaining)
      if count <= 0 { return nil }
      result.append(contentsOf: buffer.prefix(count))
      remaining -= count
    }
    return result
  }

  private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var sent = 0
    while sent < bytes.count {
      let count = bytes.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return write(fd, base.advanced(by: sent), bytes.count - sent)
      }
      if count <= 0 { return false }
      sent += count
    }
    return true
  }
}

@Suite("Postgres probe timeout")
struct PostgresProbeTimeoutTests {
  @Test(
    "probe fails when startup completes and SELECT 1 never returns",
    .timeLimit(.minutes(1))
  )
  func probeTimesOutWhenQueryNeverReturns() async throws {
    let server = QueryStallServer()
    let port = try server.start()
    defer { server.stop() }
    let timeoutSeconds = 1
    let config = ConnectionConfig(
      host: "127.0.0.1", port: port, database: "db", username: "user", password: "pw",
      sslMode: .disable, timeoutSeconds: timeoutSeconds)
    let clock = ContinuousClock()
    let started = clock.now
    do {
      _ = try await PostgresSession(config: config).probe()
      Issue.record("probe returned; expected a timeout")
    } catch let DatabaseError.connectionFailed(message) {
      #expect(message.contains("Connection timeout after \(timeoutSeconds) seconds"))
    }
    let elapsed = clock.now - started
    #expect(elapsed >= .milliseconds(500))
    #expect(elapsed < .seconds(10))
    #expect(server.didSeeTestQuery)
  }
}
