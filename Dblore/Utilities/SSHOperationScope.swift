import Foundation

// The form's SSH secret for one operation (connect, Test Connection, save), mirroring
// `ClientCertificateStoreFactory.operationMaterial`. An unremembered connection keeps its secret
// only here, never in the store.

nonisolated extension SSHCredentialStoreFactory {
  struct ConnectionCredential: Sendable, Equatable {
    let account: String
    let credential: SSHStoredCredential
  }

  /// Cleared when the operation ends, so a task that inherited it cannot keep using it.
  final class ScopedSSHCredential: @unchecked Sendable {
    let account: String
    private let lock = NSLock()
    private var storage: SSHStoredCredential?

    init(account: String, credential: SSHStoredCredential) {
      self.account = account
      storage = credential
    }

    var credential: SSHStoredCredential? { lock.withLock { storage } }

    func clear() { lock.withLock { storage = nil } }
  }

  @TaskLocal static var operationCredential: ScopedSSHCredential?

  /// The scoped credential when it belongs to `config`'s account.
  static func currentCredential(for config: ConnectionConfig) -> ConnectionCredential? {
    guard let account = account(for: config), let scoped = operationCredential,
      scoped.account == account, let credential = scoped.credential
    else { return nil }
    return ConnectionCredential(account: account, credential: credential)
  }

  /// The scoped credential for `config`'s account, else the stored one. Nil without a tunnel.
  static func load(
    for config: ConnectionConfig, from store: any SSHCredentialStore = shared
  ) -> SSHStoredCredential? {
    if let current = currentCredential(for: config) { return current.credential }
    guard let account = account(for: config) else { return nil }
    return store.load(account: account)
  }

  /// Saves the scoped credential for a remembered tunneled connection. True when there is
  /// nothing to save.
  @discardableResult
  static func persistOperationCredential(
    for config: ConnectionConfig, to store: any SSHCredentialStore = shared
  ) -> Bool {
    guard config.rememberConnection, let current = currentCredential(for: config) else {
      return true
    }
    return store.save(current.credential, account: current.account)
  }

  /// Wraps `credential` for `config`'s account (nil without a credential or a tunnel).
  static func scoped(
    _ credential: SSHStoredCredential?, for config: ConnectionConfig
  ) -> ScopedSSHCredential? {
    guard let credential, let account = account(for: config) else { return nil }
    return ScopedSSHCredential(account: account, credential: credential)
  }
}
