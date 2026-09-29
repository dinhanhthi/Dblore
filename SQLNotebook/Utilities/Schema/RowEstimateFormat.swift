//
//  RowEstimateFormat.swift
//  SQLNotebook
//
//  Compact "~12.3k" formatting of a table row estimate (pg_class.reltuples)
//

import Foundation

/// Formats a row estimate as "~999", "~12.3k", "~1.2M", "~3.4B"; nil or negative gives nil.
/// One decimal, round-half-up, trailing ".0" dropped; rolls over to the next unit instead of
/// printing "~1000k".
nonisolated func compactRowEstimate(_ n: Int?) -> String? {
  guard let n, n >= 0 else { return nil }
  if n < 1000 { return "~\(n)" }
  let units: [(divisor: Int, suffix: String)] = [
    (1_000, "k"), (1_000_000, "M"), (1_000_000_000, "B"),
  ]
  for (index, unit) in units.enumerated() {
    let tenths = (n * 10 + unit.divisor / 2) / unit.divisor
    if tenths >= 10_000 && index < units.count - 1 { continue }
    let whole = tenths / 10
    let fraction = tenths % 10
    return fraction == 0 ? "~\(whole)\(unit.suffix)" : "~\(whole).\(fraction)\(unit.suffix)"
  }
  return nil
}
