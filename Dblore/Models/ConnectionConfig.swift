//
//  ConnectionConfig.swift
//  Dblore
//

import Foundation

/// Database type supported by the application
enum DatabaseType: String, Codable, CaseIterable, Sendable {
  case postgresql = "PostgreSQL"
  case sqlite = "SQLite"
  case duckdb = "DuckDB"
  case mysql = "MySQL"
  case mongodb = "MongoDB"

  var displayName: String {
    switch self {
    case .postgresql: rawValue
    case .sqlite: rawValue
    case .duckdb: rawValue
    case .mysql: "MySQL / MariaDB"
    case .mongodb: rawValue
    }
  }

  /// Asset catalog image name for the database type icon (from simpleicons.org)
  var iconAssetName: String {
    switch self {
    case .postgresql:
      return "postgresql"
    case .sqlite:
      return "sqlite"
    case .duckdb:
      return "duckdb"
    case .mysql:
      return "mysql"
    case .mongodb:
      return "mongodb"
    }
  }

  /// Port of a new connection form. File engines keep the struct default; they have no port.
  nonisolated var defaultPort: Int {
    switch self {
    case .mysql: 3306
    case .mongodb: 27017
    case .postgresql, .sqlite, .duckdb: 5432
    }
  }

  /// Quoting and literal rules for this database.
  nonisolated var dialect: SQLDialect {
    switch self {
    case .postgresql: .postgresql
    case .sqlite: .sqlite
    case .duckdb: .duckdb
    case .mysql: .mysql
    case .mongodb: .mongodb
    }
  }

  /// Engine part of Keychain password keys and certificate accounts. Nil keeps the legacy
  /// format: PostgreSQL, SQLite and DuckDB items predate MySQL and are never migrated.
  nonisolated var keychainScope: String? {
    switch self {
    case .postgresql, .sqlite, .duckdb: nil
    case .mysql, .mongodb: rawValue
    }
  }

  /// An interrupt cancel (`CancelStrategy.interrupt`) stops only the statement: the session and
  /// its open transaction survive, so the cancel reports nothing rolled back. MySQL
  /// `KILL QUERY` and MongoDB `killOp` do. SQLite and DuckDB may roll back an explicit
  /// transaction on interrupt; PostgreSQL reconnects.
  nonisolated var interruptKeepsTransaction: Bool {
    switch self {
    case .mysql, .mongodb: true
    case .postgresql, .sqlite, .duckdb: false
    }
  }

  /// An interrupt cancel always aborts an open transaction, whatever the statement was doing
  /// (DuckDB, reads too). SQLite rolls it back only when the interrupted statement was writing.
  nonisolated var interruptAbortsTransaction: Bool {
    self == .duckdb
  }

