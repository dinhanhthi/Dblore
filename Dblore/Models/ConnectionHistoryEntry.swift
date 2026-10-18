//
//  ConnectionHistoryEntry.swift
//  Dblore
//

import Foundation

/// Represents an entry in the connection history
/// Stores connection config (without password) and metadata
struct ConnectionHistoryEntry: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var config: ConnectionConfig  // Always stored without password
  let lastUsedAt: Date

  init(config: ConnectionConfig) {
    self.id = UUID()
    var cleanConfig = config
    cleanConfig.password = ""  // Never store password in history entry
    self.config = cleanConfig
    self.lastUsedAt = Date()
  }

  /// Display string for dropdown menu
  var displayString: String {
    let date = lastUsedAt.formatted(date: .abbreviated, time: .shortened)

    // If connection has a name, show it prominently
    if !config.name.isEmpty {
      return "\(config.name) (\(config.displayString)) • \(date)"
    }

    // Otherwise, show default format
    return "\(config.displayString) • \(date)"
  }

  /// Short display name for connection (just the name if set, otherwise connection string)
  var shortDisplayName: String {
    if !config.name.isEmpty {
      return config.name
    }
    return config.displayString
  }

  /// Formatted last used date in short form (e.g., "26 Jan 25")
  var formattedLastUsedDate: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM yy"
    return formatter.string(from: lastUsedAt)
  }

  /// Keychain key for password storage (see `ConnectionKeychainKey`)
  var keychainKey: String {
    ConnectionKeychainKey.password(for: config)
  }
}

/// The one formula for a connection's Keychain identity: the password key and the client
/// certificate account. Only engines with a `DatabaseType.keychainScope` (MySQL) carry the engine;
/// PostgreSQL, SQLite and DuckDB keep the legacy strings byte for byte. The database part is
/// `identityDatabase`, so a switched MongoDB connection keeps the items of the saved one.
nonisolated enum ConnectionKeychainKey {
  /// `host:port:database:username` for an engine without a scope; a length-prefixed account
  /// with the scope first otherwise, so colons in a field never make it equal a legacy key.
  static func password(
    scope: String?, host: String, port: Int, database: String, username: String
  ) -> String {
    guard let scope else { return "\(host):\(port):\(database):\(username)" }
    return KeychainAccount.v2([scope, host, String(port), database, username])
  }

  static func password(for config: ConnectionConfig) -> String {
    password(
      scope: config.databaseType.keychainScope, host: config.host, port: config.port,
      database: config.identityDatabase, username: config.username)
  }

  /// Length-prefixed account; the scope is an extra leading part only when the engine has one.
  static func certificateAccount(for config: ConnectionConfig) -> String {
    let parts = [config.host, String(config.port), config.identityDatabase, config.username]
    return KeychainAccount.v2((config.databaseType.keychainScope.map { [$0] } ?? []) + parts)
  }
}
