//
//  SchemaCatalog.swift
//  SQLNotebook
//
//  Pure mapping of bulk pg_catalog column rows into DatabaseColumn values
//

import Foundation

/// Namespace for turning one bulk pg_attribute result into per-relation column lists
enum SchemaCatalog {
  /// One row of the bulk column query (one column of one table or view)
  struct ColumnRow: Sendable {
    let schema: String
    let relation: String
    let name: String
    /// Output of `format_type(atttypid, atttypmod)`
    let formatType: String
    let notNull: Bool
    let isIdentity: Bool
    let isPK: Bool
    let isUnique: Bool

    nonisolated init(
      schema: String,
      relation: String,
      name: String,
      formatType: String,
      notNull: Bool,
      isIdentity: Bool,
      isPK: Bool,
      isUnique: Bool
    ) {
      self.schema = schema
      self.relation = relation
      self.name = name
      self.formatType = formatType
      self.notNull = notNull
      self.isIdentity = isIdentity
      self.isPK = isPK
      self.isUnique = isUnique
    }
  }

  /// Uppercases a `format_type` string and shortens the time zone suffixes.
  /// User-defined type names (`public.mood`, `"MyType"`) are uppercased as-is.
  nonisolated static func displayType(formatType: String) -> String {
    formatType.uppercased()
      .replacingOccurrences(of: " WITHOUT TIME ZONE", with: " W/O TZ")
      .replacingOccurrences(of: " WITH TIME ZONE", with: " W TZ")
  }

  /// Groups rows by `"schema.relation"` (same format as `DatabaseTable.qualifiedName`),
  /// keeping input (attnum) order within each relation.
  nonisolated static func columnsByRelation(_ rows: [ColumnRow]) -> [String: [DatabaseColumn]] {
    var result: [String: [DatabaseColumn]] = [:]
    for row in rows {
      result["\(row.schema).\(row.relation)", default: []].append(
        DatabaseColumn(
          name: row.name,
          type: displayType(formatType: row.formatType),
          isNullable: !row.notNull,
          isPrimaryKey: row.isPK,
          isIdentity: row.isIdentity,
          isUnique: row.isUnique && !row.isPK
        ))
    }
    return result
  }
}
