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
  var timeoutSeconds: Int
  var readOnly: Bool
  var name: String  // Optional label for the connection
  var safeMode: SafeMode?  // Per-connection SafeMode override (nil = use global setting)

  nonisolated init(
    databaseType: DatabaseType = .postgresql,
    host: String = "localhost",
    port: Int = 5432,
    database: String = "",
    username: String = "",
    password: String = "",
    sslMode: SSLMode = .prefer,
    rememberConnection: Bool = false,
    timeoutSeconds: Int = 30,
    readOnly: Bool = false,
    name: String = "",
    safeMode: SafeMode? = nil
  ) {
    self.databaseType = databaseType
    self.host = host
    self.port = port
    self.database = database
    self.username = username
    self.password = password
    self.sslMode = sslMode
    self.rememberConnection = rememberConnection
    self.timeoutSeconds = timeoutSeconds
    self.readOnly = readOnly
    self.name = name
    self.safeMode = safeMode
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
