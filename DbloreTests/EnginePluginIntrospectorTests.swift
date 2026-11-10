// EnginePluginIntrospectorTests.swift
// `EnginePluginIntrospector` through a real `EnginePluginSession` on `FakeEnginePlugin`: catalog
// DTOs mapped into the schema models, the lenient text enums, the edit table, optional against
// required reads, and an answer for another read.

import Foundation
import Testing

@testable import Dblore

@Suite(.timeLimit(.minutes(1)))
struct EnginePluginIntrospectorTests {
  private let introspector = EnginePluginIntrospector()

  /// An open session on `fake`
  private func session(_ fake: FakeEnginePlugin) async throws -> EnginePluginSession {
    let session = EnginePluginSession(
      pluginID: fake.install(),
      config: ConnectionConfig(
        host: "db.example.com", port: 1433, database: "app", username: "sa", password: "pw",
        sslMode: .disable, timeoutSeconds: 5),
      hostKeyValidator: RejectUnknownSSHHostKeys())
    try await session.open()
    return session
  }

  @Test("Tables and columns keep their names, schema, types, nullability and key flags")
  func tablesAndColumnsMap() async throws {
    let fake = FakeEnginePlugin()
    fake.catalogAnswers[.tables] = .catalog(
      .tables([
        .init(schema: "dbo", name: "orders", rowCount: 12),
        .init(schema: "dbo", name: "#scratch", isTemporary: true),
      ]))
    fake.catalogAnswers[.allColumns] = .catalog(
      .allColumns([
        "dbo.orders": [
          .init(name: "id", type: "int", isNullable: false, isPrimaryKey: true),
          .init(name: "note", type: "nvarchar(50)"),
        ]
      ]))
    let session = try await session(fake)

    let tables = try await introspector.tables(in: session)
    let columns = try #require(try await introspector.allColumns(in: session)["dbo.orders"])

    #expect(tables.map(\.qualifiedName) == ["dbo.orders", "dbo.#scratch"])
    #expect(tables.map(\.rowCount) == [12, nil])
    #expect(tables.map(\.isTemporary) == [false, true])
    #expect(columns.map(\.name) == ["id", "note"])
    #expect(columns.map(\.type) == ["int", "nvarchar(50)"])
    #expect(columns.map(\.isNullable) == [false, true])
    #expect(columns.map(\.isPrimaryKey) == [true, false])
    await session.close()
  }

