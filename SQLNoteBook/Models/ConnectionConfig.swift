//
//  ConnectionConfig.swift
//  SQLNotebook
//

import Foundation

/// Configuration for database connection
struct ConnectionConfig: Codable, Equatable, Sendable {
  var host: String
  var port: Int
  var database: String
  var username: String
  var password: String
  var sslMode: SSLMode

  nonisolated init(
    host: String = "localhost",
    port: Int = 5432,
    database: String = "",
    username: String = "",
    password: String = "",
    sslMode: SSLMode = .prefer
  ) {
    self.host = host
    self.port = port
    self.database = database
    self.username = username
    self.password = password
    self.sslMode = sslMode
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
