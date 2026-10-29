//
//  SchemaPositionsStore.swift
//  Dblore
//
//  Stores schema visualizer node positions per database connection
//

import CoreGraphics
import Foundation

/// Stores and retrieves schema node positions for each database connection
/// Positions are persisted locally using UserDefaults, keyed by connection identifier
enum SchemaPositionsStore {
  private nonisolated static let storageKey = "app.schema.nodePositions"

  /// Generate a unique key for a database connection
  /// Format: "host:port/database"
  static func connectionKey(host: String, port: Int, database: String) -> String {
    "\(host):\(port)/\(database)"
  }

  /// Generate connection key from ConnectionConfig. Engines with a Keychain scope (MySQL) prefix
  /// it (`MySQL|host:port/database`), so they never share positions with PostgreSQL on the same
  /// tuple; PostgreSQL, SQLite and DuckDB keep the legacy key.
  static func connectionKey(from config: ConnectionConfig) -> String {
    let key = connectionKey(host: config.host, port: config.port, database: config.database)
    return config.databaseType.keychainScope.map { "\($0)|\(key)" } ?? key
  }

  /// Save positions for a specific database connection, replacing its entry. `keepingOthers`
  /// (a diagram showing some of the tables) merges them by table: the others keep theirs.
  static func savePositions(
    _ positions: [SavedNodePosition], forConnection key: String, keepingOthers: Bool = false
  ) {
    var allPositions = loadAllPositions()

    // Convert positions to dictionary format
    let positionsData = positions.map { position in
      [
        "tableQualifiedName": position.tableQualifiedName,
        "x": position.x,
        "y": position.y,
      ] as [String: Any]
    }

    let saved = keepingOthers ? allPositions[key] as? [[String: Any]] ?? [] : []
    let replaced = Set(positions.map(\.tableQualifiedName))
    let kept = saved.filter { entry in
      (entry["tableQualifiedName"] as? String).map { !replaced.contains($0) } ?? false
    }
    allPositions[key] = positionsData + kept
    UserDefaults.standard.set(allPositions, forKey: storageKey)
  }

  /// Remove the saved positions of these tables only (the others stay)
  static func removePositions(
    forTables qualifiedNames: Set<String>, forConnection key: String
  ) {
    var allPositions = loadAllPositions()
    guard let saved = allPositions[key] as? [[String: Any]] else { return }
    allPositions[key] = saved.filter { entry in
      (entry["tableQualifiedName"] as? String).map { !qualifiedNames.contains($0) } ?? false
    }
    UserDefaults.standard.set(allPositions, forKey: storageKey)
  }

  /// Load positions for a specific database connection
  static func loadPositions(forConnection key: String) -> [SavedNodePosition] {
    let allPositions = loadAllPositions()

    guard let positionsData = allPositions[key] as? [[String: Any]] else {
      return []
    }

    return positionsData.compactMap { dict in
      guard let tableName = dict["tableQualifiedName"] as? String,
        let x = dict["x"] as? Double,
        let y = dict["y"] as? Double
      else {
        return nil
      }
      return SavedNodePosition(
        tableQualifiedName: tableName,
        position: CGPoint(x: x, y: y)
      )
    }
  }

  /// Clear positions for a specific database connection
  static func clearPositions(forConnection key: String) {
    var allPositions = loadAllPositions()
    allPositions.removeValue(forKey: key)
    UserDefaults.standard.set(allPositions, forKey: storageKey)
  }

  /// Clear all saved positions
  static func clearAllPositions() {
    UserDefaults.standard.removeObject(forKey: storageKey)
  }

  /// Load all positions data from UserDefaults
  private static func loadAllPositions() -> [String: Any] {
    UserDefaults.standard.dictionary(forKey: storageKey) ?? [:]
  }

  nonisolated static func storedPositions(defaults: UserDefaults, domainName: String) -> Any? {
    defaults.persistentDomain(forName: domainName)?[storageKey]
  }

  nonisolated static func exportSnapshot(defaults: UserDefaults, domainName: String) -> Any? {
    storedPositions(defaults: defaults, domainName: domainName)
  }

  nonisolated static func replace(_ positions: Any?, defaults: UserDefaults, domainName: String) {
    var domain = defaults.persistentDomain(forName: domainName) ?? [:]
    if let positions {
      domain[storageKey] = positions
    } else {
      domain.removeValue(forKey: storageKey)
    }
    defaults.setPersistentDomain(domain, forName: domainName)
  }

  nonisolated static func clearAll(defaults: UserDefaults, domainName: String) {
    replace(nil, defaults: defaults, domainName: domainName)
  }
}
