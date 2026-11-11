// SQLServerCatalog.swift
// Catalog reads of the SQL Server engine, from the current database's sys.* views: tables (row
// counts from sys.partitions, an estimate), views, functions and procedures with their
// parameters, triggers, definitions (OBJECT_DEFINITION), foreign keys, columns, the edit target,
// primary keys, exact row counts and table structure (columns, defaults, identity, computed
// columns, indexes, key, foreign-key and check constraints, MS_Description comments), and the
// origins of a result's columns (`enrichColumnTypes`, from a describe of its first result set).
// Objects Microsoft ships are left out. Users and roles answer `unsupported`, which the app reads
// as empty.
//
// Names from the app go in as binds (`@p1`, ...), never into the SQL text; only the row count
// quotes them, as bracket identifiers.

import Foundation

struct SQLServerCatalog {
  /// Bytes of view definitions sent with the view list; views past it go without one, so the
  /// list stays under the 1 MiB event limit
  static let viewDefinitionBudget = 512 << 10

  static let functionTypes = "('FN', 'IF', 'TF', 'FS', 'FT')"
  static let procedureTypes = "('P', 'PC')"

  let connection: SQLServerConnection

  func read(_ request: EngineRequest.Catalog) throws -> EngineCatalogResult {
    switch request.read {
    case .tables: return .tables(try tables())
    case .views: return .views(try views())
    case .functions: return .functions(try routines(Self.functionTypes).map(\.function))
    case .procedures: return .procedures(try routines(Self.procedureTypes).map(\.procedure))
    case .triggers: return .triggers(try triggers())
    case .definition:
      return .definition(
        try definition(
          schema: try Self.string(request.args, "schema"),
          name: try Self.string(request.args, "name")))
    case .foreignKeys: return .foreignKeys(try foreignKeys(of: nil))
    case .allColumns: return .allColumns(try allColumns())
    case .editTable:
      let (schema, table) = try Self.qualifiedName(request.args)
      return .editTable(try editTable(schema: schema, table: table))
    case .primaryKey:
      let (schema, table) = try Self.qualifiedName(request.args)
      guard let object = try object(schema: schema, name: table, types: "('U', 'V')") else {
        return .primaryKey([])
      }
      return .primaryKey(try primaryKey(of: object.id))
    case .rowCount:
      return .rowCount(
        try rowCount(
          schema: try Self.string(request.args, "schema"),
          table: try Self.string(request.args, "table")))
    case .tableStructure:
      return .tableStructure(
        try tableStructure(
          schema: try Self.string(request.args, "schema"),
          table: try Self.string(request.args, "table")))
    case .enrichColumnTypes:
      guard let columns = SQLServerTypes.requestColumns(request.args["columns"]) else {
        throw EngineFailure(code: .invalid, message: "The catalog request has malformed columns.")
      }
      return .enrichColumnTypes(
        originColumns(columns, query: try Self.string(request.args, "query")))
    default:
      throw EngineFailure(
        code: .unsupported, message: "This catalog read is not supported by SQL Server.")
    }
  }

  // MARK: Lists

  private func tables() throws -> [EngineCatalog.Table] {
    try connection.rows(
      """
      SELECT s.name, t.name, CAST(ISNULL(SUM(p.rows), 0) AS bigint)
      FROM sys.tables AS t
      JOIN sys.schemas AS s ON s.schema_id = t.schema_id
      LEFT JOIN sys.partitions AS p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
      WHERE t.is_ms_shipped = 0
      GROUP BY s.name, t.name
      ORDER BY s.name, t.name
      """
    ).compactMap { row in
      guard let schema = Self.text(row, 0), let name = Self.text(row, 1) else { return nil }
      return EngineCatalog.Table(schema: schema, name: name, rowCount: Self.int(row, 2))
    }
  }

  private func views() throws -> [EngineCatalog.View] {
    var budget = Self.viewDefinitionBudget
    return try connection.rows(
      """
      SELECT s.name, v.name, OBJECT_DEFINITION(v.object_id)
      FROM sys.views AS v
      JOIN sys.schemas AS s ON s.schema_id = v.schema_id
      WHERE v.is_ms_shipped = 0
      ORDER BY s.name, v.name
      """
    ).compactMap { row in
      guard let schema = Self.text(row, 0), let name = Self.text(row, 1) else { return nil }
      var definition = Self.text(row, 2).flatMap { $0.isEmpty ? nil : $0 }
      if let text = definition {
        let bytes = text.utf8.count
        if bytes <= budget { budget -= bytes } else { definition = nil }
      }
      return EngineCatalog.View(schema: schema, name: name, definition: definition)
    }
  }

