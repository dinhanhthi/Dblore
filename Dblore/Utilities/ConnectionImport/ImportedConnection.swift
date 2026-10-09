//
//  ImportedConnection.swift
//  Dblore
//
//  One connection read from an external file or string, before it is saved.
//

import Foundation

/// Where an imported connection came from.
nonisolated enum ImportSource: String, Equatable, Hashable, Sendable {
  case uri
  case pgpass
  case dbeaver
  case tablePlus
  case dataGrip
}

/// A connection parsed from external input. `config.password` is always empty: the secret
/// lives only in `password` (and `sshCredential`) until it is saved to the Keychain.
/// Descriptions and mirrors redact both secrets, so the value is safe to log or `dump`.
nonisolated struct ImportedConnection: Equatable, Sendable {
  var config: ConnectionConfig {
    didSet { config.password = "" }
  }
  var password: String?
  var sshCredential: SSHStoredCredential?
  var source: ImportSource
  var warnings: [String]

  init(
    config: ConnectionConfig, password: String? = nil, sshCredential: SSHStoredCredential? = nil,
    source: ImportSource, warnings: [String] = []
  ) {
    var config = config
    // Move a password left in the config into the secret field.
    let configPassword = config.password
    config.password = ""
    self.config = config
    self.password = password ?? (configPassword.isEmpty ? nil : configPassword)
    self.sshCredential = sshCredential
    self.source = source
    self.warnings = warnings
  }

  /// "user@host/db", the default name for an imported connection.
  static func defaultName(username: String, host: String, database: String) -> String {
    "\(username)@\(host)/\(database)"
  }
}

extension ImportedConnection: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  var description: String {
    let passwordState = password == nil ? "none" : "<redacted>"
    let sshState = sshCredential == nil ? "none" : "<redacted>"
    return
      "ImportedConnection(\(config.safeDisplayString), source: \(source.rawValue), password: \(passwordState), ssh: \(sshState), warnings: \(warnings.count))"
  }

  var debugDescription: String { description }

  var customMirror: Mirror {
    Mirror(self, children: ["summary": description], displayStyle: .struct)
  }
}
