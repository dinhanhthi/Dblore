//
//  WorkspaceManager+MongoDatabase.swift
//  Dblore
//
//  Switching the database of a MongoDB workspace: a reconnect to the same server with another
//  `database` and the `mongoHomeDatabase` pin, so the Keychain identity and the default
//  authSource stay those of the saved connection. The recent list, its Keychain items and the
//  MCP entries (built from saved entries) are never touched; the .sqlws keeps the chosen database.
//

import Foundation

extension WorkspaceManager {
  /// `config` reading `name`: every field copied, the home database pinned; back on the home
  /// database (a blank one reads the session's default) the pin is cleared, so the config is the
  /// saved one again.
  static func switchedMongoConfig(_ config: ConnectionConfig, to name: String) -> ConnectionConfig {
    var switched = config
    let home = config.identityDatabase
    if name == home || name == (home.isEmpty ? MongoSession.defaultDatabase : home) {
      (switched.database, switched.mongoHomeDatabase) = (home, nil)
    } else {
      (switched.database, switched.mongoHomeDatabase) = (name, home)
    }
    return switched
  }

  /// The database a MongoDB config reads (the session's default when blank). Data viewer tabs
  /// carry it as their schema.
  static func mongoDatabaseName(of config: ConnectionConfig) -> String {
    config.database.isEmpty ? MongoSession.defaultDatabase : config.database
  }

  /// Reconnect to `name` on the same MongoDB server. Returns why it was refused or failed, nil
  /// once connected. Data viewer tabs of the old database close first (pinned ones too: they
  /// would read the same collection names in the new database); query tabs stay and run against
  /// the new one. The connect's epoch bump refuses in-flight writes of the old database.
  func switchMongoDatabase(to name: String) async -> String? {
    guard let current = workspace.connectionConfig, current.databaseType == .mongodb else {
      return "Only a MongoDB connection can switch databases"
    }
    guard connectionState.isConnected else { return "Connect first" }
    // admin, local and config can be read: only the character and length rules apply (names are
    // case-sensitive: "Admin" is not the server's database)
    if !MongoDatabaseName.reserved.contains(name),
      let problem = MongoDatabaseName.validate(name)
    {
      return problem
    }
    let old = Self.mongoDatabaseName(of: current)
    guard name != old else { return "The connection already reads \(name)" }
    guard !viewModels.values.contains(where: \.hasPendingStagedChanges) else {
      return "Apply or discard the staged changes first"
    }
    guard pendingTransaction.isIdle else {
      return NotebookViewModel.transactionPendingElsewhereMessage
    }

    for id in tabs.map(\.id) where viewModels[id]?.dataViewer?.schema == old {
      closeTabImmediately(id: id)
    }
    // A connection that is not remembered keeps its secrets in memory only (as Reconnect does)
    let scoped = activeUnrememberedCertificate.map {
      ClientCertificateStoreFactory.ScopedMaterial(account: $0.account, material: $0.material)
    }
    let scopedSSH = activeUnrememberedSSHCredential.map {
      SSHCredentialStoreFactory.ScopedSSHCredential(
        account: $0.account, credential: $0.credential)
    }
    defer {
      scoped?.clear()
      scopedSSH?.clear()
    }
    do {
      try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
        try await SSHCredentialStoreFactory.$operationCredential.withValue(scopedSSH) {
          try await connectWithoutUnlockCheck(
            config: Self.switchedMongoConfig(current, to: name), savesConnection: false)
        }
      }
    } catch {
      return SSHHostKeyTrustCoordinator.shared.report(error)
    }
    return nil
  }
}
