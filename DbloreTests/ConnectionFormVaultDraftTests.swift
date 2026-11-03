// ConnectionFormVaultDraftTests.swift
// The connection form's Vault draft: a blocked row reads no stored secret until its unlock, the
// stored secret serves only its auth method and follows edited Vault settings (never to another
// address or CA), the "enter it again" note, the submitted config's Vault rules, and Test Vault
// (one lease from the draft's secret, revoked at once, or why not). Fake Vault client only.

import Foundation
import Testing

@testable import Dblore

/// Answers one lease per read and records the calls; never a live Vault.
nonisolated final class VaultFormFakeClient: VaultClient, @unchecked Sendable {
  enum Call: Equatable {
    case read(token: String)
    case login(roleID: String, secretID: String)
    case revoke(id: String)
    case revokeSelf(token: String)
  }

  private let lock = NSLock()
  private var recorded: [Call] = []
  private var leases = 0
  /// Thrown by every lease revoke (nil: revokes)
  let revokeError: VaultClientError?
  /// Thrown by every token revoke-self (nil: revokes)
  let revokeSelfError: VaultClientError?

  init(revokeError: VaultClientError? = nil, revokeSelfError: VaultClientError? = nil) {
    self.revokeError = revokeError
    self.revokeSelfError = revokeSelfError
  }

  var calls: [Call] { lock.withLock { recorded } }

  func readCredentials(token: String) async throws -> VaultLeasedCredentials {
    let number = lock.withLock {
      recorded.append(.read(token: token))
      leases += 1
      return leases
    }
    return VaultLeasedCredentials(
      lease: VaultLease(id: "lease-\(number)", duration: 3_600, renewable: true),
      username: "v-user-\(number)", password: "v-pass-\(number)")
  }

  func renewLease(id: String, increment: Int?, token: String) async throws -> VaultLease {
    VaultLease(id: id, duration: 3_600, renewable: true)
  }

  func revokeLease(id: String, token: String) async throws {
    lock.withLock { recorded.append(.revoke(id: id)) }
    if let revokeError { throw revokeError }
  }

  func appRoleLogin(roleID: String, secretID: String) async throws -> VaultAuth {
    lock.withLock { recorded.append(.login(roleID: roleID, secretID: secretID)) }
    return VaultAuth(clientToken: "login-token", duration: 3_600, renewable: true)
  }

  func lookupSelf(token: String) async throws -> VaultTokenInfo {
    VaultTokenInfo(ttl: 0, expireTime: nil, renewable: false, period: nil)
  }

  func renewSelf(increment: Int?, token: String) async throws -> VaultAuth {
    VaultAuth(clientToken: token, duration: 3_600, renewable: true)
  }

  func revokeSelf(token: String) async throws {
    lock.withLock { recorded.append(.revokeSelf(token: token)) }
    if let revokeSelfError { throw revokeSelfError }
  }
}

