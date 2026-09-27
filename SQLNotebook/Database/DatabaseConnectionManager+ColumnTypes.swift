//
//  DatabaseConnectionManager+ColumnTypes.swift
//  SQLNotebook
//
//  Column type enrichment (precision, scale, length) from information_schema
//

import Foundation
import Logging
import PostgresNIO

extension DatabaseConnectionManager {
  // MARK: - Column Type Enrichment

  /// Enrich column type information with modifiers (precision, scale, length)
  /// Uses information_schema to get detailed type info. Skipped (driver types kept) while the
  /// app transaction is pending: a failing catalog query would abort it.
  func enrichColumnTypes(columns: [ColumnInfo], query: String) async -> [ColumnInfo] {
    // Only proceed if we have columns and connection
    guard !columns.isEmpty, !isMetadataPaused, let connection = _connection,
      databaseType == .postgresql
    else {
      return columns
    }

    // Try to extract table name from query (simple SELECT from single table)
    guard let tableName = extractSingleTableName(query) else {
      return columns
    }

    do {
      // Build IN clause with column names
      let columnNames = columns.map { "'\($0.name)'" }.joined(separator: ", ")

      // Query information_schema to get detailed column types
      // Include udt_name to handle user-defined types (e.g., pgvector's vector type)
      let typeQuery = """
        SELECT column_name, data_type,
               character_maximum_length,
               numeric_precision,
               numeric_scale,
               datetime_precision,
               interval_type,
               udt_name
        FROM information_schema.columns
        WHERE table_name = '\(tableName)'
          AND column_name IN (\(columnNames))
        """

      let stream = try await send(on: connection) {
        try await $0.query(
          PostgresQuery(unsafeSQL: typeQuery),
          logger: Logger(label: "sqlnotebook.typeinfo")
        )
      }

      // Collect type information
      var typeMap: [String: String] = [:]

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()
        guard randomAccess.count >= 8 else { continue }

        // Extract values
        var cellValues: [PostgresCell] = []
        for cell in randomAccess {
          cellValues.append(cell)
        }

        guard let columnName = try? cellValues[0].decode(String.self, context: .default),
          let dataType = try? cellValues[1].decode(String.self, context: .default)
        else {
          continue
        }

        // Build detailed type string
        var detailedType = dataType.uppercased()

        // For user-defined types, use udt_name instead of "USER-DEFINED"
        if detailedType == "USER-DEFINED" {
          if let udtName = try? cellValues[7].decode(String.self, context: .default) {
            detailedType = udtName.uppercased()
          }
        }

        // Add length for character types
        if let maxLength = try? cellValues[2].decode(Int.self, context: .default) {
          detailedType += "(\(maxLength))"
        }
        // Add precision and scale for numeric types
        else if let precision = try? cellValues[3].decode(Int.self, context: .default) {
          if let scale = try? cellValues[4].decode(Int.self, context: .default) {
            detailedType += "(\(precision),\(scale))"
          } else {
            detailedType += "(\(precision))"
          }
        }
        // Add precision for datetime types
        else if let datetimePrecision = try? cellValues[5].decode(Int.self, context: .default) {
          // For timestamp types, check if it's WITH/WITHOUT TIME ZONE
          if dataType.uppercased().contains("TIMESTAMP") {
            if dataType.uppercased().contains("WITH TIME ZONE") {
              detailedType = "TIMESTAMP(\(datetimePrecision)) W TZ"
            } else {
              detailedType = "TIMESTAMP(\(datetimePrecision)) W/O TZ"
            }
          }
        }

        typeMap[columnName] = detailedType
      }

      // Update columns with enriched type info
      return columns.map { column in
        if let enrichedType = typeMap[column.name] {
          return ColumnInfo(
            name: column.name, type: enrichedType, tableOID: column.tableOID,
            attributeNumber: column.attributeNumber)
        }
        return column
      }

    } catch {
      // If enrichment fails, return original columns
      await AppLogger.shared.warning(
        "Failed to enrich column types: \(error)", category: "Database")
      return columns
    }
  }
}