  @Test("Trigger timings, FK actions, identities and constraint kinds map leniently")
  @MainActor func textEnumsMapLeniently() async throws {
    let fake = FakeEnginePlugin()
    func trigger(_ name: String, timing: String) -> EngineCatalog.Trigger {
      .init(
        schema: "dbo", table: "orders", name: name, timing: timing, events: ["insert", "merge"])
    }
    fake.catalogAnswers[.triggers] = .catalog(
      .triggers([
        trigger("t1", timing: "INSTEAD_OF"), trigger("t2", timing: "for"),
        trigger("t3", timing: "sometimes"),
      ]))
    fake.catalogAnswers[.foreignKeys] = .catalog(
      .foreignKeys([
        .init(
          name: "fk", sourceSchema: "dbo", sourceTable: "lines", sourceColumns: ["order_id"],
          targetSchema: "dbo", targetTable: "orders", targetColumns: ["id"], onUpdate: "explode",
          onDelete: "SET_NULL")
      ]))
    fake.catalogAnswers[.tableStructure] = .catalog(
      .tableStructure(
        .init(
          schema: "dbo", name: "orders",
          columns: [
            .init(name: "id", dataType: "int", isNullable: false, identity: "by_default"),
            .init(name: "code", dataType: "int", isNullable: false, identity: "sometimes"),
          ],
          indexes: [],
          constraints: [
            .init(name: "pk", kind: "primary_key", columns: ["id"]),
            .init(name: "pk2", kind: "PRIMARY KEY", columns: ["id"]),
            .init(name: "uq", kind: "unique", columns: ["code"]),
            .init(
              name: "fk", kind: "foreign key", columns: ["code"],
              references: .init(schema: "dbo", table: "codes", columns: ["id"])),
            .init(name: "ex", kind: "exclusion", columns: ["span"]),
          ])))
    let session = try await session(fake)

    let triggers = try await introspector.triggers(in: session)
    let key = try #require(try await introspector.foreignKeys(in: session).first)
    let structure = try await introspector.tableStructure(
      schema: "dbo", table: "orders", in: session)

    #expect(triggers.map(\.name) == ["t1", "t2"])
    #expect(triggers.map(\.timing) == [.insteadOf, .after])
    #expect(triggers.map(\.events) == [[.insert], [.insert]])
    #expect(key.onDelete == .setNull)
    #expect(key.onUpdate == .noAction)
    #expect(structure.columns.map(\.identity) == [.byDefault, nil])
    #expect(
      structure.constraints == [
        .init(name: "pk", kind: .primaryKey, columns: ["id"]),
        .init(name: "pk2", kind: .primaryKey, columns: ["id"]),
        .init(name: "uq", kind: .unique, columns: ["code"]),
        .init(
          name: "fk",
          kind: .foreignKey(
            .init(
              schema: "dbo", table: "codes", columns: ["id"], onUpdate: .noAction,
              onDelete: .noAction)),
          columns: ["code"]),
      ])
    await session.close()
  }

  @Test("An edit table has 1-based attribute names, quoted names and the plugin's table ref")
  func editTableMaps() async throws {
    let fake = FakeEnginePlugin()
    fake.catalogAnswers[.editTable] = .catalog(
      .editTable(
        .init(
          schema: "dbo", name: "or\"ders", columns: ["id", "note", "total"],
          primaryKeyColumns: ["id"], generatedColumns: ["total"])))
    // The test config is PostgreSQL-typed (the default), so its dialect quotes with `"`
    let session = try await session(fake)

    let table = try #require(try await introspector.editTable(named: "dbo.orders", in: session))
    fake.catalogAnswers[.editTable] = .catalog(
      .editTable(.init(schema: "dbo", name: "log", columns: ["at"], primaryKeyColumns: [])))
    let keyless = try await introspector.editTable(named: "dbo.log", in: session)

    #expect(table.attributeNames == [1: "id", 2: "note", 3: "total"])
    #expect(table.primaryKeyColumns == ["id"])
    #expect(table.qualifiedName == #""dbo"."or""ders""#)
    #expect(table.tableRef == .enginePlugin(session.pluginID, schema: "dbo", table: "or\"ders"))
    #expect(table.generatedColumns == ["total"])
    #expect(keyless == nil)
    await session.close()
  }

  @Test("A refused optional read is empty; a refused required read throws the plugin text")
  func optionalReadsReadErrorsAsEmpty() async throws {
    let fake = FakeEnginePlugin()
    let text = "The user has no access to the catalog."
    fake.catalogAnswers[.triggers] = .error(.init(code: .query, message: text))
    fake.catalogAnswers[.tables] = .error(.init(code: .query, message: text))
    let session = try await session(fake)

    #expect(try await introspector.triggers(in: session).isEmpty)
    let error = await #expect(throws: EnginePluginError.self) {
      _ = try await introspector.tables(in: session)
    }

    #expect(error?.errorDescription == text)
    await session.close()
  }

  @Test("A catalog answer for another read is unreadable")
  func answerForAnotherReadIsUnreadable() async throws {
    let fake = FakeEnginePlugin()
    fake.catalogAnswers[.tables] = .catalog(.views([]))
    let session = try await session(fake)

    await #expect(throws: EnginePluginError.unreadableEvent) {
      _ = try await introspector.tables(in: session)
    }
    await session.close()
  }
}
