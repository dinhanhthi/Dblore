import Foundation
import Testing

@testable import Dblore

@Suite("SSH credential store")
@MainActor
struct SSHCredentialStoreTests {
  private func account(
    type: DatabaseType = .postgresql, host: String = "db", port: Int = 5432,
    database: String = "app", username: String = "ada",
    sshHost: String = "bastion", sshPort: Int = 22, sshUsername: String = "ops"
  ) -> String {
    SSHCredentialStoreFactory.account(
      databaseType: type, host: host, port: port, database: database, username: username,
      sshHost: sshHost, sshPort: sshPort, sshUsername: sshUsername)
  }

  @Test("A password credential round-trips")
  func passwordRoundTrip() {
    let store = InMemorySSHCredentialStore()
    #expect(store.save(.password("s3cret"), account: account()))
    #expect(store.load(account: account()) == .password("s3cret"))
  }

  @Test("A private key credential round-trips")
  func privateKeyRoundTrip() {
    let store = InMemorySSHCredentialStore()
    let key = Data([0x01, 0x02, 0xFF])
    #expect(store.save(.privateKey(keychainRepresentation: key), account: account()))
    #expect(store.load(account: account()) == .privateKey(keychainRepresentation: key))
  }

  @Test("Delete removes the credential")
  func deleteRemoves() {
    let store = InMemorySSHCredentialStore()
    store.save(.password("s3cret"), account: account())
    store.delete(account: account())
    #expect(store.load(account: account()) == nil)
  }

  @Test("Accounts differing only in engine or bastion do not collide")
  func accountSeparatesEngineAndBastion() {
    let base = account()
    #expect(base != account(type: .sqlite))
    #expect(base != account(sshHost: "bastion2"))
    #expect(base != account(sshPort: 2222))
    #expect(base != account(sshUsername: "root"))
    #expect(base.hasPrefix("v2|"))
  }

  @Test("Separators inside parts cannot make two accounts equal")
  func accountSeparatorsAreUnambiguous() {
    #expect(account(database: "a:b", username: "c") != account(database: "a", username: "b:c"))
    #expect(account(database: "a|b", username: "c") != account(database: "a", username: "b|c"))
    #expect(account(sshHost: "h|1", sshUsername: "u") != account(sshHost: "h", sshUsername: "1|u"))
  }

  @Test("Stored key JSON carries no passphrase field")
  func keyJSONHasNoPassphrase() throws {
    let data = try JSONEncoder().encode(
      SSHStoredCredential.privateKey(keychainRepresentation: Data([0x0A])))
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.lowercased().contains("passphrase"))
    #expect(
      try JSONDecoder().decode(SSHStoredCredential.self, from: data)
        == .privateKey(keychainRepresentation: Data([0x0A])))
  }

  private func tunneledConfig(
    sshHost: String = "bastion", rememberConnection: Bool = true
  ) -> ConnectionConfig {
    ConnectionConfig(
      host: "db", port: 5432, database: "app", username: "ada",
      sshTunnel: SSHTunnelConfig(host: sshHost, username: "ops"),
      rememberConnection: rememberConnection)
  }

  @Test("A scoped credential shadows the store only for its account and only until cleared")
  func scopedCredentialMatchesAccount() throws {
    let store = InMemorySSHCredentialStore()
    let config = tunneledConfig()
    let other = tunneledConfig(sshHost: "bastion2")
    let account = try #require(SSHCredentialStoreFactory.account(for: config))
    let otherAccount = try #require(SSHCredentialStoreFactory.account(for: other))
    store.save(.password("stored"), account: account)
    store.save(.password("other-stored"), account: otherAccount)
    let scoped = SSHCredentialStoreFactory.ScopedSSHCredential(
      account: account, credential: .password("scoped"))
    SSHCredentialStoreFactory.$operationCredential.withValue(scoped) {
      #expect(SSHCredentialStoreFactory.load(for: config, from: store) == .password("scoped"))
      #expect(
        SSHCredentialStoreFactory.currentCredential(for: config)
          == .init(account: account, credential: .password("scoped")))
      #expect(
        SSHCredentialStoreFactory.load(for: other, from: store) == .password("other-stored"))
      #expect(SSHCredentialStoreFactory.currentCredential(for: other) == nil)
      var direct = config
      direct.sshTunnel = nil
      #expect(SSHCredentialStoreFactory.load(for: direct, from: store) == nil)
      scoped.clear()
      #expect(SSHCredentialStoreFactory.load(for: config, from: store) == .password("stored"))
    }
    #expect(SSHCredentialStoreFactory.load(for: config, from: store) == .password("stored"))
  }

  @Test("A scoped credential is persisted only for a remembered tunneled connection")
  func persistOperationCredentialOnlyWhenRemembered() throws {
    let store = InMemorySSHCredentialStore()
    let config = tunneledConfig(rememberConnection: false)
    let account = try #require(SSHCredentialStoreFactory.account(for: config))
    let scoped = SSHCredentialStoreFactory.ScopedSSHCredential(
      account: account, credential: .password("scoped"))
    SSHCredentialStoreFactory.$operationCredential.withValue(scoped) {
      #expect(SSHCredentialStoreFactory.persistOperationCredential(for: config, to: store))
      #expect(store.load(account: account) == nil)
      var remembered = config
      remembered.rememberConnection = true
      #expect(SSHCredentialStoreFactory.persistOperationCredential(for: remembered, to: store))
    }
    #expect(store.load(account: account) == .password("scoped"))
  }

  @Test("The factory uses in-memory storage under the test host")
  func factoryUsesInMemoryUnderTestHost() {
    #expect(SSHCredentialStoreFactory.makeDefault() is InMemorySSHCredentialStore)
    #expect(KeychainSSHCredentialStore.serviceName == "ace.thi.dblore.ssh-credential")
  }
}
