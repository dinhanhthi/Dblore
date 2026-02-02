//
//  ConnectionHistoryEntry.swift
//  SQLNotebook
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

  /// Keychain key for password storage
  /// Format: "host:port:database:username"
  var keychainKey: String {
    "\(config.host):\(config.port):\(config.database):\(config.username)"
  }
}
