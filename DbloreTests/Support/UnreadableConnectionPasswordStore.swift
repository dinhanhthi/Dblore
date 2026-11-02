// UnreadableConnectionPasswordStore.swift
// A connection password store whose every read fails, as a denied or locked Keychain does.

import Foundation
import Security

@testable import Dblore

/// Throws `ConnectionPasswordError.unreadable` on every read and records saves and deletes.
/// Never opens the Keychain.
@MainActor
final class UnreadableConnectionPasswordStore: ConnectionPasswordStore {
  let status: OSStatus
  private(set) var readKeys: [String] = []
  private(set) var savedKeys: [String] = []
  private(set) var deletedKeys: [String] = []

  init(status: OSStatus = errSecInteractionNotAllowed) {
    self.status = status
  }

  func savePassword(_ password: String, forKey key: String) {
    savedKeys.append(key)
  }

  func readPassword(forKey key: String) throws -> String? {
    readKeys.append(key)
    throw ConnectionPasswordError.unreadable(status)
  }

  func deletePassword(forKey key: String) {
    deletedKeys.append(key)
  }
}
