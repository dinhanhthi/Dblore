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

  /// Stepper rule: 1,000 below 10,000, 5,000 below 50,000, and 10,000 at or above.
  /// Stepping down from a boundary uses the smaller step. The result stays in range.
  nonisolated static func steppedHistoryMaxEntries(_ value: Int, up: Bool) -> Int {
    let basis = up ? value : value - 1
    let step: Int
    if basis >= 50_000 {
      step = 10_000
    } else if basis >= 10_000 {
      step = 5_000
    } else {
      step = 1_000
    }
    return clampHistoryMaxEntries(up ? value + step : value - step)
  }
}

/// Applies the current retention window and entry cap. Stepper clicks share one prune.
enum QueryHistoryPrune {
  private static var generation = 0

  /// Reads settings when the prune runs, so a burst of changes keeps the latest cap.
  @MainActor
  static func schedule() {
    guard !SessionManager.isRunningAsTestHost else { return }
    generation += 1
    let token = generation
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(200))
      guard token == generation else { return }
      let settings = AppSettings.shared
      do {
        try await QueryHistoryStore.shared.prune(
          olderThan: QueryHistoryStore.retentionCutoff(
            retentionDays: settings.historyRetentionDays),
          maxEntries: settings.historyMaxEntries)
        guard token == generation else { return }
        LocalDataNotifications.post(.queryHistory)
      } catch {
        await AppLogger.shared.error(
          "Query history prune failed: \(error.localizedDescription)", category: "History")
      }
    }
  }
}
