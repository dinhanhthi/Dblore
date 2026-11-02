// ConnectionPasswordStoreTests.swift
// A connection password read tells a missing item from one the Keychain could not read.

import Foundation
import Security
import Testing

@testable import Dblore

@Suite("Connection password store")
@MainActor
struct ConnectionPasswordStoreTests {
  private static func store(_ read: KeychainRead) -> KeychainConnectionPasswordStore {
    KeychainConnectionPasswordStore(
      vault: KeychainVault(
        service: SessionManager.keychainService, accessible: kSecAttrAccessibleAfterFirstUnlock,
        modern: FixedReadKeychain(read: read), legacy: FixedReadKeychain(read: .notFound)))
  }

  @Test("A missing password reads as nil and a stored one as its text")
  func readsMissingAndStoredPasswords() throws {
    #expect(try Self.store(.notFound).readPassword(forKey: "k") == nil)
    #expect(try Self.store(.found(Data("secret".utf8))).readPassword(forKey: "k") == "secret")
  }

  @Test("A failed read or non-UTF-8 data throws unreadable")
  func unreadablePasswordThrows() {
    #expect(throws: ConnectionPasswordError.unreadable(errSecInteractionNotAllowed)) {
      try Self.store(.failed(errSecInteractionNotAllowed)).readPassword(forKey: "k")
    }
    #expect(throws: ConnectionPasswordError.unreadable(errSecDecode)) {
      try Self.store(.found(Data([0xFF, 0xFE]))).readPassword(forKey: "k")
    }
    let unreadable = UnreadableConnectionPasswordStore()
    #expect(throws: ConnectionPasswordError.unreadable(errSecInteractionNotAllowed)) {
      try unreadable.readPassword(forKey: "k")
    }
    #expect(unreadable.readKeys == ["k"])
  }

  @Test("The unreadable password error names the connection")
  func unreadableErrorNamesConnection() {
    let message = DatabaseError.passwordStoreUnreadable(name: "Coffee Shop").localizedDescription
    #expect(message.contains("Coffee Shop"))
  }
}
