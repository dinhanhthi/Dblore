// UUIDGeneratorTests.swift
// UUIDv7 layout (RFC 9562 section 5.7): timestamp field, version and variant bits, ordering.
// UUIDv4 from a given generator (section 5.4): version and variant bits.

import Foundation
import Testing

@testable import Dblore

@Suite("UUID generator")
struct UUIDGeneratorTests {
  /// Fixed bytes, so only the generator's layout decides the text
  private struct FixedGenerator: RandomNumberGenerator {
    var value: UInt64
    mutating func next() -> UInt64 { value }
  }

  @Test("A UUIDv7 carries the millisecond timestamp, version 7 and variant 10")
  func v7Layout() {
    var random = FixedGenerator(value: .max)
    let text = UUIDGenerator.v7(milliseconds: 0x0190_1234_5678, using: &random)
    let characters = Array(text)

    #expect(text.count == 36)
    #expect(text == text.lowercased())
    #expect(text.hasPrefix("01901234-5678-"))
    #expect(characters[14] == "7")
    #expect(characters[19] == "b")
    #expect(characters[8] == "-" && characters[13] == "-" && characters[18] == "-")
    #expect(characters[23] == "-")
  }

  @Test("A UUIDv4 from a given generator carries version 4 and variant 10")
  func v4Layout() {
    var random = FixedGenerator(value: .max)

    #expect(UUIDGenerator.v4(using: &random) == "ffffffff-ffff-4fff-bfff-ffffffffffff")
  }

  @Test("A later millisecond sorts after an earlier one as text")
  func v7OrdersAcrossMilliseconds() {
    var high = FixedGenerator(value: .max)
    var low = FixedGenerator(value: 0)
    let earlier = UUIDGenerator.v7(milliseconds: 1_700_000_000_000, using: &high)
    let later = UUIDGenerator.v7(milliseconds: 1_700_000_000_001, using: &low)

    #expect(earlier < later)
    #expect(Array(later)[19] == "8")
  }
}