  /// Feature set for this engine. SQLite is a file database. DuckDB is a file database
  /// shipped as a plugin: no staged edits, import, or foreign key lookup. MySQL / MariaDB is a
  /// network engine without schemas or a server cursor: cancel and capped reads stop the
  /// statement with `KILL QUERY` and keep the session. MongoDB speaks the mongosh subset,
  /// without transactions, structure editing or SQL dump. Only PostgreSQL lists sequences and
  /// user-defined types.
  nonisolated var capabilities: DatabaseCapabilities {
    switch self {
    case .postgresql:
      DatabaseCapabilities(
        usesNetwork: true,
        usesPassword: true,
        supportsSSL: true,
        supportsSchemas: true,
        supportsRolesAndUsers: true,
        supportsFunctions: true,
        supportsServerCursor: true,
        supportsSessionBrakes: true,
        cancelStrategy: .reconnect,
        cappedReadResetsSession: true,
        supportsExplainJSON: true,
        supportsExplainAnalyze: true,
        supportsUpdateOnly: true,
        supportsDefaultInUpdate: true,
        supportsRowStaging: true,
        supportsDataImport: true,
        supportsForeignKeyLookup: true,
        requiresPlugin: false,
        isAvailable: true,
        queryLanguage: .sql,
        supportsTransactions: true,
        supportsStructure: true,
        supportsSQLDump: true,
        supportsUserTypes: true
      )
    case .sqlite:
      DatabaseCapabilities(
        usesNetwork: false,
        usesPassword: false,
        supportsSSL: false,
        supportsSchemas: false,
        supportsRolesAndUsers: false,
        supportsFunctions: false,
        supportsServerCursor: false,
        supportsSessionBrakes: false,
        cancelStrategy: .interrupt,
        cappedReadResetsSession: false,
        supportsExplainJSON: false,
        supportsExplainAnalyze: false,
        supportsUpdateOnly: false,
        supportsDefaultInUpdate: false,
        supportsRowStaging: true,
        supportsDataImport: true,
        supportsForeignKeyLookup: true,
        requiresPlugin: false,
        isAvailable: true,
        queryLanguage: .sql,
        supportsTransactions: true,
        supportsStructure: true,
        supportsSQLDump: true,
        supportsUserTypes: false
      )
    case .duckdb:
      DatabaseCapabilities(
        usesNetwork: false,
        usesPassword: false,
        supportsSSL: false,
        supportsSchemas: true,
        supportsRolesAndUsers: false,
        supportsFunctions: false,
        supportsServerCursor: false,
        supportsSessionBrakes: false,
        cancelStrategy: .interrupt,
        cappedReadResetsSession: false,
        supportsExplainJSON: false,
        supportsExplainAnalyze: true,
        supportsUpdateOnly: false,
        supportsDefaultInUpdate: false,
        supportsRowStaging: false,
        supportsDataImport: false,
        supportsForeignKeyLookup: false,
        requiresPlugin: true,
        isAvailable: true,
        queryLanguage: .sql,
        supportsTransactions: true,
        supportsStructure: true,
        supportsSQLDump: true,
        supportsUserTypes: false
      )
    case .mysql:
      DatabaseCapabilities(
        usesNetwork: true,
        usesPassword: true,
        supportsSSL: true,
        supportsSchemas: false,
        supportsRolesAndUsers: false,
        supportsFunctions: true,
        supportsServerCursor: false,
        supportsSessionBrakes: true,
        cancelStrategy: .interrupt,
        cappedReadResetsSession: false,
        supportsExplainJSON: true,
        supportsExplainAnalyze: true,
        supportsUpdateOnly: false,
        supportsDefaultInUpdate: true,
        supportsRowStaging: true,
        supportsDataImport: true,
        supportsForeignKeyLookup: true,
        requiresPlugin: false,
        isAvailable: true,
        queryLanguage: .sql,
        supportsTransactions: true,
        supportsStructure: true,
        supportsSQLDump: true,
        supportsUserTypes: false
      )
    case .mongodb:
      DatabaseCapabilities(
        usesNetwork: true,
        usesPassword: true,
        supportsSSL: true,
        supportsSchemas: false,
        supportsRolesAndUsers: false,
        supportsFunctions: false,
        supportsServerCursor: false,
        supportsSessionBrakes: true,
        cancelStrategy: .interrupt,
        cappedReadResetsSession: false,
        supportsExplainJSON: false,
        supportsExplainAnalyze: false,
        supportsUpdateOnly: false,
        supportsDefaultInUpdate: false,
        supportsRowStaging: false,
        supportsDataImport: false,
        supportsForeignKeyLookup: false,
        requiresPlugin: false,
        isAvailable: true,
        queryLanguage: .mongosh,
        supportsTransactions: false,
        supportsStructure: false,
        supportsSQLDump: false,
        supportsUserTypes: false
      )
    }
  }

  /// Whether tab titles and sidebar rows name a non-default schema. A MySQL "schema" is the
  /// connected database, the only one shown, so it is never named. SQLite keeps naming attached
  /// and temp databases.
  nonisolated var namesSchema: Bool {
    switch self {
    case .postgresql, .sqlite, .duckdb: true
    case .mysql, .mongodb: false
    }
  }

  /// Engines listed in the connection form. Unavailable engines appear only when
  /// `showExperimental` is on. An engine that `requiresPlugin` appears only when
  /// `isPluginInstalled` says so, whatever the toggle. The default provider reports no plugin
  /// installed. Saved connections are not filtered here.
  nonisolated static func connectionPickerTypes(
    showExperimental: Bool,
    isPluginInstalled: (DatabaseType) -> Bool = { _ in false }
  ) -> [DatabaseType] {
    allCases.filter { type in
      let capabilities = type.capabilities
      guard capabilities.isAvailable || showExperimental else { return false }
      return !capabilities.requiresPlugin || isPluginInstalled(type)
    }
  }
}

