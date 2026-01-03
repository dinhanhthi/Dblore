//
//  DatabaseConnectionManager+Schema.swift
//  SQLNotebook
//
//  Schema introspection methods for DatabaseConnectionManager
//

import Foundation
import Logging
import PostgresNIO

extension DatabaseConnectionManager {
  // MARK: - Schema Introspection

  /// Fetch all tables from the database
  func fetchTables() async throws -> [DatabaseTable] {
    guard let connection = _connection else {
      throw DatabaseError.notConnected
    }

    let query = """
      SELECT
        table_schema,
        table_name
      FROM information_schema.tables
      WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        AND table_type = 'BASE TABLE'
      ORDER BY table_schema, table_name
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.schema")
      )

      var tables: [DatabaseTable] = []

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        guard let schemaCell = randomAccess.first,
          let nameCell = randomAccess.dropFirst().first,
          let schema = try? schemaCell.decode(String.self, context: .default),
          let name = try? nameCell.decode(String.self, context: .default)
        else {
          continue
        }

        tables.append(DatabaseTable(schema: schema, name: name))
      }

      return tables
    } catch {
      throw DatabaseError.queryFailed("Failed to fetch tables: \(error.localizedDescription)", 0)
    }
  }

  /// Fetch columns for a specific table
  func fetchColumns(tableSchema: String, tableName: String) async throws -> [DatabaseColumn] {
    guard let connection = _connection else {
      throw DatabaseError.notConnected
    }

    // Use string interpolation for now since parameter binding is complex with PostgresNIO
    let query = """
      SELECT
        column_name,
        data_type,
        is_nullable,
        column_default
      FROM information_schema.columns
      WHERE table_schema = '\(tableSchema)'
        AND table_name = '\(tableName)'
      ORDER BY ordinal_position
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.schema")
      )

      var columns: [DatabaseColumn] = []

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        let cells = Array(randomAccess)
        guard cells.count >= 3 else { continue }

        guard let columnName = try? cells[0].decode(String.self, context: .default),
          let dataType = try? cells[1].decode(String.self, context: .default),
          let isNullableStr = try? cells[2].decode(String.self, context: .default)
        else {
          continue
        }

        let isNullable = isNullableStr.uppercased() == "YES"

        // TODO: Detect primary keys from constraints (for now, set to false)
        let isPrimaryKey = false

        columns.append(
          DatabaseColumn(
            name: columnName,
            type: dataType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey
          )
        )
      }

      return columns
    } catch {
      throw DatabaseError.queryFailed(
        "Failed to fetch columns for \(tableSchema).\(tableName): \(error.localizedDescription)",
        0
      )
    }
  }

  /// Fetch row count for a specific table
  func fetchRowCount(tableSchema: String, tableName: String) async throws -> Int {
    guard let connection = _connection else {
      throw DatabaseError.notConnected
    }

    // Use COUNT(*) to get exact row count
    let query = """
      SELECT COUNT(*) as row_count
      FROM "\(tableSchema)".\"\(tableName)\"
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.schema")
      )

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        if let countCell = randomAccess.first,
          let count = try? countCell.decode(Int.self, context: .default)
        {
          return count
        }
      }

      return 0
    } catch {
      // If fetching row count fails, return 0 instead of throwing
      print("Failed to fetch row count for \(tableSchema).\(tableName): \(error)")
      return 0
    }
  }

  /// Fetch primary key column names for a table
  /// Returns array of column names that form the primary key (empty if no PK)
  func fetchPrimaryKeyColumns(tableName: String) async throws -> [String] {
    guard _connection != nil else {
      throw DatabaseError.notConnected
    }

    // Parse table name to handle schema.table format
    let parts = tableName.split(separator: ".")
    let schema: String
    let table: String

    if parts.count == 2 {
      schema = String(parts[0])
      table = String(parts[1])
    } else {
      schema = "public"
      table = tableName
    }

    // Query to get primary key columns from PostgreSQL system catalogs
    let pkQuery = """
      SELECT a.attname AS column_name
      FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
      WHERE i.indrelid = '\(schema).\(table)'::regclass
        AND i.indisprimary
      ORDER BY array_position(i.indkey, a.attnum)
      """

    do {
      let stream = try await _connection!.query(
        PostgresQuery(unsafeSQL: pkQuery),
        logger: Logger(label: "sqlnotebook.pk")
      )

      var pkColumns: [String] = []
      for try await row in stream {
        let randomAccess = row.makeRandomAccess()
        if let columnName = try? randomAccess[0].decode(String.self) {
          pkColumns.append(columnName)
        }
      }

      return pkColumns

    } catch {
      // If query fails (table doesn't exist, permissions, etc.), return empty array
      return []
    }
  }
}
