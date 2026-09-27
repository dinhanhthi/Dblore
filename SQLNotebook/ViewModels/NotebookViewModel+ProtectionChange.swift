//
//  NotebookViewModel+ProtectionChange.swift
//  SQLNotebook
//
//  Runtime changes of the connection's safety settings (per-connection Safe Mode, protection
//  level, protected mode). A change that weakens them needs the Safe Mode unlock (Touch ID or
//  Safe Mode password; database password only when no Safe Mode password exists) while the
//  current effective Safe Mode requires a password. Strengthening never does.
//

import Foundation

/// The safety settings of a connection that a runtime change can weaken
nonisolated struct ConnectionSafetyState: Equatable, Sendable {
  /// Effective Safe Mode: the per-connection override, else the global mode
  let safeMode: SafeMode
  let protectionLevel: ConnectionProtectionLevel
  let protectedMode: Bool

  init(safeMode: SafeMode, protectionLevel: ConnectionProtectionLevel, protectedMode: Bool) {
    self.safeMode = safeMode
    self.protectionLevel = protectionLevel
    self.protectedMode = protectedMode
  }

  /// No config: global Safe Mode, no protection (same as `ProtectionPolicy(config: nil)`)
  init(config: ConnectionConfig?, globalSafeMode: SafeMode) {
    self.init(
      safeMode: config?.safeMode ?? globalSafeMode,
      protectionLevel: config?.protectionLevel ?? .none,
      protectedMode: config?.protectedMode ?? false)
  }
}

extension SafeMode {
  /// Explicit strength ordering: silent < alertRead < alertAll < safeRead < safeAll.
  /// A password level is stronger than every dialog level (safeRead > alertAll: dropping the
  /// password is a weakening even if more statement kinds get a dialog).
  nonisolated var strength: Int {
    switch self {
    case .silent: 0
    case .alertRead: 1
    case .alertAll: 2
    case .safeRead: 3
    case .safeAll: 4
    }
  }
}

extension NotebookViewModel {
  // MARK: - Decision (pure)

  /// True if changing `old` to `new` needs the Safe Mode unlock: the current effective Safe
  /// Mode requires a password AND the change weakens the effective Safe Mode, lowers the
  /// protection level (readOnly -> schemaOnly/none, schemaOnly -> none) or turns protected
  /// mode off.
  nonisolated static func requiresUnlockForChange(
    from old: ConnectionSafetyState, to new: ConnectionSafetyState
  ) -> Bool {
    switch old.safeMode {
    case .safeRead, .safeAll: break
    case .silent, .alertRead, .alertAll: return false
    }
    return new.safeMode.strength < old.safeMode.strength
      || new.protectionLevel.strictness < old.protectionLevel.strictness
      || (old.protectedMode && !new.protectedMode)
  }

  /// Global Safe Mode picker: the per-connection rule on the Safe Mode alone (weakening away
  /// from a password mode needs the unlock, strengthening never does). With no unlock
  /// configured (no password, Touch ID off) nothing gates: there is nothing to verify against.
  nonisolated static func requiresUnlockForGlobalSafeModeChange(
    from old: SafeMode, to new: SafeMode, hasPassword: Bool, hasTouchID: Bool
  ) -> Bool {
    guard hasPassword || hasTouchID else { return false }
    return requiresUnlockForChange(
      from: ConnectionSafetyState(safeMode: old, protectionLevel: .none, protectedMode: false),
      to: ConnectionSafetyState(safeMode: new, protectionLevel: .none, protectedMode: false))
  }

  // MARK: - Requests (apply now, or hold for the unlock)
  // Without a connection config there is nothing to change: true, no unlock.

  /// Per-connection Safe Mode (`nil` = use global). Applied now and returns true unless it
  /// needs the unlock (returns false, nothing changed: apply with `applyConnectionSafeMode`
  /// after a successful unlock).
  func requestConnectionSafeModeChange(
    to safeMode: SafeMode?, globalSafeMode: SafeMode = AppSettings.shared.safeMode
  ) -> Bool {
    guard var proposed = notebook.connectionConfig else { return true }  // nothing to protect
    proposed.safeMode = safeMode
    guard !requiresUnlock(for: proposed, globalSafeMode: globalSafeMode) else { return false }
    applyConnectionSafeMode(safeMode)
    return true
  }

  /// Connection protection level. Applied now and returns true unless it needs the unlock
  /// (returns false, nothing changed: apply with `applyProtectionLevel` after the unlock).
  func requestProtectionLevelChange(
    to level: ConnectionProtectionLevel, globalSafeMode: SafeMode = AppSettings.shared.safeMode
  ) -> Bool {
    guard var proposed = notebook.connectionConfig else { return true }  // nothing to protect
    proposed.protectionLevel = level
    guard !requiresUnlock(for: proposed, globalSafeMode: globalSafeMode) else { return false }
    applyProtectionLevel(level)
    return true
  }

  // MARK: - Apply (after the request or a successful unlock)

  func applyConnectionSafeMode(_ safeMode: SafeMode?) {
    notebook.connectionConfig?.safeMode = safeMode
    onDocumentChanged?()
  }

  func applyProtectionLevel(_ level: ConnectionProtectionLevel) {
    notebook.connectionConfig?.protectionLevel = level
    onDocumentChanged?()
  }

  private func requiresUnlock(for proposed: ConnectionConfig, globalSafeMode: SafeMode) -> Bool {
    Self.requiresUnlockForChange(
      from: ConnectionSafetyState(
        config: notebook.connectionConfig, globalSafeMode: globalSafeMode),
      to: ConnectionSafetyState(config: proposed, globalSafeMode: globalSafeMode))
  }
}