  /// A function or procedure with its parameters
  private struct Routine {
    let schema: String
    let name: String
    let type: String
    var returnType: String?
    var parameters: [String] = []

    var arguments: String { parameters.joined(separator: ", ") }

    var function: EngineCatalog.Function {
      // Inline and multi-statement table-valued functions return a table
      let table = ["IF", "TF", "FT"].contains(type)
      return EngineCatalog.Function(
        schema: schema, name: name, returnType: table ? "TABLE" : returnType,
        arguments: arguments)
    }

    var procedure: EngineCatalog.Procedure {
      EngineCatalog.Procedure(schema: schema, name: name, arguments: arguments)
    }
  }

  /// Functions or procedures (`types`, a fixed list of sys.objects types) with their parameters
  private func routines(_ types: String) throws -> [Routine] {
    let rows = try connection.rows(
      """
      SELECT s.name, o.name, o.type, p.parameter_id, p.name, TYPE_NAME(p.user_type_id),
        p.max_length, p.precision, p.scale, p.is_output
      FROM sys.objects AS o
      JOIN sys.schemas AS s ON s.schema_id = o.schema_id
      LEFT JOIN sys.parameters AS p ON p.object_id = o.object_id
      WHERE o.type IN \(types) AND o.is_ms_shipped = 0
      ORDER BY s.name, o.name, p.parameter_id
      """)
    var routines: [Routine] = []
    for row in rows {
      guard let schema = Self.text(row, 0), let name = Self.text(row, 1) else { continue }
      if routines.last.map({ $0.schema != schema || $0.name != name }) ?? true {
        let type = (Self.text(row, 2) ?? "").trimmingCharacters(in: .whitespaces)
        routines.append(Routine(schema: schema, name: name, type: type))
      }
      guard let id = Self.int(row, 3), let typeName = Self.text(row, 5) else { continue }
      let type = SQLServerTypes.displayType(
        name: typeName, maxLength: Self.int(row, 6) ?? 0, precision: Self.int(row, 7) ?? 0,
        scale: Self.int(row, 8) ?? 0)
      if id == 0 {
        routines[routines.count - 1].returnType = type
      } else {
        let output = Self.bool(row, 9) == true ? " OUTPUT" : ""
        routines[routines.count - 1].parameters.append(
          "\(Self.text(row, 4) ?? "") \(type)\(output)")
      }
    }
    return routines
  }

  private func triggers() throws -> [EngineCatalog.Trigger] {
    let rows = try connection.rows(
      """
      SELECT s.name, t.name, tr.name, tr.is_instead_of_trigger, tr.is_disabled, te.type_desc
      FROM sys.triggers AS tr
      JOIN sys.objects AS t ON t.object_id = tr.parent_id
      JOIN sys.schemas AS s ON s.schema_id = t.schema_id
      LEFT JOIN sys.trigger_events AS te ON te.object_id = tr.object_id
      WHERE tr.parent_class = 1 AND tr.is_ms_shipped = 0
      ORDER BY s.name, t.name, tr.name
      """)
    var triggers: [EngineCatalog.Trigger] = []
    for row in rows {
      guard let schema = Self.text(row, 0), let table = Self.text(row, 1),
        let name = Self.text(row, 2)
      else { continue }
      let last = triggers.last
      if last == nil || last?.schema != schema || last?.table != table || last?.name != name {
        triggers.append(
          EngineCatalog.Trigger(
            schema: schema, table: table, name: name,
            timing: Self.bool(row, 3) == true ? "INSTEAD OF" : "AFTER", events: [],
            enabled: Self.bool(row, 4) != true))
      }
      if let event = Self.text(row, 5) {
        let current = triggers.removeLast()
        triggers.append(
          EngineCatalog.Trigger(
            schema: current.schema, table: current.table, name: current.name,
            timing: current.timing, events: current.events + [event], enabled: current.enabled))
      }
    }
    return triggers
  }

