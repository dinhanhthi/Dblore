// CappedReadLimitsTests.swift
// The MCP pool's per-row cap (`CappedReadLimits.cut`): long cells are cut a little past
// `maxCellCharacters` and every kept cell counts toward the byte budget. Pure unit tests; the
// capped reads against a server are in DatabaseCappedReadTests (integration).

import Foundation
import Testing

@testable import Dblore

@Suite("Capped read limits")
@MainActor
struct CappedReadLimitsTests {
  @Test("A long decimal is cut like text and counted as its UTF-8 bytes")
  func longDecimalIsCut() {
    let limits = CappedReadLimits(maxCellCharacters: 10, maxResultBytes: 1_000)
    let digits = String(repeating: "9", count: 50)
    let cut = limits.cut([.decimal(digits), .decimal("1.5")])
    #expect(cut.row == [.decimal(String(repeating: "9", count: 11)), .decimal("1.5")])
    #expect(cut.bytes == 11 + 3)
  }
}
