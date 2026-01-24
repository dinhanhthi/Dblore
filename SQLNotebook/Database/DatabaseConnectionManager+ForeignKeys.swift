//
//  DatabaseConnectionManager+ForeignKeys.swift
//  SQLNotebook
//
//  Foreign key introspection methods for DatabaseConnectionManager
//

import Foundation
import Logging
import PostgresNIO

extension DatabaseConnectionManager {
  // MARK: - Foreign Key Introspection

  /// Fetch all foreign key relationships from the database
  /// Queries pg_constraint system catalog for foreign key constraints
  func fetchForeignKeys() async throws -> [ForeignKey] {
    guard let connection = _connection else {
      throw DatabaseError.notConnected
    }

    // Query to get foreign key constraints with source and target column names
    // Uses pg_constraint, pg_class, pg_namespace, and pg_attribute catalogs
    let query = """
      SELECT
        c.conname AS constraint_name,
        ns.nspname AS source_schema,
        cl.relname AS source_table,
        nst.nspname AS target_schema,
        clt.relname AS target_table,
        c.confupdtype AS on_update,
        c.confdeltype AS on_delete,
        (
          SELECT array_agg(a.attname ORDER BY x.n)
          FROM pg_attribute a
          CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS x(attnum, n)
          WHERE a.attrelid = c.conrelid AND a.attnum = x.attnum
        ) AS source_columns,
        (
          SELECT array_agg(a.attname ORDER BY x.n)
          FROM pg_attribute a
          CROSS JOIN LATERAL unnest(c.confkey) WITH ORDINALITY AS x(attnum, n)
          WHERE a.attrelid = c.confrelid AND a.attnum = x.attnum
        ) AS target_columns
      FROM pg_constraint c
      JOIN pg_class cl ON c.conrelid = cl.oid
      JOIN pg_namespace ns ON cl.relnamespace = ns.oid
      JOIN pg_class clt ON c.confrelid = clt.oid
      JOIN pg_namespace nst ON clt.relnamespace = nst.oid
      WHERE c.contype = 'f'
        AND ns.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      ORDER BY ns.nspname, cl.relname, c.conname
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.foreignkeys")
      )

      var foreignKeys: [ForeignKey] = []

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()
        let cells = Array(randomAccess)

        // Expected columns: constraint_name, source_schema, source_table,
        // target_schema, target_table, on_update, on_delete, source_columns, target_columns
        guard cells.count >= 9 else { continue }

        // Decode basic fields
        guard
          let constraintName = try? cells[0].decode(String.self, context: .default),
          let sourceSchema = try? cells[1].decode(String.self, context: .default),
          let sourceTable = try? cells[2].decode(String.self, context: .default),
          let targetSchema = try? cells[3].decode(String.self, context: .default),
          let targetTable = try? cells[4].decode(String.self, context: .default)
        else {
          continue
        }

        // Decode action codes (single character strings)
        let onUpdateCode = (try? cells[5].decode(String.self, context: .default)) ?? "a"
        let onDeleteCode = (try? cells[6].decode(String.self, context: .default)) ?? "a"

        // Decode column arrays - PostgreSQL returns these as text arrays
        // Try to decode as String array, fallback to String and parse
        var sourceColumns: [String] = []
        var targetColumns: [String] = []

        if let srcArray = try? cells[7].decode([String].self, context: .default) {
          sourceColumns = srcArray
        } else if let srcString = try? cells[7].decode(String.self, context: .default) {
          sourceColumns = parsePostgresArray(srcString)
        }

        if let tgtArray = try? cells[8].decode([String].self, context: .default) {
          targetColumns = tgtArray
        } else if let tgtString = try? cells[8].decode(String.self, context: .default) {
          targetColumns = parsePostgresArray(tgtString)
        }

        // Skip if no columns found
        guard !sourceColumns.isEmpty, !targetColumns.isEmpty else { continue }

        let foreignKey = ForeignKey(
          constraintName: constraintName,
          sourceSchema: sourceSchema,
          sourceTable: sourceTable,
          sourceColumns: sourceColumns,
          targetSchema: targetSchema,
          targetTable: targetTable,
          targetColumns: targetColumns,
          onUpdate: ForeignKeyAction(pgCode: onUpdateCode),
          onDelete: ForeignKeyAction(pgCode: onDeleteCode)
        )

        foreignKeys.append(foreignKey)
      }

      return foreignKeys
    } catch {
      throw DatabaseError.queryFailed(
        "Failed to fetch foreign keys: \(error.localizedDescription)", 0)
    }
  }

  /// Parse PostgreSQL array string format: {val1,val2,val3}
  private func parsePostgresArray(_ arrayString: String) -> [String] {
    var str = arrayString.trimmingCharacters(in: .whitespaces)

    // Remove curly braces
    if str.hasPrefix("{") { str.removeFirst() }
    if str.hasSuffix("}") { str.removeLast() }

    // Handle empty array
    if str.isEmpty { return [] }

    // Split by comma, handling quoted values
    var result: [String] = []
    var current = ""
    var inQuotes = false

    for char in str {
      if char == "\"" {
        inQuotes.toggle()
      } else if char == "," && !inQuotes {
        result.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      } else {
        current.append(char)
      }
    }

    // Add last element
    if !current.isEmpty {
      result.append(current.trimmingCharacters(in: .whitespaces))
    }

    return result
  }
}
