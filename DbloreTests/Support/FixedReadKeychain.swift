// FixedReadKeychain.swift
// A Keychain domain whose every lookup returns one fixed answer.

import Foundation
import LocalAuthentication
import Security

@testable import Dblore

/// A Keychain domain whose every lookup returns `read`; writes return `writeStatus` (success
/// by default) and keep nothing.
nonisolated struct FixedReadKeychain: KeychainBackend {
  let read: KeychainRead
  var writeStatus: OSStatus = errSecSuccess

  func copy(service: String, account: String, context: LAContext?) -> KeychainRead { read }

  func add(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus { writeStatus }

  func upsert(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus { writeStatus }

  func delete(service: String, account: String) -> OSStatus { errSecSuccess }

  func accounts(service: String) -> [String] { [] }
}
