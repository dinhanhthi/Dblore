// MySQLLargePacketTests.swift
// A 17 MiB LONGBLOB through MySQLSession on MySQL 8.4 (3307) and MariaDB 11.4 (3308). The
// INSERTs (a 34 MiB hex literal over COM_QUERY, a 34 MiB bind over COM_STMT_EXECUTE) and the
// 17 MiB rows (text and binary protocol) cross MySQL's 16 MiB packet size, so mysql-nio splits
// and reassembles them (fork patch D). The servers run with max_allowed_packet=64M
// (docker/mysql/docker-compose.test.yml). Opt-in (`.requiresMySQL`). Tables use `big_`.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MySQLLargePacketTests {
  typealias Server = MySQLSessionTests.Server

  /// 17 MiB, past the 16 MiB (0xFFFFFF) payload of one packet.
  static let size = 17 * 1024 * 1024

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  @Test(
    "A 17 MiB LONGBLOB round-trips byte for byte", .requiresMySQL, .timeLimit(.minutes(2)),
    arguments: [Server.mysql, .mariadb])
  func longBlobRoundTrip(server: Server) async throws {
    let blob = Self.blob()
    let hex = Self.hex(blob)
    let table = "big_blob"
    try await MySQLSessionTests.withSession(MySQLSessionTests.config(port: server.port)) {
      session in
      _ = try await session.command("DROP TABLE IF EXISTS \(table)", binds: [])
      _ = try await session.command(
        "CREATE TABLE \(table) (id INT PRIMARY KEY, data LONGBLOB)", binds: [])
      do {
        let literal = try await session.command(
          "INSERT INTO \(table) VALUES (1, X'\(hex)')", binds: [])
        let bound = try await session.command(
          "INSERT INTO \(table) VALUES (2, UNHEX(?))", binds: [.text(hex)])
        #expect(literal.affectedRows == 1)
        #expect(bound.affectedRows == 1)

        // Text protocol: each row starts with the blob's 0xFE length prefix.
        let text = try await MySQLSessionTests.rows(
          session, "SELECT data FROM \(table) ORDER BY id")
        #expect(text.rows.count == 2)
        #expect(text.rows.allSatisfy { $0 == [.data(blob)] })

        // Binary protocol.
        let binary = try await MySQLSessionTests.rows(
          session, "SELECT LENGTH(data), data FROM \(table) WHERE id = ?", binds: [.text("2")])
        #expect(binary.rows.count == 1)
        #expect(binary.rows.first?.first == .int(Self.size))
        #expect(binary.rows.first?.last == .data(blob))
      } catch {
        _ = try? await session.command("DROP TABLE IF EXISTS \(table)", binds: [])
        throw error
      }
      _ = try await session.command("DROP TABLE IF EXISTS \(table)", binds: [])
      // The connection still works after the multi-packet exchanges.
      let after = try await MySQLSessionTests.rows(session, "SELECT 1")
      #expect(after.rows == [[.int(1)]])
    }
  }

  /// Every byte value, in an order that depends on the offset, so a misplaced chunk shows.
  static func blob() -> Data {
    Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
  }

  static func hex(_ data: Data) -> String {
    let digits = Array("0123456789ABCDEF".utf8)
    var ascii = [UInt8]()
    ascii.reserveCapacity(data.count * 2)
    for byte in data {
      ascii.append(digits[Int(byte >> 4)])
      ascii.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: ascii, as: UTF8.self)
  }
}