@Suite("Connection form Vault draft")
@MainActor
struct ConnectionFormVaultDraftTests {
  static func vaultConfig(
    host: String = "db.internal", auth: VaultSource.AuthMethod = .token
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      host: host, database: "app", username: "saved-user", password: "")
    config.vault = VaultSource(
      address: "https://vault.test:8200", mount: "database", role: "app-ro", authMethod: auth,
      caPEM: nil)
    return config
  }

  /// Counts reads of stored Vault secrets.
  private final class LoadCountingVaultStore: VaultSecretStore, @unchecked Sendable {
    let base = InMemoryVaultSecretStore()
    private let lock = NSLock()
    private var count = 0

    var loads: Int { lock.withLock { count } }

    func load(account: String) -> VaultStoredSecret? {
      lock.withLock { count += 1 }
      return base.load(account: account)
    }

    func save(_ secret: VaultStoredSecret, account: String) -> VaultSecretSave {
      base.save(secret, account: account)
    }

    func delete(account: String) { base.delete(account: account) }

    func isSessionOnly(account: String) -> Bool { false }
  }

  @Test("A blocked row's form reads no stored Vault secret until the unlock; after it, it does")
  func lockedRowReadsNoSecretUntilUnlock() {
    let store = LoadCountingVaultStore()
    let config = Self.vaultConfig()
    VaultCredentialStore.save(.token("saved-token"), for: config, to: store)
    let registry = LockRegistry()
    registry.setLockedConnections([LockIdentity(config)])

    var draft = VaultFormDraft(restoringFor: config, blocked: true)
    draft.apply(VaultFormDraft.storedLookup(for: config, store: store, registry: registry))
    #expect(store.loads == 0)
    #expect(draft.pending)
    #expect(draft.storedSecret == nil)
    #expect(draft.preparedSecret(for: .token) == nil)
    // Valid: the connect asks the unlock, then the lease reads the saved secret
    #expect(draft.isValid(for: config))

    #expect(registry.grant(LockIdentity.all(config), ifGeneration: registry.generation))
    var unlocked = VaultFormDraft(restoringFor: config, blocked: false)
    unlocked.apply(VaultFormDraft.storedLookup(for: config, store: store, registry: registry))
    #expect(store.loads == 1)
    #expect(unlocked.preparedSecret(for: .token) == .token("saved-token"))
  }

  @Test("The stored secret serves only its auth method; typed values win, AppRole fills gaps")
  func preparedSecret() {
    var draft = VaultFormDraft()
    draft.storedSecret = .token("saved")
    #expect(draft.preparedSecret(for: .token) == .token("saved"))
    #expect(draft.preparedSecret(for: .appRole) == nil)
    draft.token = " typed\n"
    #expect(draft.preparedSecret(for: .token) == .token("typed"))
    #expect(draft.preparedSecret(for: nil) == nil)

    var appRole = VaultFormDraft()
    appRole.storedSecret = .appRole(roleID: "role", secretID: "old-secret")
    appRole.secretID = "new-secret"
    #expect(
      appRole.preparedSecret(for: .appRole) == .appRole(roleID: "role", secretID: "new-secret"))
  }

  @Test("Edited Vault settings ask for the secret again only when the draft holds none")
  func secretAgainNote() {
    let config = Self.vaultConfig()
    var edited = config
    edited.vault?.role = "app-rw"

    // Restored: the stored secret goes with the edit
    var restored = VaultFormDraft(restoringFor: config, blocked: false)
    restored.apply(.found(.token("saved")))
    #expect(!restored.needsSecretAgain(for: edited))
    #expect(restored.isValid(for: edited))

    // Blocked: the saved secret is for the old settings
    var blocked = VaultFormDraft(restoringFor: config, blocked: true)
    blocked.apply(nil)
    #expect(!blocked.needsSecretAgain(for: config))
    #expect(blocked.needsSecretAgain(for: edited))
    #expect(!blocked.isValid(for: edited))
    // The trimmed address text decides, as for the stored secret: case or a trailing slash the
    // destination ignores still asks for the secret again
    var trimmedAway = config
    trimmedAway.vault?.address = " https://vault.test:8200\n"
    #expect(blocked.waitsForUnlock(trimmedAway))
    var recased = config
    recased.vault?.address = "https://VAULT.test:8200/"
    #expect(
      VaultCredentialStore.destination(for: recased)
        == VaultCredentialStore.destination(for: config))
    #expect(!blocked.waitsForUnlock(recased))
    #expect(blocked.needsSecretAgain(for: recased))
    #expect(!blocked.isValid(for: recased))
    blocked.token = "typed"
    #expect(!blocked.needsSecretAgain(for: edited))

    // Another address or CA: the stored secret is not sent there, it is typed again
    var otherAddress = config
    otherAddress.vault?.address = "https://vault-other.test:8200"
    var otherCA = config
    otherCA.vault?.caPEM = "-----BEGIN CERTIFICATE-----"
    for target in [otherAddress, otherCA] {
      #expect(restored.preparedSecret(for: target) == nil)
      #expect(restored.needsSecretAgain(for: target))
      #expect(!restored.isValid(for: target))
    }
    var typed = restored
    typed.token = "typed"
    #expect(typed.preparedSecret(for: otherAddress) == .token("typed"))
    var spaced = config
    spaced.vault?.address = " https://vault.test:8200 "
    #expect(restored.preparedSecret(for: spaced) == .token("saved"))

    // Saved for other settings already
    var elsewhere = VaultFormDraft(restoringFor: config, blocked: false)
    elsewhere.apply(.destinationChanged)
    #expect(elsewhere.needsSecretAgain(for: config))
  }

  @Test("A stored secret the Keychain cannot read keeps the draft's secret and shows the notice")
  func unreadableStoredSecret() {
    var draft = VaultFormDraft(restoringFor: Self.vaultConfig(), blocked: false)
    draft.storedSecret = .token("kept")
    draft.apply(.unreadable)
    #expect(draft.storedSecret == .token("kept"))
    #expect(draft.storeUnreadable)
    // Not "waits for the unlock" nor "saved for other settings"
    #expect(!draft.pending)
    #expect(!draft.storedElsewhere)
  }

  @Test("A submitted Vault config is remembered, with no password or password command")
  func vaultRules() {
    var config = Self.vaultConfig()
    config.rememberConnection = false
    config.password = "stale"
    config.passwordCommandScript = "pw.sh"
    config.vault?.address = " https://vault.test:8200 "
    let submitted = ConnectionFormContent.withVaultRules(config)
    #expect(submitted.rememberConnection)
    #expect(submitted.password.isEmpty)
    #expect(submitted.passwordCommandScript == nil)
    #expect(submitted.vault?.address == "https://vault.test:8200")

    var plain = config
    plain.vault = nil
    #expect(ConnectionFormContent.withVaultRules(plain) == plain)
  }

  @Test(
    "Ask on connect clears Vault and the password command and blanks the password; another source clears it"
  )
  func askOnConnectSourceRules() {
    typealias Form = ConnectionFormContent
    var config = ConnectionConfig(
      host: "db.test", port: 5432, database: "app", username: "u", password: "saved")
    config.passwordCommandScript = "pw.sh"
    let command = PasswordSourceDraft(
      config: config, passwordBeforeVault: nil, choosesPasswordCommand: true)
    #expect(command.source == .command)

    let ask = Form.selecting(.ask, in: command)
    #expect(ask.source == .ask)
    #expect(ask.config.askPasswordOnConnect)
    #expect(ask.config.passwordCommandScript == nil)
    #expect(!ask.choosesPasswordCommand)
    // Blanked, so Test and Connect ask; kept for a switch back
    #expect(ask.config.password.isEmpty)
    #expect(ask.passwordBeforeVault == "saved")

    let saved = Form.selecting(.saved, in: ask)
    #expect(saved.source == .saved)
    #expect(!saved.config.askPasswordOnConnect)
    #expect(saved.config.password == "saved")
    #expect(saved.passwordBeforeVault == nil)

    // Vault, then Ask on connect, then Vault again: the password Vault blanked is still kept
    let askFromVault = Form.selecting(.ask, in: Form.selecting(.vault, in: saved))
    #expect(askFromVault.config.vault == nil)
    #expect(askFromVault.config.askPasswordOnConnect)
    #expect(askFromVault.passwordBeforeVault == "saved")
    let vault = Form.selecting(.vault, in: askFromVault)
    #expect(vault.source == .vault)
    #expect(!vault.config.askPasswordOnConnect)
    #expect(Form.selecting(.saved, in: vault).config.password == "saved")

    // A password that still reached an Ask on connect config (a pasted URI) is never submitted
    var pasted = ask.config
    pasted.password = "from-uri"
    #expect(Form.withVaultRules(pasted).password.isEmpty)
  }

  @Test("Test Vault leases with the draft's secret alone, reports user and TTL, and revokes")
  func testVaultUsesDraftAndRevokes() async throws {
    let client = VaultFormFakeClient()
    let store = InMemoryVaultSecretStore()
    let leasing = VaultLeasing(makeClient: { _ in client }, store: store)
    let config = Self.vaultConfig()

    let result = try await VaultTestProbe.run(
      config: config, secret: .token("typed-token"), leasing: leasing)
    #expect(result == VaultTestProbe.Result(username: "v-user-1", ttl: 3_600))
    #expect(client.calls == [.read(token: "typed-token"), .revoke(id: "lease-1")])
    #expect(VaultCredentialStore.lookup(for: config, from: store) == .missing)
    let message = VaultTestProbe.message(for: result)
    #expect(message.contains("v-user-1"))
    #expect(!message.contains("v-pass"))
  }

  @Test("Test Vault says the lease is not revoked when Vault refuses the revoke")
  func testVaultRevokeRefused() async throws {
    let client = VaultFormFakeClient(
      revokeError: .http(status: 403, errors: ["permission denied"]))
    let leasing = VaultLeasing(makeClient: { _ in client }, store: InMemoryVaultSecretStore())
    let result = try await VaultTestProbe.run(
      config: Self.vaultConfig(), secret: .token("typed-token"), leasing: leasing)
    #expect(client.calls == [.read(token: "typed-token"), .revoke(id: "lease-1")])
    let message = VaultTestProbe.message(for: result)
    #expect(
      message
        == "Vault works: user v-user-1, lease \(Self.hourText); the lease could not be revoked: "
        + "the token's policy does not allow update on sys/leases/revoke — it ends at its TTL.")

    let failing = VaultFormFakeClient(
      revokeError: .http(status: 500, errors: ["lease revocation failed"]))
    let failed = try await VaultTestProbe.run(
      config: Self.vaultConfig(), secret: .token("typed-token"),
      leasing: VaultLeasing(makeClient: { _ in failing }, store: InMemoryVaultSecretStore()))
    #expect(failed.revokeFailure == "Vault answered HTTP 500: lease revocation failed")
  }

  /// How `VaultTestProbe.message` writes a one-hour lease
  private static let hourText = Duration.seconds(3_600).formatted(
    .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))

  @Test("Test Vault with AppRole revokes the lease, then its login token")
  func testVaultAppRole() async throws {
    let client = VaultFormFakeClient()
    let leasing = VaultLeasing(makeClient: { _ in client }, store: InMemoryVaultSecretStore())
    _ = try await VaultTestProbe.run(
      config: Self.vaultConfig(auth: .appRole), secret: .appRole(roleID: "r", secretID: "s"),
      leasing: leasing)
    #expect(
      client.calls == [
        .login(roleID: "r", secretID: "s"), .read(token: "login-token"),
        .revoke(id: "lease-1"), .revokeSelf(token: "login-token"),
      ])
  }

  @Test("Test Vault with AppRole counts a refused lease revoke as revoked once the token is")
  func testVaultAppRoleRevokeRefused() async throws {
    let forbidden = VaultClientError.http(status: 403, errors: ["permission denied"])
    let serverError = VaultClientError.http(status: 500, errors: ["lease revocation failed"])
    let config = Self.vaultConfig(auth: .appRole)
    func run(_ client: VaultFormFakeClient) async throws -> VaultTestProbe.Result {
      let result = try await VaultTestProbe.run(
        config: config, secret: .appRole(roleID: "r", secretID: "s"),
        leasing: VaultLeasing(makeClient: { _ in client }, store: InMemoryVaultSecretStore()))
      #expect(
        client.calls.suffix(2) == [.revoke(id: "lease-1"), .revokeSelf(token: "login-token")])
      return result
    }

    // 403, then the login token is revoked: its leases go with it
    let refused = try await run(VaultFormFakeClient(revokeError: forbidden))
    #expect(refused.revokeFailure == nil)
    #expect(VaultTestProbe.message(for: refused).hasSuffix(", revoked."))

    // Another failure stays one, even with the token revoked
    let failed = try await run(VaultFormFakeClient(revokeError: serverError))
    #expect(failed.revokeFailure == "Vault answered HTTP 500: lease revocation failed")
    #expect(VaultTestProbe.message(for: failed).contains("the lease could not be revoked"))

    // 403 and the token's revoke fails too: the lease outlives the test
    let kept = try await run(
      VaultFormFakeClient(revokeError: forbidden, revokeSelfError: serverError))
    #expect(kept.revokeFailure == VaultTestProbe.revokeReason(forbidden))
  }
}
