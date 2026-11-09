// CappedReadLimitsTests.swift
// The per-row cap (`CappedReadLimits.cut`): MCP limits cut long cells a little past
// `maxCellCharacters`; limits that mark cut cells (`marksCutCells`) cut at exactly the limit and
// record where. Every kept cell counts toward the byte budget. Unit tests (pure, or a manager
// over a fake session); the capped reads against a server are in DatabaseCappedReadTests.

import Foundation
import Testing

@testable import Dblore

@Suite("Capped read limits")
@MainActor
struct CappedReadLimitsTests {
  /// Small limits that mark cut cells, as the app's do
  private static let marking = CappedReadLimits(
    maxCellCharacters: 64, maxResultBytes: 4_096, marksCutCells: true)

  @Test("A long decimal is cut like text and counted as its UTF-8 bytes")
  func longDecimalIsCut() {
    let limits = CappedReadLimits(maxCellCharacters: 10, maxResultBytes: 1_000)
    let digits = String(repeating: "9", count: 50)
    let cut = limits.cut([.decimal(digits), .decimal("1.5")])
    #expect(cut.row == [.decimal(String(repeating: "9", count: 11)), .decimal("1.5")])
    #expect(cut.bytes == 11 + 3)
  }

  @Test("Marking limits cut text and binary at exactly the limit and name the cut columns")
  func markingCutsAtTheLimit() {
    let cut = Self.marking.cut([
      .string(String(repeating: "a", count: 65)), .string(String(repeating: "b", count: 64)),
      .data(Data(repeating: 1, count: 100)), .int(1),
    ])
    #expect(
      cut.row == [
        .string(String(repeating: "a", count: 64)), .string(String(repeating: "b", count: 64)),
        .data(Data(repeating: 1, count: 64)), .int(1),
      ])
    #expect(cut.cutColumns == [0, 2])
  }

  // MARK: - Reads through a manager

  private static let long = String(repeating: "x", count: 3_000) + "1234"

  private func manager(
    limits: CappedReadLimits, columns: [String], rows: [[CellValue]],
    maskRules: [ColumnMaskRule] = []
  ) async throws -> DatabaseConnectionManager {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.sqlite.capabilities,
      columns: columns.map { ColumnInfo(name: $0, type: "TEXT") }, rows: rows)
    let manager = DatabaseConnectionManager(sessionFactory: factory, readLimits: limits)
    var config = ConnectionConfig(
      databaseType: .sqlite, host: "fake", port: 0, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    config.maskRules = maskRules
    try await manager.connect(config: config)
    return manager
  }

  private func read(
    _ manager: DatabaseConnectionManager, _ sql: String
  ) async throws
    -> QueryResult
  {
    let result = try await manager.execute(
      userSQL: sql, policy: ProtectionPolicy(protectionLevel: .none))
    await manager.disconnect()
    return result
  }

  @Test("A marking read keeps the limit, records each cut cell, and a script keeps the last's")
  func markingReadRecordsCutCells() async throws {
    let short = "short"
    let manager = try await manager(
      limits: Self.marking, columns: ["a", "b"],
      rows: [[.string(Self.long), .string(short)], [.string(short), .string(Self.long)]])
    let result = try await read(manager, "SELECT 1; SELECT a, b FROM t")
    let kept = CellValue.string(String(Self.long.prefix(64)))
    #expect(result.rows == [[kept, .string(short)], [.string(short), kept]])
    #expect(result.cutCells == [CellPosition(row: 0, column: 0), CellPosition(row: 1, column: 1)])
    #expect(!result.truncated)
    #expect(!result.stoppedAtByteBudget)
  }

  @Test("MCP limits keep one character past and record no cut cell")
  func mcpReadKeepsOnePast() async throws {
    let limits = CappedReadLimits(maxCellCharacters: 64, maxResultBytes: 4_096)
    let manager = try await manager(limits: limits, columns: ["a"], rows: [[.string(Self.long)]])
    let result = try await read(manager, "SELECT a FROM t")
    #expect(result.rows == [[.string(String(Self.long.prefix(65)))]])
    #expect(result.cutCells.isEmpty)
  }

  @Test("Kept cells past the byte budget stop the read, marked as a byte stop")
  func byteBudgetStopsTheRead() async throws {
    // 64 kept bytes per row: the 65th row passes 4 KiB
    let rows = Array(repeating: [CellValue.string(Self.long)], count: 100)
    let manager = try await manager(limits: Self.marking, columns: ["a"], rows: rows)
    let result = try await read(manager, "SELECT a FROM t")
    #expect(result.rows.count == 64)
    #expect(result.truncated)
    #expect(result.stoppedAtByteBudget)
    #expect(result.cutCells == Set((0..<64).map { CellPosition(row: $0, column: 0) }))
  }

  @Test("A cut cell under lastFour shows the full mask and leaves cutCells; others stay cut")
  func cutCellUnderLastFourMasksFully() async throws {
    let manager = try await manager(
      limits: Self.marking, columns: ["email", "note"],
      rows: [[.string(Self.long), .string(Self.long)], [.string("ab12345"), .string("n")]],
      maskRules: [try ColumnMaskRule(pattern: "email", style: .lastFour)])
    let result = try await read(manager, "SELECT email, note FROM t")
    #expect(result.rows[0][0] == .string(ColumnMaskRule.maskText))
    #expect(result.rows[1][0] == .string(ColumnMaskRule.maskText + "2345"))
    #expect(result.cutCells == [CellPosition(row: 0, column: 1)])
  }
}
