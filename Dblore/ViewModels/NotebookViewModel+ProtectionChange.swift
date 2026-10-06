//
//  NotebookViewModel+ProtectionChange.swift
//  Dblore
//
//  Runtime changes of a connection's commit style and protection level. Unlock runs only when
//  a Safe Mode password or Touch ID is configured. Lowering from review or password needs it
//  (immediate < confirm < review < password). confirm → immediate does not. Lowering the
//  protection level needs it only while the current style is password. The check compares
//  resolved commit styles; it does not project legacy fields.
//

import Foundation

/// The safety settings of a connection that a runtime change can weaken.
nonisolated struct ConnectionSafetyState: Equatable, Sendable {
  let commitStyle: CommitStyle
  let protectionLevel: ConnectionProtectionLevel

  init(commitStyle: CommitStyle, protectionLevel: ConnectionProtectionLevel) {
    self.commitStyle = commitStyle
    self.protectionLevel = protectionLevel
  }

  /// No config: the default commit style, no protection (same as a missing policy).
  init(config: ConnectionConfig?, defaultCommitStyle: CommitStyle) {
    self.init(
      commitStyle: config?.resolvedCommitStyle(fallback: defaultCommitStyle) ?? defaultCommitStyle,
      protectionLevel: config?.protectionLevel ?? .none)
  }
}

extension NotebookViewModel {
  // MARK: - Decision (pure)

  /// True when a Safe Mode password or Touch ID is configured and the change either lowers
  /// the commit style from `review` or `password`, or lowers the protection level while the
  /// current style is `password`.
  nonisolated static func requiresUnlockForChange(
    from old: ConnectionSafetyState, to new: ConnectionSafetyState,
    hasPassword: Bool, hasTouchID: Bool
  ) -> Bool {
    guard hasPassword || hasTouchID else { return false }
    let styleWeakened =
      new.commitStyle.strength < old.commitStyle.strength
      && (old.commitStyle == .review || old.commitStyle == .password)
    let levelLowered =
      new.protectionLevel.strictness < old.protectionLevel.strictness
      && old.commitStyle == .password
    return styleWeakened || levelLowered
  }

  /// Default commit-style picker: the same rule, on the style alone. With no unlock
  /// configured (no password, Touch ID off) nothing gates.
  nonisolated static func requiresUnlockForGlobalSafeModeChange(
    from old: CommitStyle, to new: CommitStyle, hasPassword: Bool, hasTouchID: Bool
  ) -> Bool {
    requiresUnlockForChange(
      from: ConnectionSafetyState(commitStyle: old, protectionLevel: .none),
      to: ConnectionSafetyState(commitStyle: new, protectionLevel: .none),
      hasPassword: hasPassword, hasTouchID: hasTouchID)
  }

  // MARK: - Requests (apply now, or hold for the unlock)
  // Without a connection config there is nothing to change: true, no unlock.

  /// Commit style the user already chose. Applied now (via `applyCommitStyle`) and returns
  /// true unless it needs the unlock (returns false, nothing changed: apply with
  /// `applyConnectionCommitStyle` after a successful unlock).
  func requestConnectionCommitStyle(
    _ style: CommitStyle, defaultCommitStyle: CommitStyle = AppSettings.shared.commitStyle
  ) -> Bool {
    guard let current = notebook.connectionConfig else { return true }
    let from = ConnectionSafetyState(config: current, defaultCommitStyle: defaultCommitStyle)
    let to = ConnectionSafetyState(commitStyle: style, protectionLevel: current.protectionLevel)
    guard !needsUnlock(from: from, to: to) else { return false }
    applyConnectionCommitStyle(style)
    return true
  }

  /// Per-connection Safe Mode (`nil` = use global). Kept for the current Safe Mode menus.
  /// Applied now and returns true unless the resolved commit style needs the unlock.
  func requestConnectionSafeModeChange(
    to safeMode: SafeMode?, defaultCommitStyle: CommitStyle = AppSettings.shared.commitStyle
  ) -> Bool {
    guard var proposed = notebook.connectionConfig else { return true }
    proposed.safeMode = safeMode
    guard !requiresUnlock(for: proposed, defaultCommitStyle: defaultCommitStyle) else {
      return false
    }
    applyConnectionSafeMode(safeMode)
    return true
  }

  /// Connection protection level. Applied now and returns true unless it needs the unlock
  /// (returns false, nothing changed: apply with `applyProtectionLevel` after the unlock).
  /// A protection-level change writes `protectionLevel` only.
  func requestProtectionLevelChange(
    to level: ConnectionProtectionLevel,
    defaultCommitStyle: CommitStyle = AppSettings.shared.commitStyle
  ) -> Bool {
    guard let current = notebook.connectionConfig else { return true }
    let from = ConnectionSafetyState(config: current, defaultCommitStyle: defaultCommitStyle)
    let to = ConnectionSafetyState(commitStyle: from.commitStyle, protectionLevel: level)
    guard !needsUnlock(from: from, to: to) else { return false }
    applyProtectionLevel(level)
    return true
  }

  // MARK: - Apply (after the request or a successful unlock)

  /// Stores the commit style the user already chose, including its legacy pair.
  func applyConnectionCommitStyle(_ style: CommitStyle) {
    notebook.connectionConfig?.applyCommitStyle(style)
    onDocumentChanged?()
  }

  func applyConnectionSafeMode(_ safeMode: SafeMode?) {
    notebook.connectionConfig?.safeMode = safeMode
    onDocumentChanged?()
  }

  func applyProtectionLevel(_ level: ConnectionProtectionLevel) {
    notebook.connectionConfig?.protectionLevel = level
    onDocumentChanged?()
  }

  private func needsUnlock(from old: ConnectionSafetyState, to new: ConnectionSafetyState) -> Bool {
    Self.requiresUnlockForChange(
      from: old, to: new,
      hasPassword: AppSettings.shared.hasCustomPasswordSet,
      hasTouchID: AppSettings.shared.isBiometricEnabled)
  }

  private func requiresUnlock(
    for proposed: ConnectionConfig, defaultCommitStyle: CommitStyle
  ) -> Bool {
    needsUnlock(
      from: ConnectionSafetyState(
        config: notebook.connectionConfig, defaultCommitStyle: defaultCommitStyle),
      to: ConnectionSafetyState(config: proposed, defaultCommitStyle: defaultCommitStyle))
  }
}