/// Protection level for database connections
/// Combines the previous readOnly and blockSchemaChanges into a single setting
enum ConnectionProtectionLevel: String, Codable, CaseIterable, Sendable {
  /// No protection - all queries allowed
  case none
  /// Block schema changes only (CREATE/DROP/ALTER/TRUNCATE)
  /// Data modifications (INSERT/UPDATE/DELETE) are allowed
  case schemaOnly = "schema"
  /// Full read-only mode - block all modifications including data and schema
  case readOnly = "readonly"

  var displayName: String {
    switch self {
    case .none: return "None"
    case .schemaOnly: return "Schema Protected"
    case .readOnly: return "Read-Only"
    }
  }

  var description: String {
    switch self {
    case .none:
      return "All queries allowed"
    case .schemaOnly:
      return "Block CREATE, DROP, ALTER, TRUNCATE"
    case .readOnly:
      return "Block all data and schema modifications"
    }
  }

  /// Icon for UI display
  var iconName: String {
    switch self {
    case .none: return "lock.open"
    case .schemaOnly: return "tablecells.badge.ellipsis"
    case .readOnly: return "lock.fill"
    }
  }

  /// Whether this level blocks schema changes
  var blocksSchemaChanges: Bool {
    self == .schemaOnly || self == .readOnly
  }

  /// Whether this level blocks data modifications
  var blocksDataModifications: Bool {
    self == .readOnly
  }
}

/// Configuration for database connection
nonisolated struct ClientCertificateInfo: Codable, Equatable, Sendable {
  /// Nil when only a custom CA is saved (no client certificate).
  var subject: String?
  var expiry: Date?
  var hasCA: Bool
}

/// SSH bastion for a connection. Display data only: the password or decrypted key lives in
/// SSHCredentialStore, and a key passphrase is never kept.
nonisolated struct SSHTunnelConfig: Codable, Equatable, Sendable {
  enum AuthMethod: String, Codable, Sendable {
    case password
    case privateKey
  }

  var host: String
  var port: Int
  var username: String
  var authMethod: AuthMethod
  var keyAlgorithm: String?
  var keyFingerprint: String?

  init(
    host: String, port: Int = 22, username: String, authMethod: AuthMethod = .password,
    keyAlgorithm: String? = nil, keyFingerprint: String? = nil
  ) {
    self.host = host
    self.port = port
    self.username = username
    self.authMethod = authMethod
    self.keyAlgorithm = keyAlgorithm
    self.keyFingerprint = keyFingerprint
  }
}

struct ConnectionConfig: Codable, nonisolated Equatable, Sendable {
  var databaseType: DatabaseType
  var host: String
  var port: Int
  var database: String
  var username: String
  var password: String
  var sslMode: SSLMode
  /// Display metadata only. PEM bytes live in ClientCertificateStore.
  var clientCertificate: ClientCertificateInfo?
  /// Display metadata only. SSH secrets live in SSHCredentialStore.
  var sshTunnel: SSHTunnelConfig?
  var rememberConnection: Bool
  var timeoutSeconds: Int
  var protectionLevel: ConnectionProtectionLevel  // Replaces readOnly and blockSchemaChanges
  var name: String  // Optional label for the connection
  var safeMode: SafeMode?  // Per-connection SafeMode override (nil = use global setting)
  var protectedMode: Bool  // Protected mode (ON by default, also for legacy connections)
  /// Nil only for a legacy, never-edited connection.
  var commitStyle: CommitStyle?
  var hasStoredCommitStyle: Bool { commitStyle != nil }
  // Per-connection timeout overrides (nil = use the global setting, see `resolvingBrakes`)
  var statementTimeoutSeconds: Int?  // Server-side statement_timeout
  var lockTimeoutSeconds: Int?  // Server-side lock_timeout
  var idleInTransactionTimeoutSeconds: Int?  // Server-side idle_in_transaction_session_timeout
  var rowCapOverride: Int?  // Per-connection row cap (nil = use global setting)
  /// Security-scoped bookmark for a file database. The path itself is `database`. Never a password.
  var fileBookmark: Data?
  /// Open a file database without writing. Distinct from `protectionLevel` and from `readOnly`.
  /// Defaults to true for DuckDB files (the brief: read-only by default), false otherwise.
  var readOnlyFile: Bool
  /// MongoDB connection string rebuilt by `MongoURIParser` from allow-listed fields only: never
  /// userinfo or unknown options. TLS lives in `sslMode`.
  var mongoURI: String?
  /// Database of the saved connection after a MongoDB database switch (nil: never switched).
  /// Keychain identities and the default authSource use it, so they stay those of the saved
  /// connection.
  var mongoHomeDatabase: String?
  /// Whether AI features may use this connection (`.useDefault` follows the AI settings).
  var aiAccess: AIAccessPolicy
  /// Instructions sent to the model with this connection's context, at most `aiRulesLimit`
  /// characters.
  var aiRules: String {
    didSet { aiRules = Self.clampedAIRules(aiRules) }
  }