  /// The source of a function, procedure or trigger; nil when unknown or encrypted
  private func definition(schema: String, name: String) throws -> String? {
    Self.text(
      try connection.rows(
        "SELECT OBJECT_DEFINITION(OBJECT_ID(QUOTENAME(@p1) + N'.' + QUOTENAME(@p2)))",
        binds: [schema, name]
      ).first ?? [], 0)
  }

  /// Every foreign key, or those of the table `object`
  private func foreignKeys(of object: Int?) throws -> [EngineCatalog.ForeignKey] {
    let filter = object == nil ? "" : "WHERE fk.parent_object_id = CAST(@p1 AS int)"
    let rows = try connection.rows(
      """
      SELECT fk.object_id, fk.name, ss.name, st.name, sc.name, ts.name, tt.name, tc.name,
        fk.update_referential_action_desc, fk.delete_referential_action_desc
      FROM sys.foreign_keys AS fk
      JOIN sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id
      JOIN sys.objects AS st ON st.object_id = fk.parent_object_id
      JOIN sys.schemas AS ss ON ss.schema_id = st.schema_id
      JOIN sys.columns AS sc
        ON sc.object_id = fkc.parent_object_id AND sc.column_id = fkc.parent_column_id
      JOIN sys.objects AS tt ON tt.object_id = fk.referenced_object_id
      JOIN sys.schemas AS ts ON ts.schema_id = tt.schema_id
      JOIN sys.columns AS tc
        ON tc.object_id = fkc.referenced_object_id AND tc.column_id = fkc.referenced_column_id
      \(filter)
      ORDER BY ss.name, st.name, fk.name, fk.object_id, fkc.constraint_column_id
      """, binds: object.map { [String($0)] } ?? [])
    var keys: [EngineCatalog.ForeignKey] = []
    var lastID: Int?
    for row in rows {
      guard let id = Self.int(row, 0), let name = Self.text(row, 1),
        let sourceSchema = Self.text(row, 2), let sourceTable = Self.text(row, 3),
        let sourceColumn = Self.text(row, 4), let targetSchema = Self.text(row, 5),
        let targetTable = Self.text(row, 6), let targetColumn = Self.text(row, 7)
      else { continue }
      if id == lastID, let current = keys.popLast() {
        keys.append(
          EngineCatalog.ForeignKey(
            name: current.name, sourceSchema: current.sourceSchema,
            sourceTable: current.sourceTable,
            sourceColumns: current.sourceColumns + [sourceColumn],
            targetSchema: current.targetSchema, targetTable: current.targetTable,
            targetColumns: current.targetColumns + [targetColumn], onUpdate: current.onUpdate,
            onDelete: current.onDelete))
      } else {
        keys.append(
          EngineCatalog.ForeignKey(
            name: name, sourceSchema: sourceSchema, sourceTable: sourceTable,
            sourceColumns: [sourceColumn], targetSchema: targetSchema, targetTable: targetTable,
            targetColumns: [targetColumn], onUpdate: Self.text(row, 8),
            onDelete: Self.text(row, 9)))
      }
      lastID = id
    }
    return keys
  }

  /// `{"schema.relation": [Column]}` for every table and view
  private func allColumns() throws -> [String: [EngineCatalog.Column]] {
    let rows = try connection.rows(
      """
      SELECT s.name, o.name, c.name, TYPE_NAME(c.user_type_id), c.max_length, c.precision,
        c.scale, c.is_nullable, c.is_identity, c.is_computed,
        CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END
      FROM sys.columns AS c
      JOIN sys.objects AS o ON o.object_id = c.object_id
      JOIN sys.schemas AS s ON s.schema_id = o.schema_id
      LEFT JOIN (
        SELECT ic.object_id, ic.column_id
        FROM sys.indexes AS i
        JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        WHERE i.is_primary_key = 1
      ) AS pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
      WHERE o.type IN ('U', 'V') AND o.is_ms_shipped = 0
      ORDER BY s.name, o.name, c.column_id
      """)
    var relations: [String: [EngineCatalog.Column]] = [:]
    for row in rows {
      guard let schema = Self.text(row, 0), let relation = Self.text(row, 1),
        let name = Self.text(row, 2)
      else { continue }
      relations["\(schema).\(relation)", default: []].append(
        EngineCatalog.Column(
          name: name, type: Self.displayType(row, 3), isNullable: Self.bool(row, 7),
          isPrimaryKey: Self.int(row, 10) == 1, isIdentity: Self.bool(row, 8),
          isGenerated: Self.bool(row, 9)))
    }
    return relations
  }

