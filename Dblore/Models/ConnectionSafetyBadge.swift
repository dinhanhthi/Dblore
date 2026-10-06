//
//  ConnectionSafetyBadge.swift
//  Dblore
//
//  Header safety badge: protection level, or the resolved commit style when the level is
//  None, plus SSL state from the connection config. Pure mapping; the view picks colors.
//

import Foundation

struct ConnectionSafetyBadge: Equatable, Sendable {
  /// Traffic-light level (the view maps it to red / yellow / green)
  enum Level: Equatable, Sendable {
    case danger, warning, ok
  }

  struct SSLStatus: Equatable, Sendable {
    let level: Level
    let label: String
  }

  let protectionLabel: String
  let protectionIcon: String
  /// nil for SQLite (a local file, no network)
  let ssl: SSLStatus?
  let tooltip: String

  init(config: ConnectionConfig, commitStyle: CommitStyle) {
    let level = config.protectionLevel
    if level != .none {
      protectionLabel = level.displayName
      protectionIcon = level.iconName
    } else {
      protectionLabel = commitStyle.title
      protectionIcon = commitStyle == .review ? "shield.lefthalf.filled" : level.iconName
    }

    var lines: [String] = []
    if level != .none {
      lines.append("\(protectionLabel): \(level.description)")
    }
    if commitStyle == .review {
      lines.append("Review: changes stay pending until you Commit or Roll Back.")
    }

    if config.databaseType.capabilities.supportsSSL {
      let status = Self.sslStatus(config.sslMode)
      ssl = status
      lines.append(
        "SSL mode \(config.sslMode.displayName): \(Self.sslExplanation(status.level))")
    } else {
      ssl = nil
    }
    tooltip = lines.joined(separator: "\n")
  }

  static func sslStatus(_ mode: SSLMode) -> SSLStatus {
    switch mode {
    case .disable, .allow, .prefer: return SSLStatus(level: .danger, label: "No SSL")
    case .require, .verifyCa, .verifyFull: return SSLStatus(level: .ok, label: "SSL verified")
    }
  }

  private static func sslExplanation(_ level: Level) -> String {
    switch level {
    case .danger: return "the connection may be unencrypted"
    case .warning: return "encrypted, server certificate not verified"
    case .ok: return "encrypted, this app always verifies the server certificate"
    }
  }
}