  /// Swatch shown next to the connection; one of the app accent palette colors.
  var colorTag: AccentColor?
  /// Folder the connection is listed under, normalized by `normalizedGroupName`.
  var groupName: String? {
    didSet { groupName = Self.normalizedGroupName(groupName) }
  }

  nonisolated static let aiRulesLimit = 2_000
  nonisolated static let groupNameLimit = 64

  /// Trimmed and cut to `groupNameLimit` characters; blank becomes nil.
  nonisolated static func normalizedGroupName(_ name: String?) -> String? {
    guard let name else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let cut = String(trimmed.prefix(groupNameLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    return cut.isEmpty ? nil : cut
  }

  nonisolated static func clampedAIRules(_ rules: String) -> String {
    rules.count > aiRulesLimit ? String(rules.prefix(aiRulesLimit)) : rules
  }

  /// The database part of the connection's Keychain identity: the pin (MongoDB only), else
  /// `database`.
  nonisolated var identityDatabase: String {
    databaseType == .mongodb ? mongoHomeDatabase ?? database : database
  }

  // Custom CodingKeys for backward compatibility
  private enum CodingKeys: String, CodingKey {
    case databaseType, host, port, database, username, password, sslMode, clientCertificate
    // Absent on connections saved before SSH tunnels
    case sshTunnel
    case rememberConnection, timeoutSeconds, name, safeMode
    case protectedMode, commitStyle, statementTimeoutSeconds, lockTimeoutSeconds
    case idleInTransactionTimeoutSeconds, rowCapOverride
    // Marks timeouts saved as overrides; absent on connections saved before global timeouts
    case brakeOverrides
    // New key
    case protectionLevel
    // File database (absent on connections saved before SQLite config)
    case fileBookmark, readOnlyFile
    // MongoDB connection string (absent on other engines and on older connections)
    case mongoURI
    // Identity pin of a switched MongoDB connection (absent unless switched)
    case mongoHomeDatabase
    // AI access policy and rules (absent on connections saved before them)
    case aiAccess, aiRules
    // Color and group (absent on connections saved before them)
    case colorTag, groupName
    // Legacy keys (for reading old data)
    case readOnly, blockSchemaChanges
  }

  // Custom decoder for backward compatibility with old readOnly/blockSchemaChanges format
  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    databaseType = try container.decode(DatabaseType.self, forKey: .databaseType)
    host = try container.decode(String.self, forKey: .host)
    port = try container.decode(Int.self, forKey: .port)
    database = try container.decode(String.self, forKey: .database)
    username = try container.decode(String.self, forKey: .username)
    password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
    sslMode = try container.decode(SSLMode.self, forKey: .sslMode)
    clientCertificate = try container.decodeIfPresent(
      ClientCertificateInfo.self, forKey: .clientCertificate)
    sshTunnel = try container.decodeIfPresent(SSHTunnelConfig.self, forKey: .sshTunnel)
    rememberConnection = try container.decode(Bool.self, forKey: .rememberConnection)
    timeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
    name = try container.decode(String.self, forKey: .name)
    safeMode = try container.decodeIfPresent(SafeMode.self, forKey: .safeMode)
    protectedMode = try container.decodeIfPresent(Bool.self, forKey: .protectedMode) ?? true
    if let rawStyle = try container.decodeIfPresent(String.self, forKey: .commitStyle) {
      commitStyle = CommitStyle(rawValue: rawStyle)
    } else {
      commitStyle = nil
    }
    // Before global timeouts every connection stored concrete values; one equal to the old
    // default can't be told from a choice, so it follows the global setting.
    let storedAsOverrides =
      try container.decodeIfPresent(Bool.self, forKey: .brakeOverrides) ?? false
    func decodeBrake(
      _ key: CodingKeys, range: ClosedRange<Int>, legacyDefault: Int
    ) throws -> Int? {
      let value = SessionBrakeLimits.clampOverride(
        try container.decodeIfPresent(Int.self, forKey: key), to: range)
      return storedAsOverrides || value != legacyDefault ? value : nil
    }
    statementTimeoutSeconds = try decodeBrake(
      .statementTimeoutSeconds, range: SessionBrakeLimits.statementTimeoutRange,
      legacyDefault: SessionBrakeLimits.defaultStatementTimeout)
    lockTimeoutSeconds = try decodeBrake(
      .lockTimeoutSeconds, range: SessionBrakeLimits.lockTimeoutRange,
      legacyDefault: SessionBrakeLimits.defaultLockTimeout)
    idleInTransactionTimeoutSeconds = try decodeBrake(
      .idleInTransactionTimeoutSeconds, range: SessionBrakeLimits.idleTimeoutRange,
      legacyDefault: SessionBrakeLimits.defaultIdleTimeout)
    rowCapOverride = try container.decodeIfPresent(Int.self, forKey: .rowCapOverride)
    fileBookmark = try container.decodeIfPresent(Data.self, forKey: .fileBookmark)
    readOnlyFile =
      try container.decodeIfPresent(Bool.self, forKey: .readOnlyFile) ?? (databaseType == .duckdb)
    mongoURI = try container.decodeIfPresent(String.self, forKey: .mongoURI)
    mongoHomeDatabase = try container.decodeIfPresent(String.self, forKey: .mongoHomeDatabase)
    // An unknown policy (e.g. from a newer version) follows the AI settings
    let rawAccess = try container.decodeIfPresent(String.self, forKey: .aiAccess)
    aiAccess = rawAccess.flatMap(AIAccessPolicy.init(rawValue:)) ?? .useDefault
    aiRules = Self.clampedAIRules(
      try container.decodeIfPresent(String.self, forKey: .aiRules) ?? "")
    // An unknown color (e.g. from a newer version) shows no color
    let rawColor = try container.decodeIfPresent(String.self, forKey: .colorTag)
    colorTag = rawColor.flatMap(AccentColor.init(rawValue:))
    groupName = Self.normalizedGroupName(
      try container.decodeIfPresent(String.self, forKey: .groupName))

    // Try to decode new protectionLevel first, fall back to legacy fields
    if let level = try container.decodeIfPresent(
      ConnectionProtectionLevel.self, forKey: .protectionLevel)
    {
      protectionLevel = level
    } else {
      // Migrate from legacy readOnly/blockSchemaChanges
      let readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
      let blockSchemaChanges =
        try container.decodeIfPresent(Bool.self, forKey: .blockSchemaChanges) ?? false

      if readOnly {
        protectionLevel = .readOnly
      } else if blockSchemaChanges {
        protectionLevel = .schemaOnly
      } else {
        protectionLevel = .none
      }
    }
  }

  // Custom encoder - only encode new format
  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(databaseType, forKey: .databaseType)
    try container.encode(host, forKey: .host)
    try container.encode(port, forKey: .port)
    try container.encode(database, forKey: .database)
    try container.encode(username, forKey: .username)
    try container.encode(password, forKey: .password)
    try container.encode(sslMode, forKey: .sslMode)
    try container.encodeIfPresent(clientCertificate, forKey: .clientCertificate)
    try container.encodeIfPresent(sshTunnel, forKey: .sshTunnel)
    try container.encode(rememberConnection, forKey: .rememberConnection)
    try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
    try container.encode(protectionLevel, forKey: .protectionLevel)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(safeMode, forKey: .safeMode)
    try container.encode(protectedMode, forKey: .protectedMode)
    try container.encodeIfPresent(commitStyle, forKey: .commitStyle)
    try container.encodeIfPresent(statementTimeoutSeconds, forKey: .statementTimeoutSeconds)
    try container.encodeIfPresent(lockTimeoutSeconds, forKey: .lockTimeoutSeconds)
    try container.encodeIfPresent(
      idleInTransactionTimeoutSeconds, forKey: .idleInTransactionTimeoutSeconds)
    try container.encode(true, forKey: .brakeOverrides)
    try container.encodeIfPresent(rowCapOverride, forKey: .rowCapOverride)
    try container.encodeIfPresent(fileBookmark, forKey: .fileBookmark)
    try container.encode(readOnlyFile, forKey: .readOnlyFile)
    try container.encodeIfPresent(mongoURI, forKey: .mongoURI)
    try container.encodeIfPresent(mongoHomeDatabase, forKey: .mongoHomeDatabase)
    try container.encode(aiAccess, forKey: .aiAccess)
    try container.encode(aiRules, forKey: .aiRules)
    try container.encodeIfPresent(colorTag?.rawValue, forKey: .colorTag)
    try container.encodeIfPresent(groupName, forKey: .groupName)
  }

