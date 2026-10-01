// SessionBrakeLimits.swift
// Allowed ranges and defaults for the per-connection safety settings, shared by the
// session SQL builder and the connection form so both clamp identically.

import Foundation

/// Allowed ranges and defaults for the per-connection safety settings.
/// Shared by the SQL builder and the connection form so both clamp identically.
nonisolated enum SessionBrakeLimits {
  static let statementTimeoutRange = 1...86400
  static let lockTimeoutRange = 1...3600
  static let idleTimeoutRange = 1...86400
  static let rowCapRange = 100...100_000

  static let defaultStatementTimeout = 60
  static let defaultLockTimeout = 5
  static let defaultIdleTimeout = 600

  /// Non-positive → `defaultValue` (0 would disable the brake); otherwise clamp to `range`.
  static func clamp(_ value: Int, to range: ClosedRange<Int>, default defaultValue: Int) -> Int {
    value <= 0 ? defaultValue : min(max(value, range.lowerBound), range.upperBound)
  }

  static func clampStatementTimeout(_ value: Int) -> Int {
    clamp(value, to: statementTimeoutRange, default: defaultStatementTimeout)
  }

  static func clampLockTimeout(_ value: Int) -> Int {
    clamp(value, to: lockTimeoutRange, default: defaultLockTimeout)
  }

  static func clampIdleTimeout(_ value: Int) -> Int {
    clamp(value, to: idleTimeoutRange, default: defaultIdleTimeout)
  }

  /// `nil` or non-positive → `nil` (use the global setting); otherwise clamp to `rowCapRange`.
  static func clampRowCap(_ value: Int?) -> Int? {
    guard let value, value > 0 else { return nil }
    return min(max(value, rowCapRange.lowerBound), rowCapRange.upperBound)
  }
}
