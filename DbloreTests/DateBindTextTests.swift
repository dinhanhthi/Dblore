import Foundation
import Testing

@testable import Dblore

@Suite("Date bind text")
struct DateBindTextTests {
  @Test("PostgreSQL infinity beyond Int64 microseconds has no fraction and does not trap")
  func infinityHasNoFraction() {
    // PostgresNIO decodes infinity as Int64.max microseconds after 2000-01-01.
    let postgresEpoch = Date(timeIntervalSince1970: 946_684_800)
    let infinity = postgresEpoch.addingTimeInterval(Double(Int64.max) / 1_000_000)
    let text = DateBindText.string(from: infinity)
    #expect(text.hasSuffix("Z"))
    #expect(!text.contains("."))
  }

  @Test("PostgreSQL -infinity does not trap")
  func negativeInfinityDoesNotTrap() {
    let postgresEpoch = Date(timeIntervalSince1970: 946_684_800)
    let negativeInfinity = postgresEpoch.addingTimeInterval(Double(Int64.min) / 1_000_000)
    #expect(DateBindText.string(from: negativeInfinity).hasSuffix("Z"))
  }
}
