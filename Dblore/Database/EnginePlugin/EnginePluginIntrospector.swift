// EnginePluginIntrospector.swift
// Catalog reads of an engine plugin session: one `catalog` request per read, its DTOs mapped
// into the schema models. DTO text is server data, mapped and never interpreted.
// - Reads with an empty protocol default (functions, procedures, triggers, users, roles, and
//   `definition` as nil) read a plugin `error` (any code, `unsupported` included) as empty; the
//   code is logged, never the message. Every other read throws it as plain text. Transport
//   failures and cancellation always throw.
// - Text enums map leniently: a trigger with an unknown timing is skipped, unknown events are
//   dropped, unknown FK actions are NO ACTION, an unknown identity is none, a constraint of an
//   unknown kind (or a foreign key without its reference, a check without its text) is skipped.
// - Sequences and user types keep the protocol defaults: the protocol has no read for them.

import Foundation

nonisolated struct EnginePluginIntrospector: SchemaIntrospector {

  func tables(in session: any DatabaseSession) async throws -> [DatabaseTable] {
    guard case .tables(let tables) = try await read(.tables, in: session) else { return [] }
    return tables.map {
      DatabaseTable(
        schema: $0.schema, name: $0.name, rowCount: $0.rowCount,
        isTemporary: $0.isTemporary ?? false)
    }
  }

  func views(in session: any DatabaseSession) async throws -> [DatabaseView] {
    guard case .views(let views) = try await read(.views, in: session) else { return [] }
    return views.map { DatabaseView(schema: $0.schema, name: $0.name, definition: $0.definition) }
  }

  func functions(in session: any DatabaseSession) async throws -> [DatabaseFunction] {
    guard case .functions(let functions) = try await optionalRead(.functions, in: session)
    else { return [] }
    return functions.map {
      DatabaseFunction(
        schema: $0.schema, name: $0.name, returnType: $0.returnType ?? "",
        arguments: $0.arguments ?? "")
    }
  }

  func procedures(in session: any DatabaseSession) async throws -> [DatabaseProcedure] {
    guard case .procedures(let procedures) = try await optionalRead(.procedures, in: session)
    else { return [] }
    return procedures.map {
      DatabaseProcedure(schema: $0.schema, name: $0.name, arguments: $0.arguments ?? "")
    }
  }

  func triggers(in session: any DatabaseSession) async throws -> [DatabaseTrigger] {
    guard case .triggers(let triggers) = try await optionalRead(.triggers, in: session)
    else { return [] }
    return triggers.compactMap { trigger in
      guard let timing = Self.timing(trigger.timing) else { return nil }
      return DatabaseTrigger(
        schema: trigger.schema, table: trigger.table, name: trigger.name, timing: timing,
        events: trigger.events.compactMap { DatabaseTrigger.Event(rawValue: Self.word($0)) },
        enabled: trigger.enabled ?? true)
    }
  }

  /// Functions, procedures and triggers; nil for sequences and user types (no read for them)
  func definition(
    of object: SchemaObjectRef, in session: any DatabaseSession
  ) async throws -> String? {
    let args: [String: EngineJSONValue]
    switch object {
    case .function(let function):
      args = [
        "kind": .string("function"), "schema": .string(function.schema),
        "name": .string(function.name),
      ]
    case .procedure(let procedure):
      args = [
        "kind": .string("procedure"), "schema": .string(procedure.schema),
        "name": .string(procedure.name),
      ]
    case .trigger(let trigger):
      args = [
        "kind": .string("trigger"), "schema": .string(trigger.schema),
        "name": .string(trigger.name), "table": .string(trigger.table),
      ]
    case .sequence, .userType:
      return nil
    }
    guard case .definition(let text) = try await optionalRead(.definition, args, in: session)
    else { return nil }
    return text
  }

  func users(in session: any DatabaseSession) async throws -> [DatabaseUser] {
    guard case .users(let users) = try await optionalRead(.users, in: session) else { return [] }
    return users.map {
      DatabaseUser(
        name: $0.name, canLogin: $0.canLogin ?? true, isSuperuser: $0.isSuperuser ?? false,
        canCreateDB: $0.canCreateDB ?? false, canCreateRole: $0.canCreateRole ?? false,
        connectionLimit: $0.connectionLimit)
    }
  }

  func roles(in session: any DatabaseSession) async throws -> [DatabaseRole] {
    guard case .roles(let roles) = try await optionalRead(.roles, in: session) else { return [] }
    return roles.map {
      DatabaseRole(
        name: $0.name, canLogin: $0.canLogin ?? false, isSuperuser: $0.isSuperuser ?? false,
        canCreateDB: $0.canCreateDB ?? false, canCreateRole: $0.canCreateRole ?? false,
        members: $0.members ?? [])
    }
  }

  func foreignKeys(in session: any DatabaseSession) async throws -> [ForeignKey] {
    guard case .foreignKeys(let keys) = try await read(.foreignKeys, in: session) else {
      return []
    }
    return keys.map {
      ForeignKey(
        constraintName: $0.name, sourceSchema: $0.sourceSchema, sourceTable: $0.sourceTable,
        sourceColumns: $0.sourceColumns, targetSchema: $0.targetSchema,
        targetTable: $0.targetTable, targetColumns: $0.targetColumns,
        onUpdate: Self.action($0.onUpdate), onDelete: Self.action($0.onDelete))
    }
  }

  func allColumns(in session: any DatabaseSession) async throws -> [String: [DatabaseColumn]] {
    guard case .allColumns(let relations) = try await read(.allColumns, in: session) else {
      return [:]
    }
    return relations.mapValues { columns in
      columns.map {
        DatabaseColumn(
          name: $0.name, type: $0.type, isNullable: $0.isNullable ?? true,
          isPrimaryKey: $0.isPrimaryKey ?? false, isIdentity: $0.isIdentity ?? false,
          isUnique: $0.isUnique ?? false, isGenerated: $0.isGenerated ?? false)
      }
    }
  }

  /// Nil when the plugin finds no editable table or the table has no primary key (rows are
  /// located by key only). Ordinals are 1-based positions in `columns`.
  func editTable(named name: String, in session: any DatabaseSession) async throws -> EditTable? {
    let plugin = try Self.pluginSession(session)
    guard case .editTable(let found) = try await read(.editTable, ["name": .string(name)], plugin),
      let table = found, !table.primaryKeyColumns.isEmpty
    else { return nil }
    var names: [Int16: String] = [:]
    for (index, column) in table.columns.enumerated() {
      guard let ordinal = Int16(exactly: index + 1) else { return nil }
      names[ordinal] = column
    }
    let dialect = plugin.config.databaseType.dialect
    return EditTable(
      oid: Self.editTableOID, attributeNames: names, primaryKeyColumns: table.primaryKeyColumns,
      qualifiedName: try dialect.quoteIdentifier(table.schema) + "."
        + (try dialect.quoteIdentifier(table.name)),
      updateOnly: false,
      tableRef: .enginePlugin(plugin.pluginID, schema: table.schema, table: table.name),
      schema: table.schema, name: table.name,
      generatedColumns: Set(table.generatedColumns ?? []))
  }

  /// Result types with precision, scale and length from the plugin, matched by position and
  /// name. `columns` unchanged when the read fails or answers other columns.
  func enrichColumnTypes(
    _ columns: [ColumnInfo], query: String, in session: any DatabaseSession
  ) async -> [ColumnInfo] {
    guard !columns.isEmpty else { return columns }
    let args: [String: EngineJSONValue] = [
      "query": .string(query), "columns": .array(columns.map(Self.wire)),
    ]
    guard let plugin = try? Self.pluginSession(session),
      case .enrichColumnTypes(let typed) = try? await read(.enrichColumnTypes, args, plugin),
      typed.count == columns.count,
      zip(columns, typed).allSatisfy({ $0.name == $1.name })
    else { return columns }
    return zip(columns, typed).map { column, typed in
      ColumnInfo(
        name: column.name, type: typed.type, origin: column.origin,
        sourceName: column.sourceName, wallClock: column.wallClock, masked: column.masked)
    }
  }

  func rowCount(schema: String, table: String, in session: any DatabaseSession) async throws -> Int
  {
    let args: [String: EngineJSONValue] = ["schema": .string(schema), "table": .string(table)]
    guard case .rowCount(let count) = try await read(.rowCount, args, in: session) else {
      return 0
    }
    return count
  }

  func primaryKeyColumns(
    of tableName: String, in session: any DatabaseSession
  ) async throws -> [String] {
    let args: [String: EngineJSONValue] = ["name": .string(tableName)]
    guard case .primaryKey(let columns) = try await read(.primaryKey, args, in: session) else {
      return []
    }
    return columns
  }

  func tableStructure(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> TableStructure {
    let plugin = try Self.pluginSession(session)
    let args: [String: EngineJSONValue] = ["schema": .string(schema), "table": .string(table)]
    guard case .tableStructure(let structure) = try await read(.tableStructure, args, plugin)
    else { throw EnginePluginError.unreadableEvent }
    return TableStructure(
      tableID: .enginePlugin(plugin.pluginID, schema: structure.schema, table: structure.name),
      schema: structure.schema, name: structure.name,
      columns: structure.columns.enumerated().map { Self.column($1, ordinal: $0 + 1) },
      indexes: structure.indexes.map(Self.index),
      constraints: structure.constraints.compactMap(Self.constraint),
      comment: structure.comment)
  }

  // MARK: - Requests

  /// MySQL-style edit target: the OID only has to be nonzero; identity is `tableRef`
  static let editTableOID: UInt32 = 1

  private func read(
    _ read: EngineCatalogRead, _ args: [String: EngineJSONValue] = [:],
    in session: any DatabaseSession
  ) async throws -> EngineCatalogResult {
    try await self.read(read, args, try Self.pluginSession(session))
  }

  private func read(
    _ read: EngineCatalogRead, _ args: [String: EngineJSONValue], _ session: EnginePluginSession
  ) async throws -> EngineCatalogResult {
    try await session.catalog(read, args: args)
  }

  /// `read`, or nil when the plugin answers it with an `error` (the protocol default's empty
  /// answer). Only the read and the error code are logged: the message is server text.
  private func optionalRead(
    _ read: EngineCatalogRead, _ args: [String: EngineJSONValue] = [:],
    in session: any DatabaseSession
  ) async throws -> EngineCatalogResult? {
    let plugin = try Self.pluginSession(session)
    do {
      return try await self.read(read, args, plugin)
    } catch EnginePluginError.server(let failure) {
      await AppLogger.shared.debug(
        "The \(plugin.pluginID) plugin did not read \(read.rawValue) (\(failure.code.rawValue))",
        category: "Database")
      return nil
    }
  }

  private static func pluginSession(_ session: any DatabaseSession) throws -> EnginePluginSession {
    guard let plugin = session as? EnginePluginSession else {
      throw EnginePluginSessionError.unsupported("A catalog read through another kind of session")
    }
    return plugin
  }

  /// A result column as `enrichColumnTypes` sends it (`EngineEvent.Column`)
  private static func wire(_ column: ColumnInfo) -> EngineJSONValue {
    var object: [String: EngineJSONValue] = [
      "name": .string(column.name), "type": .string(column.type),
      "wallClock": .bool(column.wallClock),
    ]
    if let source = column.sourceName {
      object["origin"] = .object([
        "schema": .string(source.schema), "table": .string(source.table),
        "column": .string(source.column),
      ])
    }
    return .object(object)
  }

  // MARK: - Mapping

  /// Upper-cased, `_` and runs of whitespace as one space (`INSTEAD_OF`, `SET_NULL`)
  private static func word(_ text: String) -> String {
    text.uppercased().split(whereSeparator: { $0 == "_" || $0.isWhitespace })
      .joined(separator: " ")
  }

  /// `word` without its spaces (`primary_key`, `PRIMARY KEY` and `primaryKey` as `PRIMARYKEY`)
  private static func compactWord(_ text: String) -> String {
    word(text).filter { $0 != " " }
  }

  private static func timing(_ text: String) -> DatabaseTrigger.Timing? {
    let word = word(text)
    return word == "FOR" ? .after : DatabaseTrigger.Timing(rawValue: word)
  }

  private static func action(_ text: String?) -> ForeignKeyAction {
    ForeignKeyAction(mysqlRule: text.map(word) ?? "")
  }

  private static func column(
    _ column: EngineCatalog.StructureColumn, ordinal: Int
  ) -> TableStructure.Column {
    TableStructure.Column(
      ordinal: ordinal, name: column.name, dataType: column.dataType,
      isNullable: column.isNullable, defaultExpression: column.defaultExpression,
      identity: column.identity.flatMap(identity),
      generated: column.generated.map {
        TableStructure.Generated(expression: $0.expression, isStored: $0.isStored)
      },
      comment: column.comment, collation: column.collation)
  }

  private static func identity(_ text: String) -> TableStructure.Identity? {
    switch compactWord(text) {
    case "AUTOINCREMENT": .autoIncrement
    case "ALWAYS": .always
    case "BYDEFAULT": .byDefault
    default: nil
    }
  }

  private static func index(_ index: EngineCatalog.Index) -> TableStructure.Index {
    TableStructure.Index(
      name: index.name,
      keys: index.keys.map { key in
        key.column.map(TableStructure.Index.Key.column) ?? .expression(key.expression)
      },
      isUnique: index.isUnique, isPrimary: index.isPrimary, method: index.method,
      isPartial: index.predicate != nil, predicate: index.predicate,
      sortOrder: TableStructure.Index.storedOrder(
        index.keys.map { TableStructure.Index.KeyOrder(descending: $0.descending ?? false) }))
  }

  private static func constraint(
    _ constraint: EngineCatalog.Constraint
  ) -> TableStructure.Constraint? {
    let kind: TableStructure.Constraint.Kind
    switch compactWord(constraint.kind) {
    case "PRIMARYKEY": kind = .primaryKey
    case "UNIQUE": kind = .unique
    case "FOREIGNKEY":
      guard let reference = constraint.references else { return nil }
      kind = .foreignKey(
        .init(
          schema: reference.schema, table: reference.table, columns: reference.columns,
          onUpdate: action(reference.onUpdate), onDelete: action(reference.onDelete)))
    case "CHECK":
      guard let check = constraint.check else { return nil }
      kind = .check(check)
    default: return nil
    }
    return .init(name: constraint.name, kind: kind, columns: constraint.columns)
  }
}

extension TableRef {
  /// Engine plugin table identity: `plugin:<id>:` then the double-quoted schema and table, built
  /// only here. Quotes are doubled, so names with dots or quotes never give the same string.
  nonisolated static func enginePlugin(
    _ pluginID: String, schema: String, table: String
  )
    -> TableRef
  {
    func quoted(_ name: String) -> String {
      "\"" + SQLDialect.escapingScalars(name, ["\"": "\"\""]) + "\""
    }
    return TableRef("plugin:\(pluginID):\(quoted(schema)).\(quoted(table))")
  }
}
