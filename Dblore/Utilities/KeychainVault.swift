// KeychainVault.swift
// One generic-password Keychain service, stored in the data protection keychain. Debug and
// Release builds share its access group, while file-based keychain ACLs trusted only the
// signature that created an item. Reads fall back to the legacy file-based keychain and copy
// a hit into the data protection keychain; a read then sweeps the legacy copy once it is
// verified as redundant (no UI, once per key and launch, only the key named by a launch argument
// in Debug builds). Protected items (behind user presence) live in the data protection keychain
// only.

import Foundation
import LocalAuthentication
import Security
import os

/// Result of one Keychain lookup. A failure (for example a denied prompt) is never a miss.
nonisolated enum KeychainRead: Equatable, Sendable {
  case found(Data)
  case notFound
  case failed(OSStatus)
}

/// Access control of a protected item. It replaces the plain accessibility.
nonisolated enum KeychainAccessControl: Equatable, Sendable {
  /// Touch ID or the Mac password on every read, only while a login password is set
  /// (kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly + .userPresence).
  case userPresence
}

/// One Keychain domain (data protection or legacy file-based). Tests inject an in-memory twin.
nonisolated protocol KeychainBackend: Sendable {
  /// `context` is the caller's evaluated LAContext that satisfies a protected item's access
  /// control; only `KeychainVault.readProtected` passes one. Without it the query is a plain
  /// read, unchanged for every other secret. Reading a protected item that way is out of scope
  /// (the system would prompt; no caller does it); the in-memory twin fails it closed so such a
  /// caller surfaces in tests.
  func copy(service: String, account: String, context: LAContext?) -> KeychainRead
  func add(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus
  /// Updates the data and accessibility (or access control), or adds the item when it does not
  /// exist.
  func upsert(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus
  func delete(service: String, account: String) -> OSStatus
  /// `context` is the legacy sweep's no-interaction context: with one whose
  /// `interactionNotAllowed` is true the delete also refuses UI, so an item that would prompt
  /// fails instead.
  func delete(service: String, account: String, context: LAContext?) -> OSStatus
  /// Account names only; item data is never read.
  func accounts(service: String) -> [String]
  /// The item's modification date, read attributes-only (no data, no prompt). Nil when it
  /// cannot be read.
  func modificationDate(service: String, account: String) -> Date?
  /// Reads the data without any UI: an item that would need user interaction fails (for
  /// example `errSecInteractionNotAllowed`) instead of prompting.
  func copyWithoutUI(service: String, account: String) -> KeychainRead
}

nonisolated extension KeychainBackend {
  func copy(service: String, account: String) -> KeychainRead {
    copy(service: service, account: account, context: nil)
  }

  func add(service: String, account: String, data: Data, accessible: CFString) -> OSStatus {
    add(service: service, account: account, data: data, accessible: accessible, accessControl: nil)
  }

  func upsert(service: String, account: String, data: Data, accessible: CFString) -> OSStatus {
    upsert(
      service: service, account: account, data: data, accessible: accessible, accessControl: nil)
  }

  func delete(service: String, account: String, context: LAContext?) -> OSStatus {
    delete(service: service, account: account)
  }

  func modificationDate(service: String, account: String) -> Date? { nil }

  func copyWithoutUI(service: String, account: String) -> KeychainRead {
    copy(service: service, account: account, context: nil)
  }
}

/// An LAContext that never shows UI: a query that would need user interaction fails.
nonisolated private func keychainNoInteractionContext() -> LAContext {
  let context = LAContext()
  context.interactionNotAllowed = true
  return context
}

/// Turns the file-based keychain's user interaction off around one SecItem call, so an item whose
/// ACL would show the SecurityAgent dialog fails (`errSecInteractionNotAllowed`) instead.
/// `LAContext.interactionNotAllowed` and `kSecUseAuthenticationUIFail` do not govern that dialog
/// (found by the phase 7 host probe). The setting is process-global: while it is off, any other
/// thread's file-keychain operation fails instead of prompting, so it is held only for one SecItem
/// call, under a process-wide lock. The SDK no longer declares the C functions, so they are
/// resolved at runtime from Security.
nonisolated enum FileKeychainInteraction {
  private typealias Getter = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
  private typealias Setter = @convention(c) (DarwinBoolean) -> OSStatus

  /// Resolved once; a missing symbol is logged once.
  private static let functions: (get: Getter, set: Setter)? = {
    // RTLD_DEFAULT ((void *) -2 in <dlfcn.h>) is a macro Swift does not import.
    let everyImage = UnsafeMutableRawPointer(bitPattern: -2)
    guard let get = dlsym(everyImage, "SecKeychainGetUserInteractionAllowed"),
      let set = dlsym(everyImage, "SecKeychainSetUserInteractionAllowed")
    else {
      KeychainLog.interactionSwitchFailed("resolve", nil)
      return nil
    }
    return (unsafeBitCast(get, to: Getter.self), unsafeBitCast(set, to: Setter.self))
  }()

  private static let lock = OSAllocatedUnfairLock()

  /// Runs `body` with interaction off, then restores the previous state. Nil, without running
  /// `body`, when the functions are missing or reading or switching the state fails (fail closed:
  /// the caller reads or deletes nothing).
  static func withInteractionDisabled<T>(_ body: () -> T) -> T? {
    guard let functions else { return nil }
    lock.lock()
    defer { lock.unlock() }
    var previous = DarwinBoolean(true)
    let read = functions.get(&previous)
    guard read == errSecSuccess else {
      KeychainLog.interactionSwitchFailed("read", read)
      return nil
    }
    let off = functions.set(false)
    guard off == errSecSuccess else {
      KeychainLog.interactionSwitchFailed("disable", off)
      return nil
    }
    defer {
      let restored = functions.set(previous)
      if restored != errSecSuccess { KeychainLog.interactionSwitchFailed("restore", restored) }
    }
    return body()
  }

  /// The current state, nil when it cannot be read. Takes no lock (tests call it inside `body`).
  static func isAllowed() -> Bool? {
    guard let functions else { return nil }
    var state = DarwinBoolean(true)
    return functions.get(&state) == errSecSuccess ? state.boolValue : nil
  }
}

/// SecItem calls on generic-password items. No access group is set, so items land in the
/// default one (the first keychain-access-groups entitlement).
nonisolated struct SecItemKeychainBackend: KeychainBackend {
  let dataProtection: Bool

  init(dataProtection: Bool) {
    self.dataProtection = dataProtection
  }

  private var domain: String { dataProtection ? "data protection" : "legacy" }

  func query(service: String, account: String? = nil) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    if let account { query[kSecAttrAccount as String] = account }
    if dataProtection {
      query[kSecUseDataProtectionKeychain as String] = true
      query[kSecAttrSynchronizable as String] = false
    } else {
      // Explicit false: without it a legacy query also matches data protection items.
      query[kSecUseDataProtectionKeychain as String] = false
    }
    return query
  }

  func copy(service: String, account: String, context: LAContext?) -> KeychainRead {
    var query = query(service: service, account: account)
    if let context { query[kSecUseAuthenticationContext as String] = context }
    return copy(query, operation: "copy", service: service, account: account)
  }

  func copyWithoutUI(service: String, account: String) -> KeychainRead {
    var query = query(service: service, account: account)
    Self.refuseUI(&query, context: keychainNoInteractionContext())
    let operation = "copy without UI"
    guard !dataProtection else {
      return copy(query, operation: operation, service: service, account: account)
    }
    return FileKeychainInteraction.withInteractionDisabled {
      copy(query, operation: operation, service: service, account: account)
    } ?? .failed(errSecInteractionNotAllowed)
  }

  private func copy(
    _ query: [String: Any], operation: String, service: String, account: String
  ) -> KeychainRead {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    KeychainLog.status(status, operation, domain, service, account)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { return .failed(errSecDecode) }
      return .found(data)
    case errSecItemNotFound: return .notFound
    default: return .failed(status)
    }
  }

  func add(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus {
    var attributes = query(service: service, account: account)
    attributes[kSecValueData as String] = data
    guard Self.protect(&attributes, accessible: accessible, accessControl: accessControl) else {
      return errSecParam
    }
    let status = SecItemAdd(attributes as CFDictionary, nil)
    KeychainLog.status(status, "add", domain, service, account)
    return status
  }

  func upsert(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus {
    var changes: [String: Any] = [kSecValueData as String: data]
    guard Self.protect(&changes, accessible: accessible, accessControl: accessControl) else {
      return errSecParam
    }
    let status = SecItemUpdate(
      query(service: service, account: account) as CFDictionary, changes as CFDictionary)
    guard status == errSecItemNotFound else {
      KeychainLog.status(status, "update", domain, service, account)
      return status
    }
    return add(
      service: service, account: account, data: data, accessible: accessible,
      accessControl: accessControl)
  }

  /// Sets either the access control or the plain accessibility (SecItem refuses both). False
  /// when the access control cannot be built: the caller fails, never writes a plain item.
  private static func protect(
    _ attributes: inout [String: Any], accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> Bool {
    guard let accessControl else {
      attributes[kSecAttrAccessible as String] = accessible
      return true
    }
    switch accessControl {
    case .userPresence:
      guard
        let access = SecAccessControlCreateWithFlags(
          nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil)
      else { return false }
      attributes[kSecAttrAccessControl as String] = access
      return true
    }
  }

  func delete(service: String, account: String) -> OSStatus {
    delete(service: service, account: account, context: nil)
  }

  func delete(service: String, account: String, context: LAContext?) -> OSStatus {
    var query = query(service: service, account: account)
    if let context { Self.refuseUI(&query, context: context) }
    let status: OSStatus
    if !dataProtection, context?.interactionNotAllowed == true {
      status =
        FileKeychainInteraction.withInteractionDisabled { SecItemDelete(query as CFDictionary) }
        ?? errSecInteractionNotAllowed
    } else {
      status = SecItemDelete(query as CFDictionary)
    }
    KeychainLog.status(
      status, context == nil ? "delete" : "delete without UI", domain, service, account)
    return status
  }

  /// Passes `context` and, when it disallows interaction, also asks SecItem to fail rather than
  /// show UI. Neither key governs the file-based keychain's ACL dialog: the legacy backend also
  /// wraps its no-UI calls in `FileKeychainInteraction`.
  private static func refuseUI(_ query: inout [String: Any], context: LAContext) {
    query[kSecUseAuthenticationContext as String] = context
    if context.interactionNotAllowed {
      query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }
  }

  func modificationDate(service: String, account: String) -> Date? {
    var query = query(service: service, account: account)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    KeychainLog.status(status, "modification date", domain, service, account)
    guard status == errSecSuccess, let attributes = result as? [String: Any] else { return nil }
    return attributes[kSecAttrModificationDate as String] as? Date
  }

  func accounts(service: String) -> [String] {
    var query = query(service: service)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    KeychainLog.status(status, "accounts", domain, service, nil)
    guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
    return items.compactMap { $0[kSecAttrAccount as String] as? String }
  }
}

/// Which (service, account) keys the legacy sweep may touch.
nonisolated enum KeychainSweepPolicy: Equatable, Sendable {
  case everyKey
  case onlyKey(service: String, account: String)
  case noKey

  func allows(service: String, account: String) -> Bool {
    switch self {
    case .everyKey: true
    case .onlyKey(let only, let onlyAccount): only == service && onlyAccount == account
    case .noKey: false
    }
  }

  /// Read once per launch. Release sweeps every key; a Debug build (Xcode runs, the test host)
  /// sweeps only the key named by `-keychainSweepOnly "<service>|<account>"`, otherwise none.
  static let launch: KeychainSweepPolicy = {
    #if DEBUG
      debug(arguments: ProcessInfo.processInfo.arguments)
    #else
      .everyKey
    #endif
  }()

  /// The Debug fence: the value after `-keychainSweepOnly`, split at its first `|`. A missing or
  /// malformed value sweeps nothing.
  static func debug(arguments: [String]) -> KeychainSweepPolicy {
    guard let flag = arguments.firstIndex(of: "-keychainSweepOnly"),
      flag + 1 < arguments.count
    else { return .noKey }
    let value = arguments[flag + 1]
    guard let bar = value.firstIndex(of: "|") else { return .noKey }
    let service = String(value[..<bar])
    let account = String(value[value.index(after: bar)...])
    guard !service.isEmpty, !account.isEmpty else { return .noKey }
    return .onlyKey(service: service, account: account)
  }
}

/// The (service, account) keys already swept in this launch, so each is tried at most once.
nonisolated final class KeychainSweepTracker: Sendable {
  /// The process-wide tracker every default vault shares (vaults are values built per call).
  static let shared = KeychainSweepTracker()

  private struct Key: Hashable {
    let service: String
    let account: String
  }

  private let swept = OSAllocatedUnfairLock(initialState: Set<Key>())

  /// True the first time a key is claimed in this launch, false after.
  func claim(service: String, account: String) -> Bool {
    swept.withLock { $0.insert(Key(service: service, account: account)).inserted }
  }
}

/// A service in the data protection keychain, migrated lazily from the legacy keychain.
nonisolated struct KeychainVault: Sendable {
  let service: String
  /// Kept as a String: CFString is not Sendable.
  private let accessibility: String
  private let modern: any KeychainBackend
  private let legacy: any KeychainBackend
  private let sweepTracker: KeychainSweepTracker
  private let sweepPolicy: KeychainSweepPolicy

  private var accessible: CFString { accessibility as CFString }

  init(
    service: String, accessible: CFString,
    modern: any KeychainBackend = SecItemKeychainBackend(dataProtection: true),
    legacy: any KeychainBackend = SecItemKeychainBackend(dataProtection: false),
    sweepTracker: KeychainSweepTracker = .shared,
    sweepPolicy: KeychainSweepPolicy = .launch
  ) {
    self.service = service
    self.accessibility = accessible as String
    self.modern = modern
    self.legacy = legacy
    self.sweepTracker = sweepTracker
    self.sweepPolicy = sweepPolicy
  }

  /// Data protection first. A legacy hit is copied over (never overwriting) and returned even
  /// when the copy fails; a legacy failure stays a failure so callers can fail closed. Then the
  /// legacy copy is swept (at most once per key and launch, as the sweep policy allows); the
  /// sweep never changes the result.
  func read(account: String) -> KeychainRead {
    let current = modern.copy(service: service, account: account)
    if case .found(let data) = current { sweepLegacy(account: account, current: data) }
    guard current == .notFound else { return current }
    let old = legacy.copy(service: service, account: account)
    if case .found(let data) = old,
      modern.add(service: service, account: account, data: data, accessible: accessible)
        == errSecSuccess
    {
      sweepCopiedLegacy(account: account, copied: data)
    }
    return old
  }

  private func claimSweep(account: String) -> Bool {
    sweepPolicy.allows(service: service, account: account)
      && sweepTracker.claim(service: service, account: account)
  }

  /// After a data protection hit: reads the legacy copy without UI and deletes it when it equals
  /// `current`, or differs and is older than the data protection item. A failed read, a newer
  /// differing copy or an unreadable date keeps it.
  private func sweepLegacy(account: String, current: Data) {
    guard claimSweep(account: account),
      case .found(let old) = legacy.copyWithoutUI(service: service, account: account)
    else { return }
    guard old != current else { return deleteLegacy(account: account) }
    if let legacyDate = legacy.modificationDate(service: service, account: account),
      let currentDate = modern.modificationDate(service: service, account: account),
      legacyDate < currentDate
    {
      deleteLegacy(account: account)
    } else {
      KeychainLog.keptDifferingLegacy(service, account)
    }
  }

  /// After a legacy-only hit was copied over: deletes the legacy copy only when a re-read of the
  /// data protection item returns the same bytes.
  private func sweepCopiedLegacy(account: String, copied: Data) {
    guard claimSweep(account: account),
      modern.copy(service: service, account: account) == .found(copied)
    else { return }
    deleteLegacy(account: account)
  }

  private func deleteLegacy(account: String) {
    _ = legacy.delete(service: service, account: account, context: keychainNoInteractionContext())
  }

  /// Writes to the data protection keychain only; the legacy copy is left alone.
  @discardableResult func write(account: String, data: Data) -> OSStatus {
    modern.upsert(service: service, account: account, data: data, accessible: accessible)
  }

  /// Adds only when absent: false on a duplicate or any failure.
  func add(account: String, data: Data) -> Bool {
    modern.add(service: service, account: account, data: data, accessible: accessible)
      == errSecSuccess
  }

  /// Writes a protected item to the data protection keychain only. A failure is returned as is:
  /// there is no plain fallback here.
  @discardableResult func writeProtected(
    account: String, data: Data, accessControl: KeychainAccessControl = .userPresence
  ) -> OSStatus {
    modern.upsert(
      service: service, account: account, data: data, accessible: accessible,
      accessControl: accessControl)
  }

  /// Reads with an evaluated context from the data protection keychain only: a legacy hit is
  /// never migrated as a plain item.
  func readProtected(account: String, context: LAContext) -> KeychainRead {
    modern.copy(service: service, account: account, context: context)
  }

  /// Deletes in both keychains, legacy first: when the legacy delete fails the modern copy is
  /// kept, so a later read cannot migrate the old value back. A missing item is fine.
  @discardableResult func delete(account: String) -> OSStatus {
    for backend in [legacy, modern] {
      let status = backend.delete(service: service, account: account)
      guard status == errSecSuccess || status == errSecItemNotFound else { return status }
    }
    return errSecSuccess
  }

  /// Accounts in either keychain, data protection order first, without duplicates.
  func accounts() -> [String] {
    var seen = Set<String>()
    return (modern.accounts(service: service) + legacy.accounts(service: service))
      .filter { seen.insert($0).inserted }
  }
}

/// Keychain statuses worth a look. Accounts are private; data is never logged.
nonisolated private enum KeychainLog {
  static let logger = Logger(subsystem: "ace.thi.dblore.app", category: "Keychain")

  static func status(
    _ status: OSStatus, _ operation: String, _ domain: String, _ service: String,
    _ account: String?
  ) {
    guard status != errSecSuccess, status != errSecItemNotFound else { return }
    let message = SecCopyErrorMessageString(status, nil) as String? ?? ""
    logger.error(
      "\(operation, privacy: .public) \(domain, privacy: .public) \(service, privacy: .public) \(account ?? "-", privacy: .private): \(status) \(message, privacy: .public)"
    )
  }

  /// The file-keychain interaction switch failed at `step` (nil status: the symbols are missing),
  /// so the sweep's legacy read or delete is skipped.
  static func interactionSwitchFailed(_ step: String, _ status: OSStatus?) {
    logger.error(
      "file keychain interaction switch \(step, privacy: .public) failed: \(status.map { "\($0)" } ?? "missing symbols", privacy: .public)"
    )
  }

  /// A differing legacy copy the sweep keeps (newer, or its date is unreadable). Logged once per
  /// key and launch, as the sweep runs once.
  static func keptDifferingLegacy(_ service: String, _ account: String) {
    logger.notice(
      "sweep kept a differing legacy copy \(service, privacy: .public) \(account, privacy: .private)"
    )
  }
}
