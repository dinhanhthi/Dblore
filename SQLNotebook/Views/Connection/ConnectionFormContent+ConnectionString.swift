//
//  ConnectionFormContent+ConnectionString.swift
//  SQLNotebook
//
//  Connection string parsing and generation
//

import SwiftUI

// MARK: - Connection String Extension

extension ConnectionFormContent {

  func generateConnectionString() -> String {
    let config = connectionConfig
    var components = URLComponents()
    components.scheme = "postgresql"
    components.user = config.username
    components.password = config.password.isEmpty ? nil : config.password
    components.host = config.host
    components.port = config.port
    components.path = "/\(config.database)"
    components.queryItems = [URLQueryItem(name: "sslmode", value: config.sslMode.rawValue)]

    return components.url?.absoluteString ?? ""
  }

  func parseConnectionString(_ connectionStr: String) {
    // Support both postgresql:// and postgres:// schemes
    let normalizedStr = connectionStr.replacingOccurrences(of: "postgres://", with: "postgresql://")

    guard let url = URL(string: normalizedStr),
      let scheme = url.scheme,
      scheme == "postgresql" || scheme == "postgres"
    else {
      setParseError("Invalid connection string format")
      return
    }

    guard let host = url.host else {
      setParseError("Missing host in connection string")
      return
    }

    let port = url.port ?? 5432
    let database = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let username = url.user ?? ""
    let password = url.password ?? ""

    // Parse SSL mode from query parameters
    var sslMode: SSLMode = .prefer
    var hasExplicitSSLMode = false
    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    {
      for item in queryItems {
        if item.name == "sslmode", let value = item.value {
          sslMode = SSLMode(rawValue: value) ?? .prefer
          hasExplicitSSLMode = true
        }
      }
    }

    // Smart default: Detect cloud database providers and require SSL
    if !hasExplicitSSLMode {
      let hostLower = host.lowercased()
      if hostLower.contains("supabase.com") || hostLower.contains("aws")
        || hostLower.contains("azure") || hostLower.contains("gcp") || hostLower.contains("cloud")
      {
        sslMode = .require
      }
    }

    if database.isEmpty {
      setParseError("Missing database name in connection string")
      return
    }

    if username.isEmpty {
      setParseError("Missing username in connection string")
      return
    }

    // Update the config
    connectionConfig.host = host
    connectionConfig.port = port
    connectionConfig.database = database
    connectionConfig.username = username
    connectionConfig.password = password
    connectionConfig.sslMode = sslMode

    // Sync the state for the SSL mode picker
    updateConnectionStringSSLMode(sslMode)

    clearParseError()
  }
}
