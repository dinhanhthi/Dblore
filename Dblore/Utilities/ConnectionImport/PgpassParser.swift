//
//  PgpassParser.swift
//  Dblore
//
//  Parses a .pgpass file into concrete connections. Input is external: warnings carry the
//  line number and reason only, never the line text.
//

import Foundation

nonisolated enum PgpassParser {
  static func parse(_ text: String) -> (connections: [ImportedConnection], warnings: [String]) {
    var connections: [ImportedConnection] = []
    var warnings: [String] = []
    var firstLineForKey: [String: Int] = [:]

    // "\r\n" is one Character in Swift, so split on any newline rather than "\n".
    for (offset, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .enumerated()
    {
      let lineNumber = offset + 1
      if line.hasPrefix("#") || line.allSatisfy(\.isWhitespace) { continue }

      let fields = splitFields(line)
      guard fields.count >= 5 else {
        warnings.append("Line \(lineNumber): expected host:port:database:username:password.")
        continue
      }
      let (host, portField, database, username) = (fields[0], fields[1], fields[2], fields[3])
      if [host, portField, database, username].contains(where: \.isWildcard) {
        warnings.append("Line \(lineNumber): wildcard entry skipped.")
        continue
      }
      guard !host.value.isEmpty, !database.value.isEmpty, !username.value.isEmpty else {
        warnings.append("Line \(lineNumber): empty host, database or username.")
        continue
      }
      if host.value.hasPrefix("/") {
        warnings.append("Line \(lineNumber): unix socket entry skipped.")
        continue
      }
      guard portField.value.allSatisfy({ $0.isASCII && $0.isNumber }),
        let port = Int(portField.value), (1...65535).contains(port)
      else {
        warnings.append("Line \(lineNumber): invalid port.")
        continue
      }

      let key = [host.value, String(port), database.value, username.value].joined(separator: "\n")
      if let firstLine = firstLineForKey[key] {
        warnings.append("Line \(lineNumber): duplicate of line \(firstLine), skipped.")
        continue
      }
      firstLineForKey[key] = lineNumber

      let config = ConnectionConfig(
        databaseType: .postgresql, host: host.value, port: port, database: database.value,
        username: username.value,
        name: ImportedConnection.defaultName(
          username: username.value, host: host.value, database: database.value))
      connections.append(
        ImportedConnection(config: config, password: fields[4].value, source: .pgpass))
    }
    return (connections, warnings)
  }

  private struct Field {
    var value = ""
    /// A wildcard is an unescaped `*` alone in the field.
    var isWildcard = false
  }

  /// Splits on unescaped `:`, resolving `\:` and `\\`. Like libpq, the password ends at the
  /// next unescaped `:` and any later fields are ignored.
  private static func splitFields(_ line: Substring) -> [Field] {
    var fields: [Field] = []
    var current = Field()
    var raw = ""
    var escaping = false
    for character in line {
      if escaping {
        current.value.append(character)
        raw.append("\\")
        raw.append(character)
        escaping = false
      } else if character == "\\" {
        escaping = true
      } else if character == ":" {
        current.isWildcard = raw == "*"
        fields.append(current)
        current = Field()
        raw = ""
      } else {
        current.value.append(character)
        raw.append(character)
      }
    }
    // A trailing lone backslash is kept literally, as libpq does.
    if escaping { current.value.append("\\") }
    current.isWildcard = raw == "*"
    fields.append(current)
    return fields
  }
}
