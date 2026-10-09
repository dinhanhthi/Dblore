import Foundation
import Testing

@testable import Dblore

@Suite("Connection form SSH draft")
@MainActor
struct ConnectionFormSSHDraftTests {
  private static let ed25519Fingerprint = "SHA256:9ulJ9dylfq2c4xbA1GreqvEcDo+Qj6YNmzKiEP+Ed3Y"

  private static func tunneledConfig(
    host: String = "db.internal", username: String = "ada", bastionHost: String = "bastion.example",
    bastionPort: Int = 22, bastionUser: String = "jump",
    authMethod: SSHTunnelConfig.AuthMethod = .password
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      host: host, port: 5432, database: "app", username: username, rememberConnection: true,
      name: "Tunneled")
    config.sshTunnel = SSHTunnelConfig(
      host: bastionHost, port: bastionPort, username: bastionUser, authMethod: authMethod,
      keyAlgorithm: authMethod == .privateKey ? "ssh-ed25519" : nil,
      keyFingerprint: authMethod == .privateKey ? "SHA256:stored" : nil)
    return config
  }

  private static func enabledDraft() -> SSHFormDraft {
    var draft = SSHFormDraft()
    draft.enabled = true
    draft.host = "bastion.example"
    draft.username = "jump"
    return draft
  }

  private static func importKey(
    _ draft: inout SSHFormDraft, _ pem: String, passphrase: String? = nil
  ) async {
    let data = Data(pem.utf8)
    let token = draft.beginKeyImport()
    let result = await SSHFormDraft.parseKey(data: data, passphrase: passphrase)
    draft.finishKeyImport(result, data: data, token: token)
  }

  // MARK: Config

  @Test("SSH off prepares no tunnel and no credential, and does not block the form")
  func disabledDraft() {
    var draft = SSHFormDraft()
    draft.password = "typed"
    #expect(draft.preparedConfig == nil)
    #expect(draft.enteredCredential == nil)
    #expect(draft.isValid(storedMethod: nil))
    #expect(draft.port == 22)
  }

  @Test("A saved tunnel round-trips through the draft")
  func savedTunnelRoundTrips() {
    let config = Self.tunneledConfig(authMethod: .privateKey)
    let draft = SSHFormDraft(from: config)
    #expect(draft.enabled)
    #expect(draft.preparedConfig == config.sshTunnel)
    #expect(draft.password.isEmpty)
    #expect(SSHFormDraft(from: ConnectionConfig()) == SSHFormDraft())
  }

  @Test("SSH is offered for PostgreSQL only")
  func sshEngines() {
    #expect(SSHFormDraft.supportsSSH(.postgresql))
    #expect(!SSHFormDraft.supportsSSH(.sqlite))
  }

  // MARK: Validation

  @Test("SSH on requires host, user and a secret")
  func validationRequiresHostUserSecret() {
    var draft = Self.enabledDraft()
    #expect(!draft.isValid(storedMethod: nil))
    draft.password = "pw"
    #expect(draft.isValid(storedMethod: nil))
    draft.host = "  "
    #expect(!draft.isValid(storedMethod: nil))
    draft.host = "bastion.example"
    draft.username = ""
    #expect(!draft.isValid(storedMethod: nil))
    draft.username = "jump"
    draft.port = 0
    #expect(!draft.isValid(storedMethod: nil))
  }

  @Test("A stored credential of the selected method counts; another method does not")
  func storedCredentialCounts() {
    var draft = SSHFormDraft(from: Self.tunneledConfig(authMethod: .privateKey))
    #expect(draft.isValid(storedMethod: .privateKey))
    #expect(!draft.isValid(storedMethod: .password))
    draft.authMethod = .password
    #expect(draft.isValid(storedMethod: .password))
    #expect(!draft.isValid(storedMethod: .privateKey))
  }

  @Test("Removing the stored key leaves no usable credential")
  func removeStoredKey() {
    var draft = SSHFormDraft(from: Self.tunneledConfig(authMethod: .privateKey))
    draft.removeKey()
    #expect(!draft.isValid(storedMethod: .privateKey))
    #expect(draft.preparedConfig?.keyFingerprint == nil)
    #expect(draft.preparedConfig?.keyAlgorithm == nil)
  }

  // MARK: Key import

  @Test("An imported key keeps only the decrypted key and its fingerprint")
  func importUnencryptedKey() async throws {
    var draft = Self.enabledDraft()
    await Self.importKey(&draft, Fixtures.ed25519)
    let key = try #require(draft.importedKey)
    #expect(key.algorithm == "ssh-ed25519")
    #expect(key.fingerprint == Self.ed25519Fingerprint)
    #expect(draft.authMethod == .privateKey)
    #expect(draft.keyError == nil)
    #expect(draft.pendingKeyData == nil)
    #expect(!draft.isImportingKey)
    #expect(draft.preparedConfig?.keyFingerprint == Self.ed25519Fingerprint)
    #expect(draft.preparedConfig?.keyAlgorithm == "ssh-ed25519")
    #expect(
      draft.enteredCredential == .privateKey(keychainRepresentation: key.keychainRepresentation))
    #expect(draft.isValid(storedMethod: nil))
    let restored = try SSHPrivateKeyParser.restore(from: key.keychainRepresentation)
    #expect(restored.fingerprint == Self.ed25519Fingerprint)
  }

  @Test("An encrypted key asks for its passphrase, rejects a wrong one, then imports")
  func importEncryptedKey() async throws {
    var draft = Self.enabledDraft()
    await Self.importKey(&draft, Fixtures.ed25519Encrypted)
    #expect(draft.importedKey == nil)
    #expect(draft.keyError == SSHPrivateKeyError.passphraseRequired.errorDescription)
    #expect(draft.needsPassphrase)

    draft.passphrase = "not-the-passphrase"
    let pending = try #require(draft.pendingKeyData)
    var token = draft.beginKeyImport()
    draft.finishKeyImport(
      await SSHFormDraft.parseKey(data: pending, passphrase: draft.passphrase), data: pending,
      token: token)
    #expect(draft.keyError == SSHPrivateKeyError.wrongPassphrase.errorDescription)
    #expect(draft.passphrase.isEmpty)
    #expect(draft.needsPassphrase)

    draft.passphrase = "dblore-test-pass"
    token = draft.beginKeyImport()
    draft.finishKeyImport(
      await SSHFormDraft.parseKey(data: pending, passphrase: draft.passphrase), data: pending,
      token: token)
    #expect(draft.importedKey?.algorithm == "ssh-ed25519")
    #expect(draft.keyError == nil)
    #expect(draft.passphrase.isEmpty)
    #expect(draft.pendingKeyData == nil)
  }

  @Test("An RSA key shows the exact not-supported message")
  func importRSAKey() async {
    var draft = Self.enabledDraft()
    await Self.importKey(&draft, Fixtures.rsa)
    #expect(draft.importedKey == nil)
    #expect(
      draft.keyError
        == "RSA keys are not supported; use an ed25519 or ECDSA key (ssh-keygen -t ed25519)")
    #expect(draft.keyError == SSHPrivateKeyError.rsaNotSupported.errorDescription)
    #expect(!draft.needsPassphrase)
  }

  @Test("A slower import superseded by Remove is ignored")
  func staleImportIgnored() async {
    var draft = Self.enabledDraft()
    let data = Data(Fixtures.ed25519.utf8)
    let token = draft.beginKeyImport()
    #expect(!draft.isValid(storedMethod: nil))
    draft.removeKey()
    draft.finishKeyImport(
      await SSHFormDraft.parseKey(data: data, passphrase: nil), data: data, token: token)
    #expect(draft.importedKey == nil)
  }

  @Test("Closing the form drops typed and imported secrets")
  func clearSecrets() async {
    var draft = Self.enabledDraft()
    draft.password = "pw"
    await Self.importKey(&draft, Fixtures.ed25519)
    draft.clearSecrets()
    #expect(draft.password.isEmpty)
    #expect(draft.importedKey == nil)
    #expect(draft.enteredCredential == nil)
  }

  // MARK: Credential on save

  @Test("A typed secret is saved; an untouched one on the same identity is left as is")
  func credentialSameIdentity() {
    let store = InMemorySSHCredentialStore()
    let config = Self.tunneledConfig()
    store.save(.password("old"), account: SSHCredentialStoreFactory.account(for: config)!)
    var draft = SSHFormDraft(from: config)
    #expect(draft.preparedCredential(original: config, new: config, store: store) == nil)
    draft.password = "new"
    #expect(
      draft.preparedCredential(original: config, new: config, store: store) == .password("new"))
    draft.enabled = false
    #expect(draft.preparedCredential(original: config, new: config, store: store) == nil)
  }

  @Test(
    "A changed DB identity re-supplies the stored credential",
    arguments: ["dbHost", "dbUser"])
  func credentialMovesWithIdentity(change: String) {
    let store = InMemorySSHCredentialStore()
    let original = Self.tunneledConfig(authMethod: .privateKey)
    let secret = SSHStoredCredential.privateKey(keychainRepresentation: Data([1, 2, 3]))
    store.save(secret, account: SSHCredentialStoreFactory.account(for: original)!)
    var edited =
      switch change {
      case "dbHost": Self.tunneledConfig(host: "db2.internal", authMethod: .privateKey)
      default: Self.tunneledConfig(username: "grace", authMethod: .privateKey)
      }
    var draft = SSHFormDraft(from: edited)
    edited.sshTunnel = draft.preparedConfig
    #expect(draft.preparedCredential(original: original, new: edited, store: store) == secret)
    #expect(draft.isValid(storedMethod: draft.usableStoredMethod(.privateKey, original: original)))
    // A stored key does not serve password auth.
    draft.authMethod = .password
    edited.sshTunnel = draft.preparedConfig
    #expect(draft.preparedCredential(original: original, new: edited, store: store) == nil)
  }

  @Test(
    "A changed bastion never gets the old bastion's secret; the form waits for a new one",
    arguments: ["bastionHost", "bastionPort", "bastionUser"])
  func credentialStaysWithBastion(change: String) {
    let store = InMemorySSHCredentialStore()
    let original = Self.tunneledConfig()
    let account = SSHCredentialStoreFactory.account(for: original)!
    store.save(.password("old-bastion"), account: account)
    let held = SSHCredentialStoreFactory.ConnectionCredential(
      account: account, credential: .password("held-old-bastion"))
    var edited =
      switch change {
      case "bastionHost": Self.tunneledConfig(bastionHost: "other.example")
      case "bastionPort": Self.tunneledConfig(bastionPort: 2222)
      default: Self.tunneledConfig(bastionUser: "jump2")
      }
    var draft = SSHFormDraft(from: edited)
    edited.sshTunnel = draft.preparedConfig

    #expect(!draft.bastionMatches(original))
    #expect(draft.preparedCredential(original: original, new: edited, store: store) == nil)
    #expect(
      draft.preparedCredential(original: original, new: edited, store: store, held: held) == nil)
    let usable = draft.usableStoredMethod(.password, original: original)
    #expect(usable == nil)
    #expect(!draft.isValid(storedMethod: usable))
    #expect(draft.needsSecretForNewBastion(storedMethod: .password, original: original))

    draft.password = "new-bastion"
    #expect(draft.isValid(storedMethod: usable))
    #expect(!draft.needsSecretForNewBastion(storedMethod: .password, original: original))
    #expect(
      draft.preparedCredential(original: original, new: edited, store: store, held: held)
        == .password("new-bastion"))
  }

  @Test("A held remember-off secret is re-supplied for the same bastion, even on a DB edit")
  func heldCredentialSameBastion() {
    let store = InMemorySSHCredentialStore()
    let original = Self.tunneledConfig()
    let held = SSHCredentialStoreFactory.ConnectionCredential(
      account: SSHCredentialStoreFactory.account(for: original)!, credential: .password("held"))
    let draft = SSHFormDraft(from: original)
    #expect(
      draft.preparedCredential(original: original, new: original, store: store, held: held)
        == .password("held"))
    var edited = Self.tunneledConfig(host: "db2.internal")
    edited.sshTunnel = draft.preparedConfig
    #expect(
      draft.preparedCredential(original: original, new: edited, store: store, held: held)
        == .password("held"))
    // Another connection's held secret is never used.
    let other = SSHCredentialStoreFactory.ConnectionCredential(
      account: "other", credential: .password("other"))
    #expect(
      draft.preparedCredential(original: original, new: original, store: store, held: other)
        == nil)
  }

  @Test("The stored method is read from the original account")
  func storedMethodLookup() {
    let store = InMemorySSHCredentialStore()
    let config = Self.tunneledConfig()
    #expect(SSHFormDraft.storedMethod(for: config, store: store) == nil)
    store.save(.password("pw"), account: SSHCredentialStoreFactory.account(for: config)!)
    #expect(SSHFormDraft.storedMethod(for: config, store: store) == .password)
    #expect(SSHFormDraft.storedMethod(for: nil, store: store) == nil)
    #expect(SSHFormDraft.storedMethod(for: ConnectionConfig(), store: store) == nil)
  }

  @Test("Editing the DB host keeps the SSH credential after the old account is pruned")
  func replaceMovesCredential() throws {
    let suiteName = "ace.thi.Dblore.tests.ssh-draft.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let passwords = RecordingConnectionPasswordStore()
    let credentials = InMemorySSHCredentialStore()
    let original = Self.tunneledConfig()
    #expect(
      SessionManager.saveConnection(
        original, defaults: defaults, passwords: passwords, sshCredentials: credentials,
        sshCredential: .password("ssh-secret")))
    let id = try #require(
      SessionManager.loadHistory(defaults: defaults, passwords: passwords).first?.id)

    var edited = Self.tunneledConfig(host: "db2.internal")
    let draft = SSHFormDraft(from: edited)
    edited.sshTunnel = draft.preparedConfig
    let credential = draft.preparedCredential(original: original, new: edited, store: credentials)
    #expect(
      SessionManager.replaceConnection(
        id: id, with: edited, defaults: defaults, passwords: passwords,
        sshCredentials: credentials, sshCredential: credential))

    #expect(
      credentials.load(account: SSHCredentialStoreFactory.account(for: edited)!)
        == .password("ssh-secret"))
    #expect(credentials.load(account: SSHCredentialStoreFactory.account(for: original)!) == nil)
  }

  @Test("Loading a Recent row, changing the engine or blanking the form reloads the SSH draft")
  func resetsOnOtherConnection() {
    #expect(
      ConnectionFormContent.resetsSSHDraft(
        isHistoryLoad: true, engineChanged: false, isBlankForm: false))
    #expect(
      ConnectionFormContent.resetsSSHDraft(
        isHistoryLoad: false, engineChanged: true, isBlankForm: false))
    #expect(
      ConnectionFormContent.resetsSSHDraft(
        isHistoryLoad: false, engineChanged: false, isBlankForm: true))
  }

  @Test("Editing the DB target keeps the SSH draft so the credential can move on save")
  func keepsOnTargetEdit() {
    #expect(
      !ConnectionFormContent.resetsSSHDraft(
        isHistoryLoad: false, engineChanged: false, isBlankForm: false))
  }

  @Test(
    "Key import reads only regular files (a FIFO would block the read)", .timeLimit(.minutes(1)))
  func keyImportRejectsNonRegularFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssh-key-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: (any Error).self) { try ConnectionFormContent.readSSHKeyFile(at: directory) }
    let fifo = directory.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: (any Error).self) { try ConnectionFormContent.readSSHKeyFile(at: fifo) }

    let file = directory.appendingPathComponent("id_ed25519")
    try Data(Fixtures.ed25519.utf8).write(to: file)
    #expect(try ConnectionFormContent.readSSHKeyFile(at: file) == Data(Fixtures.ed25519.utf8))
  }
}