  nonisolated init(
    databaseType: DatabaseType = .postgresql,
    host: String = "localhost",
    port: Int = 5432,
    database: String = "",
    username: String = "",
    password: String = "",
    sslMode: SSLMode = .prefer,
    clientCertificate: ClientCertificateInfo? = nil,
    sshTunnel: SSHTunnelConfig? = nil,
    rememberConnection: Bool = true,
    timeoutSeconds: Int = 30,
    protectionLevel: ConnectionProtectionLevel = .none,
    name: String = "",
    safeMode: SafeMode? = nil,
    protectedMode: Bool = true,
    statementTimeoutSeconds: Int? = nil,
    lockTimeoutSeconds: Int? = nil,
    idleInTransactionTimeoutSeconds: Int? = nil,
    rowCapOverride: Int? = nil,
    fileBookmark: Data? = nil,
    readOnlyFile: Bool? = nil,
    colorTag: AccentColor? = nil,
    groupName: String? = nil
  ) {
    self.databaseType = databaseType
    self.host = host
    self.port = port
    self.database = database
    self.username = username
    self.password = password
    self.sslMode = sslMode
    self.clientCertificate = clientCertificate
    self.sshTunnel = sshTunnel
    self.rememberConnection = rememberConnection
    self.timeoutSeconds = timeoutSeconds
    self.protectionLevel = protectionLevel
    self.name = name
    self.safeMode = safeMode
    self.protectedMode = protectedMode
    self.commitStyle = nil
    self.statementTimeoutSeconds = statementTimeoutSeconds
    self.lockTimeoutSeconds = lockTimeoutSeconds
    self.idleInTransactionTimeoutSeconds = idleInTransactionTimeoutSeconds
    self.rowCapOverride = rowCapOverride
    self.fileBookmark = fileBookmark
    self.readOnlyFile = readOnlyFile ?? (databaseType == .duckdb)
    self.aiAccess = .useDefault
    self.aiRules = ""
    self.colorTag = colorTag
    self.groupName = Self.normalizedGroupName(groupName)
  }

