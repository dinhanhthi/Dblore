// ProtectionPolicy.swift
// Per-execution snapshot of a connection's protection settings, passed to the execution gate

import Foundation

/// What the execution gate (`DatabaseConnectionManager.execute(userSQL:policy:)`) enforces.
/// Built from the notebook's `ConnectionConfig` at each execution, because the protection level
/// can change at runtime.
nonisolated struct ProtectionPolicy: Sendable {
  let protectionLevel: ConnectionProtectionLevel
  /// Per-connection Safe Mode override (confirmation stays in the ViewModel)
  let safeMode: SafeMode?
  /// Protected dry-run mode (used from Phase 3)
  let protectedMode: Bool

  init(
    protectionLevel: ConnectionProtectionLevel, safeMode: SafeMode? = nil,
    protectedMode: Bool = false
  ) {
    self.protectionLevel = protectionLevel
    self.safeMode = safeMode
    self.protectedMode = protectedMode
  }

  /// A missing config means no protection (same as before the gate existed).
  init(config: ConnectionConfig?) {
    guard let config else {
      self.init(protectionLevel: .none)
      return
    }
    self.init(
      protectionLevel: config.protectionLevel, safeMode: config.safeMode,
      protectedMode: config.protectedMode)
  }

  /// The stricter of `self` (the caller's policy) and `other` (e.g. the connected config):
  /// higher protection level, protected mode if either has it. Safe Mode (a ViewModel concern)
  /// stays the caller's. Never weaker than either input.
  func stricter(_ other: ProtectionPolicy) -> ProtectionPolicy {
    ProtectionPolicy(
      protectionLevel: protectionLevel.strictness >= other.protectionLevel.strictness
        ? protectionLevel : other.protectionLevel,
      safeMode: safeMode,
      protectedMode: protectedMode || other.protectedMode)
  }
}

extension ConnectionProtectionLevel {
  /// Ordering used by the stricter merge: .none < .schemaOnly < .readOnly
  nonisolated var strictness: Int {
    switch self {
    case .none: 0
    case .schemaOnly: 1
    case .readOnly: 2
    }
  }
}
