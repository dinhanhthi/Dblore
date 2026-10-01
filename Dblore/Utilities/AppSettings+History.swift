//
//  AppSettings+History.swift
//  Dblore
//
//  Query history retention: allowed day choices and the entry-cap clamp.
//

import Foundation

extension AppSettings {
  /// Days of history kept when none is stored
  nonisolated static let defaultHistoryRetentionDays = 90

  /// History rows kept when none is stored
  nonisolated static let defaultHistoryMaxEntries = 50_000

  /// Inclusive cap on stored history rows
  nonisolated static let historyMaxEntriesRange = 1_000...500_000

  /// Anything outside 7, 30, 90, 365, and 0 (forever) becomes 90
  nonisolated static func clampHistoryRetentionDays(_ value: Int) -> Int {
    switch value {
    case 0, 7, 30, 90, 365: return value
    default: return defaultHistoryRetentionDays
    }
  }

  /// Clamp to `historyMaxEntriesRange`
  nonisolated static func clampHistoryMaxEntries(_ value: Int) -> Int {
    min(max(value, historyMaxEntriesRange.lowerBound), historyMaxEntriesRange.upperBound)
  }
}
