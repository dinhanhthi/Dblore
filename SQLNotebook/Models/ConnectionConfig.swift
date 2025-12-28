//
//  ConnectionConfig.swift
//  SQLNotebook
//

import Foundation

/// Database type supported by the application
enum DatabaseType: String, Codable, CaseIterable, Sendable {
  case postgresql = "PostgreSQL"
  case sqlite = "SQLite"

  var displayName: String {
    rawValue
  }
}

/// Configuration for database connection
struct ConnectionConfig: Codable, Equatable, Sendable {
  var databaseType: DatabaseType
  var host: String
  var port: Int
  var database: String
  var username: String
  var password: String
  var sslMode: SSLMode
  var rememberConnection: Bool

  nonisolated init(
    databaseType: DatabaseType = .postgresql,
    host: String = "localhost",
    port: Int = 5432,
    database: String = "",
    username: String = "",
    password: String = "",
    sslMode: SSLMode = .prefer,
    rememberConnection: Bool = false
  ) {
    self.databaseType = databaseType
    self.host = host
    self.port = port
    self.database = database
    self.username = username
    self.password = password
    self.sslMode = sslMode
    self.rememberConnection = rememberConnection
  }

  /// Display string for connection info
  var displayString: String {
    "\(database)@\(host):\(port)"
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
}
