//
//  AppSettings+RowCap.swift
//  Dblore
//
//  The single result row cap (notebook and editor) and the one-time migration of the legacy
//  per-mode row limit keys.
//

import Foundation

extension AppSettings {
  /// UserDefaults key of `resultRowCap`
  nonisolated static let resultRowCapKey = "app.settings.resultRowCap"

  /// Default rows shown per statement when none is stored (a stored value, even the old
  /// default 100, is an explicit choice and is kept)
  nonisolated static let defaultResultRowCap = 10_000

  /// Pre-C6 keys (notebook 50-100, editor 100-200), migrated once then deleted
  private nonisolated static let legacyRowLimitKeys = [
    "app.settings.maxRowLimit", "app.settings.editorMaxRowLimit",
  ]

  /// Clamp to `SessionBrakeLimits.rowCapRange`; non-positive → default
  nonisolated static func clampResultRowCap(_ value: Int) -> Int {
    SessionBrakeLimits.clampRowCap(value) ?? defaultResultRowCap
  }

  /// Stepper rule: step 100 below 1000 and 1000 at or above (stepping down from 1000 gives
  /// 900), clamped to `SessionBrakeLimits.rowCapRange`
  nonisolated static func steppedResultRowCap(_ value: Int, up: Bool) -> Int {
    let range = SessionBrakeLimits.rowCapRange
    let next: Int
    if up {
      next = value + (value >= 1000 ? 1000 : 100)
    } else {
      // Above 1000, step down by 1000 but stop at 1000 before switching to steps of 100.
      next = value > 1000 ? max(value - 1000, 1000) : value - 100
    }
    return min(max(next, range.lowerBound), range.upperBound)
  }

  /// Stored cap (clamped), or nil when none is stored. When only the legacy keys exist, the
  /// larger of the two (clamped) is stored under the new key; legacy keys are always deleted.
  nonisolated static func loadResultRowCap(from defaults: UserDefaults) -> Int? {
    let legacy = legacyRowLimitKeys.compactMap { key -> Int? in
      defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }
    for key in legacyRowLimitKeys {
      defaults.removeObject(forKey: key)
    }

    if defaults.object(forKey: resultRowCapKey) != nil {
      return clampResultRowCap(defaults.integer(forKey: resultRowCapKey))
    }
    guard let largest = legacy.max() else { return nil }
    let migrated = clampResultRowCap(largest)
    defaults.set(migrated, forKey: resultRowCapKey)
    return migrated
  }
}
