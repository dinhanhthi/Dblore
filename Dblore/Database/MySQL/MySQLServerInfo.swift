// MySQLServerInfo.swift
// MySQL or MariaDB and its version, parsed from `SELECT VERSION()` ("8.4.11",
// "11.4.13-MariaDB-ubu2404"), plus the version-dependent choices the session needs.

import Foundation

nonisolated struct MySQLServerInfo: Equatable, Sendable {
  enum Flavor: Sendable {
    case mysql
    case mariadb
  }

  let flavor: Flavor
  let major: Int
  let minor: Int
  let patch: Int
  /// The session's `max_allowed_packet` in bytes, read when the session opens; nil if unknown.
  var maxAllowedPacket: Int?

  init(flavor: Flavor, major: Int, minor: Int, patch: Int) {
    self.flavor = flavor
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  /// Nil when `version` does not start with `major.minor`.
  init?(version: String) {
    let flavor: Flavor =
      version.range(of: "mariadb", options: .caseInsensitive) != nil ? .mariadb : .mysql
    var text = Substring(version)
    // MariaDB before 11 could report a "5.5.5-" replication prefix.
    if flavor == .mariadb, text.hasPrefix("5.5.5-") { text = text.dropFirst(6) }
    let numbers = text.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap {
      Int($0)
    }
    guard numbers.count >= 2 else { return nil }
    self.init(
      flavor: flavor, major: numbers[0], minor: numbers[1],
      patch: numbers.count > 2 ? numbers[2] : 0)
  }

  /// `EXPLAIN ANALYZE` exists on MySQL 8.0.18+; MariaDB has `ANALYZE` instead.
  var supportsExplainAnalyze: Bool {
    flavor == .mysql && (major, minor, patch) >= (8, 0, 18)
  }

  /// Session variable of the statement timeout: milliseconds on MySQL (SELECT only), seconds
  /// on MariaDB.
  var statementTimeoutVariable: String {
    flavor == .mysql ? "max_execution_time" : "max_statement_time"
  }

  /// `seconds` in the unit of `statementTimeoutVariable`.
  func statementTimeoutValue(seconds: Int) -> Int {
    flavor == .mysql ? seconds * 1_000 : seconds
  }
}