  /// A copy with every timeout filled in: the connection's own override, else `global`.
  nonisolated func resolvingBrakes(_ global: SessionBrakeDefaults) -> ConnectionConfig {
    var resolved = self
    resolved.statementTimeoutSeconds = statementTimeoutSeconds ?? global.statement
    resolved.lockTimeoutSeconds = lockTimeoutSeconds ?? global.lock
    resolved.idleInTransactionTimeoutSeconds = idleInTransactionTimeoutSeconds ?? global.idle
    return resolved
  }

  /// Stores `style` and copies its legacy protected-mode and safe-mode pair.
  /// Not used by init, decode, or encode, so a legacy connection stays unchanged until edited.
  mutating func applyCommitStyle(_ style: CommitStyle) {
    commitStyle = style
    let projection = style.legacyProjection
    protectedMode = projection.protectedMode
    safeMode = projection.safeMode
  }

  nonisolated func resolvedCommitStyle(fallback: CommitStyle) -> CommitStyle {
    resolvedCommitStyle(
      fallback: fallback, supportsTransactions: databaseType.capabilities.supportsTransactions)
  }

  /// Without transactions (MongoDB) Review becomes Confirm, and Protected mode raises a weaker
  /// style to Confirm (a stronger one, Password, is kept).
  nonisolated func resolvedCommitStyle(
    fallback: CommitStyle, supportsTransactions: Bool
  ) -> CommitStyle {
    let candidate: CommitStyle
    if let commitStyle {
      candidate = commitStyle
    } else {
      candidate = CommitStyle.migrate(protectedMode: protectedMode, safeMode: safeMode) ?? fallback
    }
    // protectedMode is the gate's source of truth.
    if protectedMode, supportsTransactions {
      return .review
    }
    let resolved: CommitStyle = candidate == .review ? .confirm : candidate
    if protectedMode, resolved.strength < CommitStyle.confirm.strength {
      return .confirm
    }
    return resolved
  }

