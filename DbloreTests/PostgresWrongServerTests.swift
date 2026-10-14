// PostgresWrongServerTests.swift
// A PostgreSQL connection to a port where another database listens must say so,
// not show PostgresNIO's raw messageDecodingFailure.

import Darwin
import Foundation
import Testing

@testable import Dblore

/// Sends the MySQL 8.4.11 greeting on accept, as a MySQL server does, then closes the
/// connection once the client answers.
private final class MySQLGreetingServer: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "ace.thi.dblore.mysql-greeting")
  private var listenFD: Int32 = -1

  /// The bytes from the reported error: `J`, length 10, protocol 10, "8.4.11".
  private static let greeting: [UInt8] = [0x4A, 0, 0, 0, 0x0A] + Array("8.4.11".utf8)

  func start() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.ENODEV) }
    var noSignal: Int32 = 1
    setsockopt(
      fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ready = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
      }
    }
    guard ready else {
      close(fd)
      throw POSIXError(.EADDRNOTAVAIL)
    }
    lock.lock()
    listenFD = fd
    lock.unlock()
    queue.async { self.serve(listenFD: fd) }
    return Int(UInt16(bigEndian: address.sin_port))
  }

  func stop() {
    lock.lock()
    let fd = listenFD
    listenFD = -1
    lock.unlock()
    if fd >= 0 { close(fd) }
  }

  /// Every attempt gets the greeting: `attemptConnection` retries a failed connect.
  private func serve(listenFD: Int32) {
    while true {
      let client = accept(listenFD, nil, nil)
      guard client >= 0 else { return }
      var noSignal: Int32 = 1
      setsockopt(
        client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout.size(ofValue: noSignal)))
      _ = Self.greeting.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
      // MySQL drops a client whose reply is not a MySQL handshake response
      var buffer = [UInt8](repeating: 0, count: 512)
      _ = read(client, &buffer, buffer.count)
      close(client)
    }
  }
}

// The probe retries a failed connect after 1, 2 and 4 seconds, so the last error needs ~7s.
@Suite("Postgres connection to a non-PostgreSQL server")
struct PostgresWrongServerTests {
  @Test(
    "probe names the protocol mismatch instead of messageDecodingFailure",
    .timeLimit(.minutes(1)),
    arguments: [SSLMode.disable, .prefer]
  )
  func probeReportsNonPostgresServer(sslMode: SSLMode) async throws {
    let server = MySQLGreetingServer()
    let port = try server.start()
    defer { server.stop() }
    let config = ConnectionConfig(
      host: "127.0.0.1", port: port, database: "db", username: "user", password: "pw",
      sslMode: sslMode, timeoutSeconds: 15)
    do {
      _ = try await PostgresSession(config: config).probe()
      Issue.record("probe returned; expected a connection failure")
    } catch let DatabaseError.connectionFailed(message) {
      #expect(message.hasPrefix("The server did not answer with the PostgreSQL protocol"))
      #expect(!message.contains("messageDecodingFailure"))
    }
  }
}
