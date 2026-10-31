// DatabaseConnectionManager+CopyObjects.swift
// The writable connection Copy Objects writes into: a saved PostgreSQL, MySQL / MariaDB or SQLite
// row, opened on its own single-use manager that the caller closes after the copy (no pool). A
// locked row is refused before any Keychain read; Read-only and Schema-only rows, DuckDB and
// MongoDB before connecting. The manager connects with a copy of the row whose Protected mode is
// off (protection level, Safe Mode and commit style unchanged), and every run call passes
// `CopyObjectsTarget.policy`, so the copy commits on its own transaction instead of waiting in a
// Protected mode one that closing the manager would roll back.

import Foundation

/// Why a saved connection cannot be a Copy Objects target
nonisolated enum CopyObjectsTargetError: Error, Equatable, LocalizedError {
  case unsupportedEngine(String)
  case readOnly
  case schemaOnly

  var errorDescription: String? {
    switch self {
    case .unsupportedEngine(let engine): "\(engine) cannot be a Copy Objects target."
    case .readOnly: "The target connection is read-only."
    case .schemaOnly: "The target connection blocks schema changes, so no table can be created."
    }
  }
}

/// A connected Copy Objects target: the caller passes `policy` to every run call and disconnects
/// `manager` after the copy
nonisolated struct CopyObjectsTarget: Sendable {
  let manager: DatabaseConnectionManager
  /// The saved row as connected: Protected mode off, everything else as saved
  let config: ConnectionConfig
  /// The target's protection level and Safe Mode, Protected mode off
  let policy: ProtectionPolicy
}

/// Where the planner puts the copied tables, and the names already used there
nonisolated struct CopyObjectsTargetNames: Sendable, Equatable {
  /// PostgreSQL current_schema(), the MySQL / MariaDB database, SQLite main
  let schema: String
  /// Tables and views; on PostgreSQL and SQLite also indexes (and PostgreSQL sequences)
  let existingNames: [String]
  /// MySQL / MariaDB foreign-key and CHECK names in the database (unique per database); empty
  /// on the other engines
  var existingConstraintNames: [String] = []
}

extension DatabaseConnectionManager {
  /// Opens a writable manager on the saved row `config`. `identity` (`config` when nil) is the
  /// saved row whose lock, password and certificate / SSH secret apply, when `config` names
  /// another database of it. `password` reads a saved password off the main actor (the Keychain
  /// in the app); a password command runs instead when the row has one. `makeManager` makes the
  /// unconnected manager: the app's host-key trust prompt by default, and its lock source is
  /// the one checked here.
  @MainActor
  static func makeCopyTargetManager(
    config: ConnectionConfig, identity: ConnectionConfig? = nil,
    password: @escaping @Sendable (ConnectionConfig) -> String? = SchemaCompareContext
      .keychainPassword,
    makeManager: @MainActor () -> DatabaseConnectionManager = { .withTrustPrompt() }
  ) async throws -> CopyObjectsTarget {
    let identity = identity ?? config
    let manager = makeManager()
    for row in [identity, config] {
      if let refusal = manager.lockSource.refusal(for: row) { throw refusal }
    }
    switch config.databaseType {
    case .postgresql, .mysql, .sqlite: break
    case .duckdb: throw CopyObjectsTargetError.unsupportedEngine("DuckDB")
    case .mongodb: throw CopyObjectsTargetError.unsupportedEngine("MongoDB")
    }
    switch config.protectionLevel {
    case .readOnly: throw CopyObjectsTargetError.readOnly
    case .schemaOnly: throw CopyObjectsTargetError.schemaOnly
    case .none: break
    }
    var connected = try await withSavedSecrets(config, identity: identity, password: password)
    connected.config.protectedMode = false
    do {
      if connected.material == nil, connected.sshCredential == nil {
        try await manager.connect(config: connected.config)
      } else {
        try await manager.reconnectWithActiveCertificate(
          config: connected.config, material: connected.material,
          sshCredential: connected.sshCredential)
      }
    } catch {
      await manager.disconnect()
      throw error
    }
    return CopyObjectsTarget(
      manager: manager, config: connected.config,
      policy: ProtectionPolicy(
        protectionLevel: connected.config.protectionLevel, safeMode: connected.config.safeMode,
        protectedMode: false))
  }

