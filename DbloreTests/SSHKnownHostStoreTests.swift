import Foundation
import Security
import Testing

@testable import Dblore

@Suite("SSH known-host store")
@MainActor
struct SSHKnownHostStoreTests {
  private let stored = SSHKnownHost(
    algorithm: "ssh-ed25519", fingerprint: "SHA256:abc",
    addedAt: Date(timeIntervalSince1970: 1_000))

  @Test("No stored key is unknown")
  func unknown() {
    #expect(
      SSHKnownHostStoreFactory.evaluate(
        presented: (algorithm: "ssh-ed25519", fingerprint: "SHA256:abc"), stored: nil) == .unknown)
  }

  @Test("Same algorithm and fingerprint is trusted")
  func trusted() {
    #expect(
      SSHKnownHostStoreFactory.evaluate(
        presented: (algorithm: "ssh-ed25519", fingerprint: "SHA256:abc"), stored: stored)
        == .trusted)
  }

  @Test("A different fingerprint is changed")
  func changedFingerprint() {
    #expect(
      SSHKnownHostStoreFactory.evaluate(
        presented: (algorithm: "ssh-ed25519", fingerprint: "SHA256:xyz"), stored: stored)
        == .changed(stored: stored))
  }

  @Test("A different algorithm is changed")
  func changedAlgorithm() {
    #expect(
      SSHKnownHostStoreFactory.evaluate(
        presented: (algorithm: "ecdsa-sha2-nistp256", fingerprint: "SHA256:abc"), stored: stored)
        == .changed(stored: stored))
  }

  @Test("Trust, lookup, and remove round-trip by host and port")
  func trustLookupRemove() throws {
    let store = InMemorySSHKnownHostStore()
    #expect(
      try store.trust(
        host: "bastion", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:abc"))
    let found = try #require(try store.lookup(host: "bastion", port: 22))
    #expect(found.algorithm == "ssh-ed25519")
    #expect(found.fingerprint == "SHA256:abc")
    #expect(try store.lookup(host: "bastion", port: 2222) == nil)
    store.remove(host: "bastion", port: 22)
    #expect(try store.lookup(host: "bastion", port: 22) == nil)
  }

  @Test("trust never overwrites a different pin; only replacePin does")
  func trustRefusesOverwrite() throws {
    let store = InMemorySSHKnownHostStore()
    try store.trust(host: "bastion", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:abc")
    #expect(
      try store.trust(
        host: "bastion", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:abc"))
    #expect(
      try !store.trust(
        host: "bastion", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:xyz"))
    #expect(
      try !store.trust(
        host: "bastion", port: 22, algorithm: "ecdsa-sha2-nistp256", fingerprint: "SHA256:abc"))
    #expect(try store.lookup(host: "bastion", port: 22)?.fingerprint == "SHA256:abc")
    #expect(
      store.replacePin(
        host: "bastion", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:xyz"))
    #expect(try store.lookup(host: "bastion", port: 22)?.fingerprint == "SHA256:xyz")
  }

  @Test("add refuses an existing pin and keeps it")
  func addIsAddOnly() throws {
    let store = InMemorySSHKnownHostStore()
    let account = SSHKnownHostStoreFactory.account(host: "bastion", port: 22)
    #expect(store.add(stored, account: account))
    let other = SSHKnownHost(algorithm: "ssh-ed25519", fingerprint: "SHA256:xyz", addedAt: Date())
    #expect(!store.add(other, account: account))
    #expect(try store.load(account: account) == stored)
  }

  @Test("trust refuses when a pin appears between its lookup and its add")
  func trustLosesConcurrentFirstUse() throws {
    let store = RacingKnownHostStore()
    let account = SSHKnownHostStoreFactory.account(host: "bastion", port: 22)
    store.inner.add(stored, account: account)
    #expect(
      try !store.trust(
        host: "bastion", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:xyz"))
    #expect(try store.inner.load(account: account) == stored)
  }

  @Test("Keychain reads: not found is nil, other errors and bad data throw")
  func keychainDecodeFailsClosed() throws {
    #expect(try KeychainSSHKnownHostStore.decode(status: errSecItemNotFound, data: nil) == nil)
    #expect(throws: SSHKnownHostStoreError.self) {
      try KeychainSSHKnownHostStore.decode(status: errSecInteractionNotAllowed, data: nil)
    }
    #expect(throws: SSHKnownHostStoreError.self) {
      try KeychainSSHKnownHostStore.decode(status: errSecSuccess, data: nil)
    }
    #expect(throws: SSHKnownHostStoreError.self) {
      try KeychainSSHKnownHostStore.decode(status: errSecSuccess, data: Data("{".utf8))
    }
    let data = try JSONEncoder().encode(stored)
    #expect(try KeychainSSHKnownHostStore.decode(status: errSecSuccess, data: data) == stored)
  }

  @Test("Host names are case-insensitive")
  func hostCaseInsensitive() throws {
    let store = InMemorySSHKnownHostStore()
    try store.trust(
      host: "Bastion.Example", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:abc")
    #expect(try store.lookup(host: "bastion.example", port: 22)?.fingerprint == "SHA256:abc")
    #expect(
      SSHKnownHostStoreFactory.account(host: "BASTION", port: 22)
        == SSHKnownHostStoreFactory.account(host: "bastion", port: 22))
    #expect(SSHKnownHostStoreFactory.account(host: "bastion", port: 22).hasPrefix("v2|"))
  }

  @Test("The factory uses in-memory storage under the test host")
  func factoryUsesInMemoryUnderTestHost() {
    #expect(SSHKnownHostStoreFactory.makeDefault() is InMemorySSHKnownHostStore)
    #expect(KeychainSSHKnownHostStore.serviceName == "ace.thi.dblore.ssh-host-key")
  }
}

/// Hides the pin from the first load, as if another first-use added it right after that read.
private final class RacingKnownHostStore: SSHKnownHostStore, @unchecked Sendable {
  let inner = InMemorySSHKnownHostStore()
  private let lock = NSLock()
  private var hidden = true

  func load(account: String) throws -> SSHKnownHost? {
    let hide = lock.withLock {
      defer { hidden = false }
      return hidden
    }
    return hide ? nil : try inner.load(account: account)
  }

  func add(_ host: SSHKnownHost, account: String) -> Bool { inner.add(host, account: account) }
  func save(_ host: SSHKnownHost, account: String) -> Bool { inner.save(host, account: account) }
  func delete(account: String) { inner.delete(account: account) }
}
