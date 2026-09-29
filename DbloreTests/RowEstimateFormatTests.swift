// RowEstimateFormatTests.swift
// Compact "~12.3k" sidebar row estimate: nil/negative hide the badge, half-up rounding on the
// displayed decimal, and a rollover to the next unit instead of "~1000k".

import Testing

@testable import Dblore

@Suite("Row Estimate Format")
struct RowEstimateFormatTests {
  @Test(
    "compactRowEstimate table",
    arguments: [
      (nil, nil),
      (-1, nil),
      (0, "~0"),
      (1, "~1"),
      (999, "~999"),
      (1000, "~1k"),
      (1049, "~1k"),
      (1050, "~1.1k"),
      (12_345, "~12.3k"),
      (999_949, "~999.9k"),
      (999_950, "~1M"),
      (1_000_000, "~1M"),
      (1_200_000, "~1.2M"),
      (999_950_000, "~1B"),
      (3_400_000_000, "~3.4B"),
    ] as [(Int?, String?)]
  )
  func table(input: Int?, expected: String?) {
    #expect(compactRowEstimate(input) == expected)
  }
}