  // MARK: - Convenience accessors (for easier migration)

  /// Whether this connection blocks all modifications (read-only mode)
  var isReadOnly: Bool {
    protectionLevel == .readOnly
  }

  /// Whether this connection blocks schema changes
  var blocksSchemaChanges: Bool {
    protectionLevel.blocksSchemaChanges
  }

  /// Display string for connection info
  var displayString: String {
    "\(database)@\(host):\(port)"
  }

  /// Safe display string for logging (redacts sensitive host information)
  /// Examples:
  /// - "mydb@db.example.com:5432" -> "mydb@db.*****.com:5432"
  /// - "mydb@192.168.1.100:5432" -> "mydb@192.168.***.***:5432"
  /// - "mydb@localhost:5432" -> "mydb@localhost:5432" (localhost is safe)
  nonisolated var safeDisplayString: String {
    let maskedHost = redactHost(host)
    return "\(database)@\(maskedHost):\(port)"
  }

  /// Redact host/IP address for security (private helper)
  private nonisolated func redactHost(_ host: String) -> String {
    // Don't redact localhost (safe for debugging)
    if host.lowercased() == "localhost" || host == "127.0.0.1" {
      return host
    }

    // Redact IP addresses (e.g., 192.168.1.100 -> 192.168.***.***)
    if host.contains(".") && host.split(separator: ".").count == 4 {
      let parts = host.split(separator: ".")
      if parts.count == 4 && parts.allSatisfy({ Int($0) != nil }) {
        return "\(parts[0]).\(parts[1]).***. ***"
      }
    }

    // Redact domain names (keep first and last part, e.g., db.example.com -> db.*****.com)
    if host.contains(".") {
      let parts = host.split(separator: ".")
      if parts.count >= 2 {
        let first = parts.first!
        let last = parts.last!
        return "\(first).*****.\(last)"
      }
    }

    // Fallback: redact middle characters for short strings
    if host.count > 4 {
      let prefix = String(host.prefix(2))
      let suffix = String(host.suffix(2))
      return "\(prefix)***\(suffix)"
    }

    return "****"
  }
}

/// SSL mode for database connections
enum SSLMode: String, Codable, CaseIterable, Sendable {
  case disable
  case allow
  case prefer
  case require
  case verifyCa = "verify-ca"
  case verifyFull = "verify-full"

  var displayName: String {
    switch self {
    case .disable: return "Disable"
    case .allow: return "Allow"
    case .prefer: return "Prefer"
    case .require: return "Require"
    case .verifyCa: return "Verify CA"
    case .verifyFull: return "Verify Full"
    }
  }

  /// Disable, Allow and Prefer may fall back to a plain connection
  var mayBeUnencrypted: Bool {
    switch self {
    case .disable, .allow, .prefer: return true
    case .require, .verifyCa, .verifyFull: return false
    }
  }
}

/// State of the database connection
enum ConnectionState: Equatable, Sendable {
  case disconnected
  case connecting
  case connected
  case error(String)

  var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }

  var isConnecting: Bool {
    if case .connecting = self { return true }
    return false
  }

  /// Extra title-bar width for two small icon buttons: the info button, plus either
  /// the connect bolt or the schema visualizer. Each button adds 31pt.
  var connectionButtonsWidth: CGFloat { 78 }
}
