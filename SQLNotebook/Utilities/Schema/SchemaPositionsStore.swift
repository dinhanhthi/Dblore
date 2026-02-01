//
//  SchemaPositionsStore.swift
//  SQLNotebook
//
//  Stores schema visualizer node positions per database connection
//

import CoreGraphics
import Foundation

/// Stores and retrieves schema node positions for each database connection
/// Positions are persisted locally using UserDefaults, keyed by connection identifier
enum SchemaPositionsStore {
  private static let storageKey = "app.schema.nodePositions"

  /// Generate a unique key for a database connection
  /// Format: "host:port/database"
  static func connectionKey(host: String, port: Int, database: String) -> String {
    "\(host):\(port)/\(database)"
  }

  /// Generate connection key from ConnectionConfig
  static func connectionKey(from config: ConnectionConfig) -> String {
    connectionKey(host: config.host, port: config.port, database: config.database)
  }

  /// Save positions for a specific database connection
  static func savePositions(_ positions: [SavedNodePosition], forConnection key: String) {
    var allPositions = loadAllPositions()

    // Convert positions to dictionary format
    let positionsData = positions.map { position in
      [
        "tableQualifiedName": position.tableQualifiedName,
        "x": position.x,
        "y": position.y,
      ] as [String: Any]
    }

    allPositions[key] = positionsData
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
}
