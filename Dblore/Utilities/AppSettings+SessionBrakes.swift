//
//  AppSettings+SessionBrakes.swift
//  Dblore
//
//  Global statement / lock / idle-in-transaction timeouts. A connection's own timeout wins
//  (see `ConnectionConfig.resolvingBrakes`).
//

import Foundation

extension AppSettings {
  nonisolated static let statementTimeoutKey = "app.settings.statementTimeout"
  nonisolated static let lockTimeoutKey = "app.settings.lockTimeout"
  nonisolated static let idleTimeoutKey = "app.settings.idleTimeout"

  var sessionBrakeDefaults: SessionBrakeDefaults {
    SessionBrakeDefaults(statement: statementTimeout, lock: lockTimeout, idle: idleTimeout)
  }

  /// Stored values replace the built-in defaults; a missing key keeps the default.
  func loadSessionBrakeDefaults(from defaults: UserDefaults) {
    if defaults.object(forKey: Self.statementTimeoutKey) != nil {
      statementTimeout = defaults.integer(forKey: Self.statementTimeoutKey)
    }
    if defaults.object(forKey: Self.lockTimeoutKey) != nil {
      lockTimeout = defaults.integer(forKey: Self.lockTimeoutKey)
    }
    if defaults.object(forKey: Self.idleTimeoutKey) != nil {
      idleTimeout = defaults.integer(forKey: Self.idleTimeoutKey)
    }
  }
}