  /// `config` with `identity`'s password, and `identity`'s certificate and SSH secret under
  /// `config`'s accounts when those differ (nil when they are the same: the session reads
  /// `config`'s own saved items)
  @concurrent nonisolated private static func withSavedSecrets(
    _ config: ConnectionConfig, identity: ConnectionConfig,
    password: @Sendable (ConnectionConfig) -> String?
  ) async throws -> (
    config: ConnectionConfig, material: ClientCertificateStoreFactory.ConnectionMaterial?,
    sshCredential: SSHCredentialStoreFactory.ConnectionCredential?
  ) {
    var config = config
    if config.databaseType.capabilities.usesPassword {
      if let command = identity.passwordCommandScript {
        config.password = try await ConnectionScriptRunner.app.password(
          from: command, for: identity)
      } else if let saved = password(identity) {
        config.password = saved
      }
    }
    var material: ClientCertificateStoreFactory.ConnectionMaterial?
    let account = ClientCertificateStoreFactory.account(for: config)
    if identity.clientCertificate != nil,
      ClientCertificateStoreFactory.account(for: identity) != account,
      let saved = ClientCertificateStoreFactory.load(for: identity)
    {
      material = .init(account: account, material: saved)
    }
    var sshCredential: SSHCredentialStoreFactory.ConnectionCredential?
    if let sshAccount = SSHCredentialStoreFactory.account(for: config),
      SSHCredentialStoreFactory.account(for: identity) != sshAccount,
      let saved = SSHCredentialStoreFactory.load(for: identity)
    {
      sshCredential = .init(account: sshAccount, credential: saved)
    }
    return (config, material, sshCredential)
  }

  /// The connected target's default schema and the names already used in it, for
  /// `CopyObjectsPlanner.plan`. Throws `CopyObjectsPlanError.noTargetSchema` when PostgreSQL
  /// has no current schema or MySQL no database.
  func copyTargetNames() async throws -> CopyObjectsTargetNames {
    let schemaSQL: String?
    let namesSQL: String
    var constraintsSQL: String?
    switch config?.databaseType {
    case .postgresql:
      schemaSQL = "SELECT current_schema()"
      // Every relation kind shares the schema's namespace: tables, views, indexes, sequences
      namesSQL = """
        SELECT c.relname FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = current_schema()
        """
    case .mysql:
      schemaSQL = "SELECT DATABASE()"
      namesSQL = "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()"
      constraintsSQL = """
        SELECT CONSTRAINT_NAME FROM information_schema.TABLE_CONSTRAINTS
        WHERE TABLE_SCHEMA = DATABASE() AND CONSTRAINT_TYPE IN ('FOREIGN KEY', 'CHECK')
        """
    case .sqlite:
      schemaSQL = nil
      namesSQL = "SELECT name FROM main.sqlite_master WHERE type IN ('table', 'view', 'index')"
    case .duckdb:
      throw CopyObjectsTargetError.unsupportedEngine("DuckDB")
    case .mongodb:
      throw CopyObjectsTargetError.unsupportedEngine("MongoDB")
    case nil:
      throw DatabaseError.notConnected
    }
    var schema: String? = "main"
    if let schemaSQL { schema = try await firstColumn(schemaSQL).first }
    guard let schema, !schema.isEmpty else { throw CopyObjectsPlanError.noTargetSchema }
    var constraints: [String] = []
    if let constraintsSQL { constraints = try await firstColumn(constraintsSQL) }
    return CopyObjectsTargetNames(
      schema: schema, existingNames: try await firstColumn(namesSQL),
      existingConstraintNames: constraints)
  }

  /// The first column of every row of app-owned `sql`, uncapped
  private func firstColumn(_ sql: String) async throws -> [String] {
    try await withSession { session in
      var values: [String] = []
      for try await row in try await session.query(sql, binds: []).rows {
        if let value = MySQLCatalogValue.string(row, 0) { values.append(value) }
      }
      return values
    }
  }
}
