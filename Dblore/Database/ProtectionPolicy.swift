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
    self.init(
      config: config,
      supportsTransactions: config?.databaseType.capabilities.supportsTransactions ?? true)
  }

  /// Without transactions (MongoDB) Protected mode cannot hold a change, so it is ignored.
  init(config: ConnectionConfig?, supportsTransactions: Bool) {
    guard let config else {
      self.init(protectionLevel: .none)
      return
    }
    self.init(
      protectionLevel: Self.gatingLevel(of: config), safeMode: config.safeMode,
      protectedMode: supportsTransactions && config.protectedMode)
  }

  /// The level the gate enforces, which can be stricter than the configured (displayed) one.
  /// A DuckDB file opened read-only gates as at least Read-only: DuckDB SQL can still write the
  /// database file and its `.wal` in READ_ONLY access mode (e.g. `COPY ... TO '<db>'
  /// (USE_TMP_FILE false)` corrupts it). In-memory DuckDB ignores `readOnlyFile`. SQLite's
  /// read-only open already refuses SQL writes.
  private static func gatingLevel(of config: ConnectionConfig) -> ConnectionProtectionLevel {
    guard config.databaseType == .duckdb, config.readOnlyFile,
      config.database != DuckDBSession.inMemoryPath,
      config.protectionLevel.strictness < ConnectionProtectionLevel.readOnly.strictness
    else { return config.protectionLevel }
    return .readOnly
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

  /// `self` while a timed write unlock runs (`writesUnlocked`): Read-only lowers to Schema only
  /// (data writes allowed, schema changes still blocked), never to None. Other levels and every
  /// other field stay as they are.
  func unlockingWrites(_ writesUnlocked: Bool) -> ProtectionPolicy {
    guard writesUnlocked, protectionLevel == .readOnly else { return self }
    return ProtectionPolicy(
      protectionLevel: .schemaOnly, safeMode: safeMode, protectedMode: protectedMode)
  }

  /// Why `config` cannot get a timed write unlock, or nil when it can. Only a Read-only row is
  /// unlocked (a Schema only row already writes data). A DuckDB row with Read-only protection
  /// opens its file read-only (`DuckDBSession`), and a SQLite `readOnlyFile` row opens it
  /// read-only too: lowering the gate would not make either writable, and the unlock never
  /// reopens a session.
  static func writeUnlockRefusal(for config: ConnectionConfig) -> String? {
    guard config.protectionLevel == .readOnly else {
      return "Only a Read-only connection can unlock writes."
    }
    if config.databaseType == .duckdb {
      return "A Read-only DuckDB connection opens its file read-only. Edit the connection to write."
    }
    if config.databaseType == .sqlite, config.readOnlyFile {
      return "This SQLite file is open read-only. Edit the connection to write."
    }
    return nil
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
