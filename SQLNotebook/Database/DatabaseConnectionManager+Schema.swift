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

    // First, fetch primary key columns for this table
    let primaryKeyColumns = try await fetchPrimaryKeyColumns(
      tableName: "\(tableSchema).\(tableName)")

    // Use string interpolation for now since parameter binding is complex with PostgresNIO
    // Include additional columns for type enrichment
    let query = """
      SELECT
        column_name,
        data_type,
        is_nullable,
        column_default,
        character_maximum_length,
        numeric_precision,
        numeric_scale,
        datetime_precision
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

        // Check if this column is a primary key
        let isPrimaryKey = primaryKeyColumns.contains(columnName)

        // Build enriched type string with precision/scale/length
        var enrichedType = dataType.uppercased()

        // Add length for character types (VARCHAR, CHAR)
        if cells.count > 4, let maxLength = try? cells[4].decode(Int.self, context: .default) {
          enrichedType += "(\(maxLength))"
        }
        // Add precision and scale for numeric types
        else if cells.count > 6,
          let precision = try? cells[5].decode(Int.self, context: .default)
        {
          if let scale = try? cells[6].decode(Int.self, context: .default) {
            enrichedType += "(\(precision),\(scale))"
          } else {
            enrichedType += "(\(precision))"
          }
        }
        // Add precision for datetime types
        else if cells.count > 7,
          let datetimePrecision = try? cells[7].decode(Int.self, context: .default)
        {
          // For timestamp types, check if it's WITH/WITHOUT TIME ZONE
          if dataType.uppercased().contains("TIMESTAMP") {
            if dataType.uppercased().contains("WITH TIME ZONE") {
              enrichedType = "TIMESTAMP(\(datetimePrecision)) W TZ"
            } else {
              enrichedType = "TIMESTAMP(\(datetimePrecision)) W/O TZ"
            }
          }
        }

        columns.append(
          DatabaseColumn(
            name: columnName,
            type: enrichedType,
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
      await AppLogger.shared.warning(
        "Failed to fetch row count for \(tableSchema).\(tableName): \(error)", category: "Schema")
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

  // MARK: - Views

  /// Fetch all views from the database
  func fetchViews() async throws -> [DatabaseView] {
    guard let connection = _connection else {
      throw DatabaseError.notConnected
    }

    let query = """
      SELECT
        table_schema,
        table_name,
        view_definition
      FROM information_schema.views
      WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
      ORDER BY table_schema, table_name
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.schema")
      )

      var views: [DatabaseView] = []

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        guard randomAccess.count >= 2,
          let schema = try? randomAccess[0].decode(String.self, context: .default),
          let name = try? randomAccess[1].decode(String.self, context: .default)
        else {
          continue
        }

        let definition = try? randomAccess[2].decode(String.self, context: .default)

        views.append(DatabaseView(schema: schema, name: name, definition: definition))
      }

      return views
    } catch {
      throw DatabaseError.queryFailed("Failed to fetch views: \(error.localizedDescription)", 0)
    }
  }

  // MARK: - Functions

  /// Fetch all functions from the database
  func fetchFunctions() async throws -> [DatabaseFunction] {
    guard let connection = _connection else {
      throw DatabaseError.notConnected
    }

    let query = """
      SELECT
        n.nspname AS schema,
        p.proname AS name,
        pg_get_function_result(p.oid) AS return_type,
        pg_get_function_arguments(p.oid) AS arguments,
        pg_get_functiondef(p.oid) AS definition
      FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND p.prokind = 'f'
      ORDER BY n.nspname, p.proname
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.schema")
      )

      var functions: [DatabaseFunction] = []

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        guard randomAccess.count >= 4,
          let schema = try? randomAccess[0].decode(String.self, context: .default),
          let name = try? randomAccess[1].decode(String.self, context: .default),
          let returnType = try? randomAccess[2].decode(String.self, context: .default),
          let arguments = try? randomAccess[3].decode(String.self, context: .default)
        else {
          continue
        }

        let definition = try? randomAccess[4].decode(String.self, context: .default)

        functions.append(
          DatabaseFunction(
            schema: schema,
            name: name,
            returnType: returnType,
            arguments: arguments,
            definition: definition
          )
        )
      }

      return functions
    } catch {
      throw DatabaseError.queryFailed(
        "Failed to fetch functions: \(error.localizedDescription)", 0)
    }
  }

  // MARK: - Procedures

  /// Fetch all procedures from the database
  func fetchProcedures() async throws -> [DatabaseProcedure] {
    guard let connection = _connection else {
      throw DatabaseError.notConnected
    }

    let query = """
      SELECT
        n.nspname AS schema,
        p.proname AS name,
        pg_get_function_arguments(p.oid) AS arguments,
        pg_get_functiondef(p.oid) AS definition
      FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND p.prokind = 'p'
      ORDER BY n.nspname, p.proname
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.schema")
      )

      var procedures: [DatabaseProcedure] = []

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        guard randomAccess.count >= 3,
          let schema = try? randomAccess[0].decode(String.self, context: .default),
          let name = try? randomAccess[1].decode(String.self, context: .default),
          let arguments = try? randomAccess[2].decode(String.self, context: .default)
        else {
          continue
        }

        let definition = try? randomAccess[3].decode(String.self, context: .default)

        procedures.append(
          DatabaseProcedure(
            schema: schema,
            name: name,
            arguments: arguments,
            definition: definition
          )
        )
      }

      return procedures
    } catch {
      throw DatabaseError.queryFailed(
        "Failed to fetch procedures: \(error.localizedDescription)", 0)
    }
  }

  // MARK: - Users

  /// Fetch all users from the database
  func fetchUsers() async throws -> [DatabaseUser] {
    guard let connection = _connection else {
      throw DatabaseError.notConnected
    }

    let query = """
      SELECT
        rolname,
        rolcanlogin,
        rolsuper,
        rolcreatedb,
        rolcreaterole,
        rolconnlimit
      FROM pg_roles
      WHERE rolcanlogin = true
      ORDER BY rolname
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.schema")
      )

      var users: [DatabaseUser] = []

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        guard randomAccess.count >= 6,
          let name = try? randomAccess[0].decode(String.self, context: .default),
          let canLogin = try? randomAccess[1].decode(Bool.self, context: .default),
          let isSuperuser = try? randomAccess[2].decode(Bool.self, context: .default),
          let canCreateDB = try? randomAccess[3].decode(Bool.self, context: .default),
          let canCreateRole = try? randomAccess[4].decode(Bool.self, context: .default)
        else {
          continue
        }

        let connectionLimit = try? randomAccess[5].decode(Int.self, context: .default)

        users.append(
          DatabaseUser(
            name: name,
            canLogin: canLogin,
            isSuperuser: isSuperuser,
            canCreateDB: canCreateDB,
            canCreateRole: canCreateRole,
            connectionLimit: connectionLimit
          )
        )
      }

      return users
    } catch {
      throw DatabaseError.queryFailed("Failed to fetch users: \(error.localizedDescription)", 0)
    }
  }

  // MARK: - Roles

  /// Fetch all roles from the database
  func fetchRoles() async throws -> [DatabaseRole] {
    guard let connection = _connection else {
      throw DatabaseError.notConnected
    }

    let query = """
      SELECT
        r.rolname,
        r.rolcanlogin,
        r.rolsuper,
        r.rolcreatedb,
        r.rolcreaterole,
        ARRAY(
          SELECT m.rolname
          FROM pg_auth_members am
          JOIN pg_roles m ON am.member = m.oid
          WHERE am.roleid = r.oid
        ) AS members
      FROM pg_roles r
      WHERE r.rolcanlogin = false
      ORDER BY r.rolname
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.schema")
      )

      var roles: [DatabaseRole] = []

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        guard randomAccess.count >= 6,
          let name = try? randomAccess[0].decode(String.self, context: .default),
          let canLogin = try? randomAccess[1].decode(Bool.self, context: .default),
          let isSuperuser = try? randomAccess[2].decode(Bool.self, context: .default),
          let canCreateDB = try? randomAccess[3].decode(Bool.self, context: .default),
          let canCreateRole = try? randomAccess[4].decode(Bool.self, context: .default)
        else {
          continue
        }

        // Try to decode members array (might be empty)
        let members = (try? randomAccess[5].decode([String].self, context: .default)) ?? []

        roles.append(
          DatabaseRole(
            name: name,
            canLogin: canLogin,
            isSuperuser: isSuperuser,
            canCreateDB: canCreateDB,
            canCreateRole: canCreateRole,
            members: members
          )
        )
      }

      return roles
    } catch {
      throw DatabaseError.queryFailed("Failed to fetch roles: \(error.localizedDescription)", 0)
    }
  }
}
