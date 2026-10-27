// LockKeyStore.swift
// The content key of each locked workspace in the Keychain (service ace.thi.dblore.lock.keys,
// account workspace:<UUID>). Behind user presence first; when that item cannot be added, an
// explicit app-gated item (read only after an in-app owner authentication); without the
// Keychain or a login password, nothing (Lock password only). The mode is returned and
// recorded per key so callers can show it. The recorded mode is display-only (UserDefaults,
// so it can be changed outside the app): it never decides whether to authenticate; `read`
// always takes an owner-authentication proof. Key bytes are never logged.

import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Where a workspace content key is kept.
nonisolated enum LockKeyMode: String, Equatable, Sendable {
  /// Keychain item behind user presence
  case presence
  /// Plain WhenUnlockedThisDeviceOnly item, read only after `.deviceOwnerAuthentication`
  case appGated
  /// No Keychain item: the workspace unlocks with the Lock password only
  case unavailable
}

nonisolated enum LockKeyStoreError: Error, Equatable, Sendable {
  /// The keybag is locked (errSecInteractionNotAllowed): try again once the Mac is unlocked
  case retryable(OSStatus)
  case failed(OSStatus)
  /// The stored item is not a 32-byte key
  case invalidKey
}

nonisolated struct LockKeyStore: Sendable {
  static let serviceName = "ace.thi.dblore.lock.keys"
  /// UserDefaults key of the recorded modes ([workspace UUID: LockKeyMode raw value])
  static let modesKey = "lockKeyModes"

  private let vault: KeychainVault
  /// UserDefaults is documented as thread-safe
  nonisolated(unsafe) private let modes: UserDefaults
  private let passcodeSet: @Sendable () -> Bool

  init(
    vault: KeychainVault = KeychainVault(
      service: LockKeyStore.serviceName, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly),
    modes: UserDefaults = .standard,
    passcodeSet: @escaping @Sendable () -> Bool = LockKeyStore.loginPasswordSet
  ) {
    self.vault = vault
    self.modes = modes
    self.passcodeSet = passcodeSet
  }

  static func account(for workspaceId: UUID) -> String { "workspace:\(workspaceId.uuidString)" }

  /// Replaces any stored key: user presence first, then the reported app-gated fallback. A
  /// missing entitlement or no login password is `.unavailable`; a locked keybag throws
  /// `.retryable` and never falls back.
  func store(_ key: SymmetricKey, for workspaceId: UUID) throws(LockKeyStoreError) -> LockKeyMode {
    let account = Self.account(for: workspaceId)
    // A new key per Lock: a stale item (either form) goes first, and with it the old mode
    let removed = vault.delete(account: account)
    guard removed == errSecSuccess else {
      guard let mode = try terminal(removed) else { throw .failed(removed) }
      record(mode, for: workspaceId)
      return mode
    }
    record(nil, for: workspaceId)
    let mode = try place(key.withUnsafeBytes { Data($0) }, account: account)
    record(mode, for: workspaceId)
    return mode
  }

  /// The key, whatever the recorded mode, only with an owner-authentication proof; nil when no
  /// item exists. Callers invalidate the proof after the read.
  func read(
    for workspaceId: UUID, authentication: OwnerAuthentication
  ) throws(LockKeyStoreError) -> SymmetricKey? {
    switch vault.readProtected(
      account: Self.account(for: workspaceId), context: authentication.context)
    {
    case .found(let data):
      guard data.count == 32 else { throw .invalidKey }
      return SymmetricKey(data: data)
    case .notFound:
      return nil
    case .failed(let status):
      throw status == errSecInteractionNotAllowed ? .retryable(status) : .failed(status)
    }
  }

  /// The recorded mode, nil when no key was stored for this workspace. For display only.
  func mode(for workspaceId: UUID) -> LockKeyMode? {
    let recorded = modes.dictionary(forKey: Self.modesKey) as? [String: String]
    return recorded?[workspaceId.uuidString].flatMap(LockKeyMode.init(rawValue:))
  }

  /// Deletes the key and always clears its recorded mode. A missing item or a missing
  /// entitlement (no item can exist) is nothing to delete.
  @discardableResult func remove(for workspaceId: UUID) -> OSStatus {
    let status = vault.delete(account: Self.account(for: workspaceId))
    record(nil, for: workspaceId)
    switch status {
    case errSecItemNotFound, errSecMissingEntitlement: return errSecSuccess
    default: return status
    }
  }

  private func place(_ data: Data, account: String) throws(LockKeyStoreError) -> LockKeyMode {
    guard passcodeSet() else { return .unavailable }
    let presence = vault.writeProtected(account: account, data: data)
    if presence == errSecSuccess { return .presence }
    if let mode = try terminal(presence) { return mode }
    // Explicit fallback, reported to the caller as .appGated
    let appGated = vault.write(account: account, data: data)
    if appGated == errSecSuccess { return .appGated }
    if let mode = try terminal(appGated) { return mode }
    throw .failed(appGated)
  }

  /// Statuses that end the attempt: a missing entitlement (ad hoc build) is `.unavailable`, a
  /// locked keybag throws `.retryable`. Nil for any other status.
  private func terminal(_ status: OSStatus) throws(LockKeyStoreError) -> LockKeyMode? {
    switch status {
    case errSecMissingEntitlement: return .unavailable
    case errSecInteractionNotAllowed: throw .retryable(status)
    default: return nil
    }
  }

  private func record(_ mode: LockKeyMode?, for workspaceId: UUID) {
    var recorded = modes.dictionary(forKey: Self.modesKey) as? [String: String] ?? [:]
    recorded[workspaceId.uuidString] = mode?.rawValue
    modes.set(recorded, forKey: Self.modesKey)
  }

  /// False only when the Mac has no login password (nothing can satisfy user presence).
  static func loginPasswordSet() -> Bool {
    var error: NSError?
    if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return true }
    return error?.code != LAError.Code.passcodeNotSet.rawValue
  }
}