  // MARK: One table

  /// A user table or view by schema (nil: the user's default schema) and name
  private struct Object {
    let id: Int
    let schema: String
    let name: String
  }

  /// `types`: a fixed list of sys.objects types
  private func object(schema: String?, name: String, types: String) throws -> Object? {
    guard
      let row = try connection.rows(
        """
        SELECT o.object_id, s.name, o.name
        FROM sys.objects AS o
        JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE s.name = ISNULL(@p1, SCHEMA_NAME()) AND o.name = @p2 AND o.type IN \(types)
        """, binds: [schema, name]
      ).first, let id = Self.int(row, 0), let schema = Self.text(row, 1),
      let name = Self.text(row, 2)
    else { return nil }
    return Object(id: id, schema: schema, name: name)
  }

  private func primaryKey(of object: Int) throws -> [String] {
    try connection.rows(
      """
      SELECT c.name
      FROM sys.indexes AS i
      JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
      JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
      WHERE i.is_primary_key = 1 AND i.object_id = CAST(@p1 AS int)
      ORDER BY ic.key_ordinal
      """, binds: [String(object)]
    ).compactMap { Self.text($0, 0) }
  }

  /// A user table; identity, computed and timestamp columns are never written
  private func editTable(schema: String?, table: String) throws -> EngineCatalog.EditTable? {
    guard let object = try object(schema: schema, name: table, types: "('U')") else { return nil }
    let rows = try connection.rows(
      """
      SELECT c.name, c.is_computed, c.is_identity, TYPE_NAME(c.system_type_id)
      FROM sys.columns AS c
      WHERE c.object_id = CAST(@p1 AS int)
      ORDER BY c.column_id
      """, binds: [String(object.id)])
    let columns = rows.compactMap { Self.text($0, 0) }
    let generated = rows.compactMap { row -> String? in
      let computed =
        Self.bool(row, 1) == true || Self.bool(row, 2) == true || Self.text(row, 3) == "timestamp"
      return computed ? Self.text(row, 0) : nil
    }
    return EngineCatalog.EditTable(
      schema: object.schema, name: object.name, columns: columns,
      primaryKeyColumns: try primaryKey(of: object.id), generatedColumns: generated)
  }

  /// `COUNT_BIG(*)`: exact
  private func rowCount(schema: String, table: String) throws -> Int {
    // The names go into the SQL text (bracket-quoted): never a NUL, which would cut it short
    guard !schema.unicodeScalars.contains("\0"), !table.unicodeScalars.contains("\0") else {
      throw EngineFailure(code: .invalid, message: "A table name contains a NUL character.")
    }
    let rows = try connection.rows(
      "SELECT COUNT_BIG(*) FROM \(SQLServerTypes.quoted(schema)).\(SQLServerTypes.quoted(table))")
    guard let count = rows.first.flatMap({ Self.int($0, 0) }) else {
      throw EngineFailure(code: .query, message: "The server did not report the row count.")
    }
    return count
  }

