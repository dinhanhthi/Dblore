// UnreadableVaultSecretStore.swift
// A Vault secret store whose reads of some accounts fail, as a denied or locked Keychain does.

import Foundation
import Security

@testable import Dblore

/// Throws `ConnectionPasswordError.unreadable` from `readSecret` for the accounts given to
/// `failReads` (none until then; every account when nil), and `load` flattens that to nil like
/// the Keychain store; everything else goes to an in-memory store. Records deletes. Never opens
/// the Keychain.
nonisolated final class UnreadableVaultSecretStore: VaultSecretStore, @unchecked Sendable {
  let base = InMemoryVaultSecretStore()
  let status: OSStatus
  private let lock = NSLock()
  private var unreadableAccounts: Set<String>? = []
  private var deleted: [String] = []

  init(status: OSStatus = errSecInteractionNotAllowed) {
    self.status = status
  }

  var deletedAccounts: [String] { lock.withLock { deleted } }

  /// From now on, reads of `accounts` fail (every account when nil)
  func failReads(of accounts: Set<String>?) {
    lock.withLock { unreadableAccounts = accounts }
  }

  func readSecret(account: String) throws -> VaultStoredSecret? {
    let fails = lock.withLock { unreadableAccounts.map { $0.contains(account) } ?? true }
    if fails { throw ConnectionPasswordError.unreadable(status) }
    return base.load(account: account)
  }

  func load(account: String) -> VaultStoredSecret? {
    (try? readSecret(account: account)) ?? nil
  }

  func save(_ secret: VaultStoredSecret, account: String) -> VaultSecretSave {
    base.save(secret, account: account)
  }

  func delete(account: String) {
    lock.withLock { deleted.append(account) }
    base.delete(account: account)
  }

  func isSessionOnly(account: String) -> Bool { false }
}
