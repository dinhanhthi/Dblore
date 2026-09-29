//
//  DatabaseConnectionManager+Schema.swift
//  Dblore
//
//  Schema introspection methods for DatabaseConnectionManager
//

import Foundation
import Logging
import PostgresNIO

extension DatabaseConnectionManager {
  // MARK: - Schema Introspection

  /// Relation-level visibility, equivalent to what information_schema applies to tables and views
  private static let relationPrivilegeFilter = """
    (pg_has_role(c.relowner, 'USAGE')
      OR has_table_privilege(c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
      OR has_any_column_privilege(c.oid, 'SELECT, INSERT, UPDATE, REFERENCES'))
    """

  /// information_schema hides other sessions' temporary tables (unreadable for this session)
  private static let hideOtherTempSchemas = "NOT pg_is_other_temp_schema(n.oid)"

  /// Column-level visibility, as information_schema.columns applies it: a column is listed only
  /// with a privilege on that column (or ownership through a role), not on any other column
  private static let columnPrivilegeFilter = """
    (pg_has_role(c.relowner, 'USAGE')
      OR has_column_privilege(c.oid, a.attnum, 'SELECT, INSERT, UPDATE, REFERENCES'))
    """

  /// Fetch all tables from the database (row count is the planner estimate, nil if never analyzed)
  func fetchTables() async throws -> [DatabaseTable] {
    let connection = try catalogConnection()

    let query = """
      SELECT
        n.nspname::text,
        c.relname::text,
        CASE WHEN c.reltuples < 0 OR (c.reltuples = 0 AND c.relpages = 0)
          THEN NULL ELSE c.reltuples::bigint END AS row_estimate
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind IN ('r', 'p')
        AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        AND \(Self.hideOtherTempSchemas)
        AND \(Self.relationPrivilegeFilter)
      ORDER BY n.nspname, c.relname
      """

    do {
      let stream = try await send(on: connection) {
        try await $0.query(
          PostgresQuery(unsafeSQL: query), logger: Logger(label: "dblore.schema"))
      }

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

        let estimate = try? randomAccess[2].decode(Int?.self, context: .default)
        tables.append(DatabaseTable(schema: schema, name: name, rowCount: estimate ?? nil))
      }

      return tables
    } catch {
      throw DatabaseError.queryFailed("Failed to fetch tables: \(error.localizedDescription)", 0)
    }
  }

  /// Fetch the columns of every table and view in one query, keyed by "schema.relation"
  func fetchAllColumns() async throws -> [String: [DatabaseColumn]] {
    let connection = try catalogConnection()

    let query = """
      SELECT
        n.nspname::text,
        c.relname::text,
        a.attname::text,
        format_type(a.atttypid, a.atttypmod),
        a.attnotnull,
        (a.attidentity <> '') AS is_identity,
        EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY(i.indkey)
        ) AS is_pk,
        EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.oid AND i.indisunique AND NOT i.indisprimary
            AND array_length(i.indkey, 1) = 1 AND a.attnum = ANY(i.indkey)
        ) AS is_unique
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind IN ('r', 'p', 'v')
        AND a.attnum > 0 AND NOT a.attisdropped
        AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        AND \(Self.hideOtherTempSchemas)
        AND \(Self.columnPrivilegeFilter)
      ORDER BY n.nspname, c.relname, a.attnum
      """

    do {
      let stream = try await send(on: connection) {
        try await $0.query(
          PostgresQuery(unsafeSQL: query), logger: Logger(label: "dblore.schema"))
      }

      var rows: [SchemaCatalog.ColumnRow] = []
      for try await row in stream {
        let cells = Array(row.makeRandomAccess())
        guard cells.count >= 8,
          let schema = try? cells[0].decode(String.self, context: .default),
          let relation = try? cells[1].decode(String.self, context: .default),
          let name = try? cells[2].decode(String.self, context: .default),
          let formatType = try? cells[3].decode(String.self, context: .default),
          let notNull = try? cells[4].decode(Bool.self, context: .default),
          let isIdentity = try? cells[5].decode(Bool.self, context: .default),
          let isPK = try? cells[6].decode(Bool.self, context: .default),
          let isUnique = try? cells[7].decode(Bool.self, context: .default)
        else {
          continue
        }
        rows.append(
          SchemaCatalog.ColumnRow(
            schema: schema, relation: relation, name: name, formatType: formatType,
            notNull: notNull, isIdentity: isIdentity, isPK: isPK, isUnique: isUnique))
      }
      return SchemaCatalog.columnsByRelation(rows)
    } catch {
      throw DatabaseError.queryFailed("Failed to fetch columns: \(error.localizedDescription)", 0)
    }
  }

  /// Fetch row count for a specific table
  func fetchRowCount(tableSchema: String, tableName: String) async throws -> Int {
    let connection = try catalogConnection()

    // Use COUNT(*) to get exact row count
    let query = """
      SELECT COUNT(*) as row_count
      FROM "\(tableSchema)".\"\(tableName)\"
      """

    do {
      let stream = try await send(on: connection) {
        try await $0.query(
          PostgresQuery(unsafeSQL: query), logger: Logger(label: "dblore.schema"))
      }

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

  /// Fetch primary key column names for a table, in key order (empty if no PK).
  /// `tableName` (`table` or `schema.table`, SQL identifier syntax) is resolved with
  /// `to_regclass` like an unqualified name in a query (search_path) and bound as a parameter.
  func fetchPrimaryKeyColumns(tableName: String) async throws -> [String] {
    let connection = try catalogConnection()

    var binds = PostgresBindings(capacity: 1)
    binds.append(tableName)
    let pkQuery = PostgresQuery(
      unsafeSQL: """
        SELECT a.attname::text AS column_name
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = to_regclass($1)
          AND i.indisprimary
        ORDER BY array_position(i.indkey, a.attnum)
        """, binds: binds)

    do {
      let stream = try await send(on: connection) {
        try await $0.query(pkQuery, logger: Logger(label: "dblore.pk"))
      }

      var pkColumns: [String] = []
      for try await row in stream {
        let randomAccess = row.makeRandomAccess()
        if let columnName = try? randomAccess[0].decode(String.self) {
          pkColumns.append(columnName)
        }
      }

      return pkColumns

    } catch {
      // If query fails (invalid name, permissions, etc.), return empty array
      return []
    }
  }

  // MARK: - Views

  /// Fetch all views from the database
  func fetchViews() async throws -> [DatabaseView] {
    let connection = try catalogConnection()

    let query = """
      SELECT n.nspname::text, c.relname::text
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'v'
        AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND \(Self.hideOtherTempSchemas)
        AND \(Self.relationPrivilegeFilter)
      ORDER BY n.nspname, c.relname
      """

    do {
      let stream = try await send(on: connection) {
        try await $0.query(
          PostgresQuery(unsafeSQL: query), logger: Logger(label: "dblore.schema"))
      }

      var views: [DatabaseView] = []

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        guard randomAccess.count >= 2,
          let schema = try? randomAccess[0].decode(String.self, context: .default),
          let name = try? randomAccess[1].decode(String.self, context: .default)
        else {
          continue
        }

        views.append(DatabaseView(schema: schema, name: name, definition: nil))
      }

      return views
    } catch {
      throw DatabaseError.queryFailed("Failed to fetch views: \(error.localizedDescription)", 0)
    }
  }

  // MARK: - Functions

  /// Fetch all functions from the database
  func fetchFunctions() async throws -> [DatabaseFunction] {
    let connection = try catalogConnection()

    let query = """
      SELECT
        n.nspname AS schema,
        p.proname AS name,
        pg_get_function_result(p.oid) AS return_type,
        pg_get_function_arguments(p.oid) AS arguments
      FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND p.prokind = 'f'
      ORDER BY n.nspname, p.proname
      """

    do {
      let stream = try await send(on: connection) {
        try await $0.query(
          PostgresQuery(unsafeSQL: query), logger: Logger(label: "dblore.schema"))
      }

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

        functions.append(
          DatabaseFunction(
            schema: schema,
            name: name,
            returnType: returnType,
            arguments: arguments,
            definition: nil
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
    let connection = try catalogConnection()

    let query = """
      SELECT
        n.nspname AS schema,
        p.proname AS name,
        pg_get_function_arguments(p.oid) AS arguments
      FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND p.prokind = 'p'
      ORDER BY n.nspname, p.proname
      """

    do {
      let stream = try await send(on: connection) {
        try await $0.query(
          PostgresQuery(unsafeSQL: query), logger: Logger(label: "dblore.schema"))
      }

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

        procedures.append(
          DatabaseProcedure(
            schema: schema,
            name: name,
            arguments: arguments,
            definition: nil
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
    let connection = try catalogConnection()

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
      let stream = try await send(on: connection) {
        try await $0.query(
          PostgresQuery(unsafeSQL: query), logger: Logger(label: "dblore.schema"))
      }

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
    let connection = try catalogConnection()

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
      let stream = try await send(on: connection) {
        try await $0.query(
          PostgresQuery(unsafeSQL: query), logger: Logger(label: "dblore.schema"))
      }

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
