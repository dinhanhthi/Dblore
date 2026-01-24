//
//  ForeignKey.swift
//  SQLNotebook
//

import Foundation

/// Action to perform on foreign key constraint violation
enum ForeignKeyAction: String, Sendable, Codable, CaseIterable {
  case noAction = "a"
  case restrict = "r"
  case cascade = "c"
  case setNull = "n"
  case setDefault = "d"

  /// Human-readable display name
  var displayName: String {
    switch self {
    case .noAction: return "NO ACTION"
    case .restrict: return "RESTRICT"
    case .cascade: return "CASCADE"
    case .setNull: return "SET NULL"
    case .setDefault: return "SET DEFAULT"
    }
  }

  /// Initialize from PostgreSQL confupdtype/confdeltype character
  nonisolated init(pgCode: String) {
    self = ForeignKeyAction(rawValue: pgCode) ?? .noAction
  }
}

/// Represents a foreign key relationship between two tables
struct ForeignKey: Identifiable, Sendable {
  let id: UUID
  let constraintName: String
  let sourceSchema: String
  let sourceTable: String
  let sourceColumns: [String]
  let targetSchema: String
  let targetTable: String
  let targetColumns: [String]
  let onUpdate: ForeignKeyAction
  let onDelete: ForeignKeyAction

  nonisolated init(
    id: UUID = UUID(),
    constraintName: String,
    sourceSchema: String,
    sourceTable: String,
    sourceColumns: [String],
    targetSchema: String,
    targetTable: String,
    targetColumns: [String],
    onUpdate: ForeignKeyAction = .noAction,
    onDelete: ForeignKeyAction = .noAction
  ) {
    self.id = id
    self.constraintName = constraintName
    self.sourceSchema = sourceSchema
    self.sourceTable = sourceTable
    self.sourceColumns = sourceColumns
    self.targetSchema = targetSchema
    self.targetTable = targetTable
    self.targetColumns = targetColumns
    self.onUpdate = onUpdate
    self.onDelete = onDelete
  }

  /// Full qualified name of source table: schema.table
  var sourceQualifiedName: String {
    "\(sourceSchema).\(sourceTable)"
  }

  /// Full qualified name of target table: schema.table
  var targetQualifiedName: String {
    "\(targetSchema).\(targetTable)"
  }

  /// Display string for the relationship
  var displayString: String {
    let srcCols = sourceColumns.joined(separator: ", ")
    let tgtCols = targetColumns.joined(separator: ", ")
    return "\(sourceTable)(\(srcCols)) → \(targetTable)(\(tgtCols))"
  }

  /// Check if this is a self-referencing foreign key
  var isSelfReferencing: Bool {
    sourceSchema == targetSchema && sourceTable == targetTable
  }
}