  private func tableStructure(schema: String, table: String) throws -> EngineCatalog.TableStructure
  {
    guard let object = try object(schema: schema, name: table, types: "('U', 'V')") else {
      throw EngineFailure(code: .query, message: "The table \(schema).\(table) was not found.")
    }
    let id = [String(object.id)]
    let columns = try connection.rows(
      """
      SELECT c.name, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale,
        c.is_nullable, c.is_identity, dc.definition, cc.definition, cc.is_persisted,
        c.collation_name, CAST(ep.value AS nvarchar(max))
      FROM sys.columns AS c
      LEFT JOIN sys.default_constraints AS dc ON dc.object_id = c.default_object_id
      LEFT JOIN sys.computed_columns AS cc
        ON cc.object_id = c.object_id AND cc.column_id = c.column_id
      LEFT JOIN sys.extended_properties AS ep
        ON ep.class = 1 AND ep.major_id = c.object_id AND ep.minor_id = c.column_id
        AND ep.name = N'MS_Description'
      WHERE c.object_id = CAST(@p1 AS int)
      ORDER BY c.column_id
      """, binds: id
    ).compactMap { row -> EngineCatalog.StructureColumn? in
      guard let name = Self.text(row, 0) else { return nil }
      var column = EngineCatalog.StructureColumn(
        name: name, dataType: Self.displayType(row, 1), isNullable: Self.bool(row, 5) ?? true,
        defaultExpression: Self.text(row, 7),
        identity: Self.bool(row, 6) == true ? "autoIncrement" : nil, comment: Self.text(row, 11),
        collation: Self.text(row, 10))
      if let expression = Self.text(row, 8) {
        column.generated = .init(expression: expression, isStored: Self.bool(row, 9) == true)
      }
      return column
    }
    let comment = try connection.rows(
      """
      SELECT CAST(value AS nvarchar(max)) FROM sys.extended_properties
      WHERE class = 1 AND major_id = CAST(@p1 AS int) AND minor_id = 0
        AND name = N'MS_Description'
      """, binds: id
    ).first.flatMap { Self.text($0, 0) }
    return EngineCatalog.TableStructure(
      schema: object.schema, name: object.name, comment: comment, columns: columns,
      indexes: try indexes(of: object.id),
      constraints: try keyConstraints(of: object.id)
        + (try foreignKeys(of: object.id)).map(Self.constraint)
        + (try checkConstraints(of: object.id)))
  }

  /// Every index but the heap, with its key columns (included columns left out)
  private func indexes(of object: Int) throws -> [EngineCatalog.Index] {
    let rows = try connection.rows(
      """
      SELECT i.index_id, i.name, i.is_unique, i.is_primary_key, i.type_desc,
        i.filter_definition, c.name, ic.is_descending_key
      FROM sys.indexes AS i
      JOIN sys.index_columns AS ic
        ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
      JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
      WHERE i.object_id = CAST(@p1 AS int) AND i.type > 0 AND i.is_hypothetical = 0
      ORDER BY i.index_id, ic.key_ordinal
      """, binds: [String(object)])
    var indexes: [EngineCatalog.Index] = []
    var lastID: Int?
    for row in rows {
      guard let id = Self.int(row, 0), let column = Self.text(row, 6) else { continue }
      let key = EngineCatalog.IndexKey(column: column, descending: Self.bool(row, 7) == true)
      if id == lastID, let current = indexes.popLast() {
        indexes.append(
          EngineCatalog.Index(
            name: current.name, keys: current.keys + [key], isUnique: current.isUnique,
            isPrimary: current.isPrimary, method: current.method, predicate: current.predicate))
      } else {
        indexes.append(
          EngineCatalog.Index(
            name: Self.text(row, 1) ?? "", keys: [key], isUnique: Self.bool(row, 2) == true,
            isPrimary: Self.bool(row, 3) == true, method: Self.text(row, 4)?.lowercased(),
            predicate: Self.text(row, 5)))
      }
      lastID = id
    }
    return indexes
  }

  /// Primary key and unique constraints
  private func keyConstraints(of object: Int) throws -> [EngineCatalog.Constraint] {
    let rows = try connection.rows(
      """
      SELECT kc.name, kc.type, c.name
      FROM sys.key_constraints AS kc
      JOIN sys.index_columns AS ic
        ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id
        AND ic.is_included_column = 0
      JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
      WHERE kc.parent_object_id = CAST(@p1 AS int)
      ORDER BY kc.type, kc.name, ic.key_ordinal
      """, binds: [String(object)])
    var constraints: [EngineCatalog.Constraint] = []
    for row in rows {
      guard let name = Self.text(row, 0), let column = Self.text(row, 2) else { continue }
      let kind =
        Self.text(row, 1)?.trimmingCharacters(in: .whitespaces) == "PK"
        ? "primaryKey" : "unique"
      if let current = constraints.last, current.name == name {
        constraints[constraints.count - 1] = EngineCatalog.Constraint(
          name: name, kind: current.kind, columns: current.columns + [column])
      } else {
        constraints.append(EngineCatalog.Constraint(name: name, kind: kind, columns: [column]))
      }
    }
    return constraints
  }

