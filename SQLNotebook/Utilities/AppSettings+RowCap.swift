//
//  AppSettings+RowCap.swift
//  SQLNotebook
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

  /// Stored cap (clamped), or nil when none is stored. When only the legacy keys exist, the
  /// larger of the two (clamped) is stored under the new key; legacy keys are always deleted.
  nonisolated static func loadResultRowCap(from defaults: UserDefaults) -> Int? {
    let legacy = legacyRowLimitKeys.compactMap { key -> Int? in
      defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }
    legacyRowLimitKeys.forEach { defaults.removeObject(forKey: $0) }

    if defaults.object(forKey: resultRowCapKey) != nil {
      return clampResultRowCap(defaults.integer(forKey: resultRowCapKey))
    }
    guard let largest = legacy.max() else { return nil }
    let migrated = clampResultRowCap(largest)
    defaults.set(migrated, forKey: resultRowCapKey)
    return migrated
  }
}
