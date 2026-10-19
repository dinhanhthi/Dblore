//
//  ConnectionFormContent+ConnectionString.swift
//  Dblore
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
    if connectionConfig.databaseType == .mongodb {
      parseMongoConnectionString(connectionStr)
      return
    }
    guard let url = Self.postgresURL(from: connectionStr) else {
      setParseError("Invalid connection string format")
      return
    }

    guard let host = url.host else {
      setParseError("Missing host in connection string")
      return
    }

    let port = url.port ?? 5432
    let database = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let username = url.user(percentEncoded: false) ?? ""
    let password = url.password(percentEncoded: false) ?? ""

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

  /// A `postgresql://` or `postgres://` URL whose user and password may hold unencoded reserved
  /// characters (`?`, `/`, `#`, `@`, `:`), as cloud consoles often show them. The user info ends
  /// at the first `@` followed by a whole host[:port][/database][?key=value&…] (an `@` in the
  /// password is followed by the real `@`, an `@` in the query by no database), else at the last
  /// `@` followed by a host[:port]; the user ends at its first `:`. Both are re-encoded before
  /// `URL` reads them, so an already percent-encoded value is decoded once.
  nonisolated static func postgresURL(from connectionStr: String) -> URL? {
    let trimmed = connectionStr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let schemeEnd = trimmed.range(of: "://"),
      ["postgresql", "postgres"].contains(trimmed[..<schemeEnd.lowerBound].lowercased())
    else { return nil }
    var rest = String(trimmed[schemeEnd.upperBound...])
    let atSigns = rest.indices.filter {
      rest[$0] == "@" && isHostPort(rest[rest.index(after: $0)...])
    }
    if let at = atSigns.first(where: { isTarget(rest[rest.index(after: $0)...]) }) ?? atSigns.last {
      let userInfo = rest[..<at]
      let colon = userInfo.firstIndex(of: ":")
      var encoded = encodeUserInfo(userInfo[..<(colon ?? userInfo.endIndex)])
      if let colon { encoded += ":" + encodeUserInfo(userInfo[userInfo.index(after: colon)...]) }
      rest = encoded + rest[at...]
    }
    return URL(string: "postgresql://" + rest)
  }

  /// Whether the text up to the first `/`, `?` or `#` is a host or `[IPv6]`, with an optional port.
  private nonisolated static func isHostPort(_ text: Substring) -> Bool {
    let authority = text.prefix { !"/?#".contains($0) }
    return authority.wholeMatch(of: #/(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._%-]+)(:[0-9]*)?/#) != nil
  }

  /// Whether the text is a whole host[:port][/database][?key=value&…], the database without `@`.
  private nonisolated static func isTarget(_ text: Substring) -> Bool {
    let query = #/[A-Za-z0-9_.-]+=[^&#]*(&[A-Za-z0-9_.-]+=[^&#]*)*/#
    let target = #/(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._%-]+)(:[0-9]*)?(/[^@?#]*)?(\?(.*))?/#
    guard let match = text.wholeMatch(of: target) else { return false }
    return match.output.5.map { $0.isEmpty || $0.wholeMatch(of: query) != nil } ?? true
  }

  private nonisolated static func encodeUserInfo(_ text: Substring) -> String {
    let value = text.removingPercentEncoding ?? String(text)
    let unreserved = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
  }

  /// A `mongodb://` or `mongodb+srv://` URI through `MongoURIParser`: its password moves to the
  /// Password field and the stored `mongoURI` has no credentials.
  private func parseMongoConnectionString(_ text: String) {
    do {
      connectionConfig = try MongoConnectionDraft.paste(text, into: connectionConfig).config
      updateConnectionStringSSLMode(connectionConfig.sslMode)
      clearParseError()
    } catch {
      setParseError(MongoConnectionDraft.message(for: error))
    }
  }
}