  private func checkConstraints(of object: Int) throws -> [EngineCatalog.Constraint] {
    try connection.rows(
      """
      SELECT cc.name, cc.definition, c.name
      FROM sys.check_constraints AS cc
      LEFT JOIN sys.columns AS c
        ON c.object_id = cc.parent_object_id AND c.column_id = cc.parent_column_id
      WHERE cc.parent_object_id = CAST(@p1 AS int)
      ORDER BY cc.name
      """, binds: [String(object)]
    ).compactMap { row in
      guard let check = Self.text(row, 1) else { return nil }
      return EngineCatalog.Constraint(
        name: Self.text(row, 0), kind: "check", columns: Self.text(row, 2).map { [$0] } ?? [],
        check: check)
    }
  }

  private static func constraint(_ key: EngineCatalog.ForeignKey) -> EngineCatalog.Constraint {
    EngineCatalog.Constraint(
      name: key.name, kind: "foreignKey", columns: key.sourceColumns,
      references: .init(
        schema: key.targetSchema, table: key.targetTable, columns: key.targetColumns,
        onUpdate: key.onUpdate, onDelete: key.onDelete))
  }

  // MARK: Result column origins

  /// `columns` (a result of `query`, without origins) with the origins the server describes for
  /// its first result set (`SQLServerTypes.describeSQL`, `originColumns`). An error of the
  /// describe or of the current database read leaves them without origins: never thrown.
  private func originColumns(
    _ columns: [EngineEvent.Column], query: String
  ) -> [EngineEvent.Column] {
    guard !columns.isEmpty else { return columns }
    do {
      // No table read: opens no transaction under IMPLICIT_TRANSACTIONS ON
      let database = Self.text(try connection.rows("SELECT DB_NAME()").first ?? [], 0)
      defer { connection.discardResults() }
      try connection.execute(
        SQLServerTypes.describeSQL, binds: [query, SQLServerTypes.describeParameters(query)])
      var names: [String] = []
      var rows: [[EngineCell]] = []
      if let described = try connection.nextResult() {
        names = described.map(\.name)
        while let row = try connection.nextRow() { rows.append(row) }
      }
      return SQLServerTypes.originColumns(
        columns, described: SQLServerTypes.describedColumns(names: names, rows: rows),
        database: database)
    } catch {
      return columns
    }
  }

  // MARK: Helpers

  private static func string(_ args: [String: EngineJSONValue], _ key: String) throws -> String {
    guard case .string(let value)? = args[key], !value.isEmpty else {
      throw EngineFailure(code: .invalid, message: "The catalog request has no \(key).")
    }
    return value
  }

  /// `name` as `table` (the user's default schema) or `schema.table`, each part bracketed
  /// (`[dbo].[t]`) or bare (`SQLServerTypes.qualifiedName`); a malformed name is refused
  private static func qualifiedName(_ args: [String: EngineJSONValue]) throws -> (String?, String) {
    guard let parts = SQLServerTypes.qualifiedName(try string(args, "name")) else {
      throw EngineFailure(code: .invalid, message: "The catalog request has a malformed name.")
    }
    return (parts.schema, parts.table)
  }

  /// The type of a row's type name at `index` and its max length, precision and scale after it
  private static func displayType(_ row: [EngineCell], _ index: Int) -> String {
    SQLServerTypes.displayType(
      name: text(row, index) ?? "", maxLength: int(row, index + 1) ?? 0,
      precision: int(row, index + 2) ?? 0, scale: int(row, index + 3) ?? 0)
  }

  private static func text(_ row: [EngineCell], _ index: Int) -> String? {
    guard index < row.count else { return nil }
    switch row[index] {
    case .text(let text), .decimal(let text), .date(let text): return text
    case .int(let value): return String(value)
    default: return nil
    }
  }

  private static func int(_ row: [EngineCell], _ index: Int) -> Int? {
    guard index < row.count else { return nil }
    switch row[index] {
    case .int(let value): return value
    case .bool(let value): return value ? 1 : 0
    default: return nil
    }
  }

  private static func bool(_ row: [EngineCell], _ index: Int) -> Bool? {
    guard index < row.count else { return nil }
    switch row[index] {
    case .bool(let value): return value
    case .int(let value): return value != 0
    default: return nil
    }
  }
}
