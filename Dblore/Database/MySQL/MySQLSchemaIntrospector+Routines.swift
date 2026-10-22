// MySQLSchemaIntrospector+Routines.swift
// Functions, procedures and triggers of the connected database from information_schema, and
// their source through SHOW CREATE FUNCTION / PROCEDURE / TRIGGER.
//
// A user who may run a routine but not read it (EXECUTE only) gets a NULL body from SHOW CREATE;
// a user without the TRIGGER privilege is refused (1227). Both read as "no source" (nil).
// Routines have no overloads in MySQL, so `oid` stays nil and the name plus arguments identify one.

import Foundation

extension MySQLSchemaIntrospector {
  func functions(in session: any DatabaseSession) async throws -> [DatabaseFunction] {
    let routines = try await routines(type: "FUNCTION", in: session)
    return routines.map {
      DatabaseFunction(
        schema: database, name: $0.name, returnType: $0.returnType, arguments: $0.arguments)
    }
  }

  func procedures(in session: any DatabaseSession) async throws -> [DatabaseProcedure] {
    let routines = try await routines(type: "PROCEDURE", in: session)
    return routines.map {
      DatabaseProcedure(schema: database, name: $0.name, arguments: $0.arguments)
    }
  }

  /// One row per trigger. MySQL triggers are always enabled.
  func triggers(in session: any DatabaseSession) async throws -> [DatabaseTrigger] {
    let sql = """
      SELECT EVENT_OBJECT_TABLE, TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION
      FROM information_schema.TRIGGERS
      WHERE TRIGGER_SCHEMA = ?
      ORDER BY EVENT_OBJECT_TABLE, TRIGGER_NAME
      """
    var triggers: [DatabaseTrigger] = []
    for row in try await rows(in: session, sql: sql, binds: [.text(database)]) {
      guard let table = MySQLCatalogValue.string(row, 0),
        let name = MySQLCatalogValue.string(row, 1)
      else { continue }
      let timing = MySQLCatalogValue.string(row, 2).flatMap(DatabaseTrigger.Timing.init)
      let event = MySQLCatalogValue.string(row, 3).flatMap(DatabaseTrigger.Event.init)
      triggers.append(
        DatabaseTrigger(
          schema: database, table: table, name: name, timing: timing ?? .before,
          events: event.map { [$0] } ?? [], enabled: true))
    }
    return triggers
  }

  /// The CREATE statement from SHOW CREATE (third column on MySQL and MariaDB). Nil when the
  /// user may not read it, or the object is gone.
  func definition(
    of object: SchemaObjectRef, in session: any DatabaseSession
  ) async throws -> String? {
    let kind: String
    let schema: String
    let name: String
    switch object {
    case .function(let function):
      (kind, schema, name) = ("FUNCTION", function.schema, function.name)
    case .procedure(let procedure):
      (kind, schema, name) = ("PROCEDURE", procedure.schema, procedure.name)
    case .trigger(let trigger):
      (kind, schema, name) = ("TRIGGER", trigger.schema, trigger.name)
    case .sequence, .userType:
      return nil
    }
    let dialect = SQLDialect.mysql
    let sql =
      "SHOW CREATE \(kind) \(try dialect.quoteIdentifier(schema.isEmpty ? database : schema))."
      + (try dialect.quoteIdentifier(name))
    do {
      return try await rows(in: session, sql: sql).first.flatMap {
        MySQLCatalogValue.string($0, 2)
      }
    } catch let error as MySQLSessionError
      where error.code.map(Self.noSourceErrorCodes.contains) == true
    {
      return nil
    }
  }

  /// Access denied (1044, 1142, 1227, 1370) and no such routine or trigger (1305, 1360).
  private static let noSourceErrorCodes: Set<UInt16> = [1044, 1142, 1227, 1370, 1305, 1360]

  /// Routines of `type` with their arguments (`name type`, procedures with the mode first) and
  /// the return type of a function.
  private func routines(
    type: String, in session: any DatabaseSession
  ) async throws -> [(name: String, returnType: String, arguments: String)] {
    let routineSQL = """
      SELECT ROUTINE_NAME, DTD_IDENTIFIER
      FROM information_schema.ROUTINES
      WHERE ROUTINE_SCHEMA = ? AND ROUTINE_TYPE = ?
      ORDER BY ROUTINE_NAME
      """
    let parameterSQL = """
      SELECT SPECIFIC_NAME, PARAMETER_MODE, PARAMETER_NAME, DTD_IDENTIFIER
      FROM information_schema.PARAMETERS
      WHERE SPECIFIC_SCHEMA = ? AND ROUTINE_TYPE = ? AND ORDINAL_POSITION > 0
      ORDER BY SPECIFIC_NAME, ORDINAL_POSITION
      """
    let binds: [SQLBindValue] = [.text(database), .text(type)]
    var arguments: [String: [String]] = [:]
    for row in try await rows(in: session, sql: parameterSQL, binds: binds) {
      guard let routine = MySQLCatalogValue.string(row, 0) else { continue }
      // Function parameters are always IN, so only a procedure shows the mode.
      let columns = type == "PROCEDURE" ? [1, 2, 3] : [2, 3]
      let parts = columns.compactMap { MySQLCatalogValue.string(row, $0) }.filter { !$0.isEmpty }
      arguments[routine, default: []].append(parts.joined(separator: " "))
    }
    var routines: [(name: String, returnType: String, arguments: String)] = []
    for row in try await rows(in: session, sql: routineSQL, binds: binds) {
      guard let name = MySQLCatalogValue.string(row, 0) else { continue }
      routines.append(
        (
          name, MySQLCatalogValue.string(row, 1) ?? "",
          (arguments[name] ?? []).joined(separator: ", ")
        ))
    }
    return routines
  }
}
