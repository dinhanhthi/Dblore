// UserTypeDDLBuilderTests.swift
// `PostgresUserTypeDDLBuilder`: names are quoted and labels are literals, ADD VALUE comes back
// in its own group, unsafe DEFAULT / CHECK / type text is refused, nothing uses a label the same
// list adds (55P04), only a constraint the domain has is dropped, a CHECK without a name is left
// to the server, and every statement passes the schema change gate's shape check. One live
// round trip (`.requiresPostgres`, CI only): ADD VALUE + RENAME VALUE through the gated path the
// types editor picks for the server's version.

import Foundation
import Testing

@testable import Dblore

@Suite("UserTypeDDLBuilderTests")
struct UserTypeDDLBuilderTests {
  private typealias Builder = PostgresUserTypeDDLBuilder

  private static let mood = DatabaseUserType.Kind.enum(["sad", "it's"])
  private static let domain = DatabaseUserType.Kind.domain(
    baseType: "integer", notNull: false, defaultExpression: nil,
    constraints: [.init(name: "positive", definition: "CHECK ((VALUE > 0))")])
  private static let composite = DatabaseUserType.Kind.composite([
    .init(name: "x", type: "integer"), .init(name: "a\"b", type: "text"),
  ])

  @Test("Type, attribute and constraint names are quoted identifiers; labels are literals")
  func quoting() throws {
    let enumDDL = try Builder.build(
      [
        .addValue(label: "o'k", position: .after("it's")),
        .addValue(label: "back\\slash", position: nil),
        .renameValue(label: "it's", newLabel: "x\"y"),
      ], schema: "my\"s", name: "t\"y", loaded: Self.mood)
    #expect(
      enumDDL.addValues == [
        "ALTER TYPE \"my\"\"s\".\"t\"\"y\" ADD VALUE 'o''k' AFTER 'it''s'",
        "ALTER TYPE \"my\"\"s\".\"t\"\"y\" ADD VALUE E'back\\\\slash'",
      ])
    #expect(
      enumDDL.others == ["ALTER TYPE \"my\"\"s\".\"t\"\"y\" RENAME VALUE 'it''s' TO 'x\"y'"])

    let domainDDL = try Builder.build(
      [
        .addCheck(.init(name: "c\"k", expression: "VALUE <> 'a''b'")),
        .dropConstraint(name: "positive"),
      ],
      schema: "s", name: "d", loaded: Self.domain)
    #expect(
      domainDDL.others == [
        "ALTER DOMAIN \"s\".\"d\" ADD CONSTRAINT \"c\"\"k\" CHECK (VALUE <> 'a''b')",
        "ALTER DOMAIN \"s\".\"d\" DROP CONSTRAINT \"positive\"",
      ])

    let compositeDDL = try Builder.build(
      [
        .renameAttribute(name: "a\"b", newName: "c\"d"),
        .addAttribute(.init(name: "n\"m", type: "numeric(10, 2)")),
        .alterAttributeType(name: "x", type: "bigint"),
        .dropAttribute(name: "x"),
      ], schema: "s", name: "c", loaded: Self.composite)
    #expect(
      compositeDDL.others == [
        "ALTER TYPE \"s\".\"c\" DROP ATTRIBUTE \"x\", ADD ATTRIBUTE \"n\"\"m\" numeric(10, 2), "
          + "ALTER ATTRIBUTE \"x\" TYPE bigint",
        "ALTER TYPE \"s\".\"c\" RENAME ATTRIBUTE \"a\"\"b\" TO \"c\"\"d\"",
      ])

    let created = try Builder.build(
      [.createEnum(labels: ["a'b", "c"])], schema: "s", name: "e\"n", loaded: nil)
    #expect(created.others == ["CREATE TYPE \"s\".\"e\"\"n\" AS ENUM ('a''b', 'c')"])
  }

  @Test("ADD VALUE statements come back apart, in staged order, whatever else is staged")
  func addValueGroupedApart() throws {
    let ddl = try Builder.build(
      [
        .renameValue(label: "sad", newLabel: "blue"),
        .addValue(label: "happy", position: nil),
        .addValue(label: "meh", position: .before("sad")),
      ], schema: "public", name: "mood", loaded: Self.mood)
    #expect(
      ddl.addValues == [
        "ALTER TYPE \"public\".\"mood\" ADD VALUE 'happy'",
        "ALTER TYPE \"public\".\"mood\" ADD VALUE 'meh' BEFORE 'sad'",
      ])
    #expect(ddl.others == ["ALTER TYPE \"public\".\"mood\" RENAME VALUE 'sad' TO 'blue'"])
    #expect(ddl.all == ddl.addValues + ddl.others)
  }

  @Test("Unsafe DEFAULT, CHECK and type text is refused, not escaped")
  func unsafeTextRefused() {
    let unsafe = [
      "0); DROP TABLE t; --", "VALUE > 0 -- comment", "1, 2", "(VALUE > 0", "'open",
    ]
    for text in unsafe {
      #expect(throws: StructureDDLError.self) {
        try Builder.build(
          [.addCheck(.init(name: "c", expression: text))], schema: "s", name: "d",
          loaded: Self.domain)
      }
      #expect(throws: StructureDDLError.self) {
        try Builder.build(
          [.setDefault(expression: text)], schema: "s", name: "d", loaded: Self.domain)
      }
      #expect(throws: StructureDDLError.self) {
        try Builder.build(
          [.addAttribute(.init(name: "a", type: text))], schema: "s", name: "c",
          loaded: Self.composite)
      }
      #expect(throws: StructureDDLError.self) {
        try Builder.build(
          [
            .createDomain(
              .init(
                baseType: "integer", notNull: true, defaultExpression: nil,
                checks: [.init(name: "c", expression: text)]))
          ], schema: "s", name: "d", loaded: nil)
      }
    }
  }

  @Test("Nothing uses a label the same list adds: no rename of it, no placing next to it (55P04)")
  func noUseOfAddedLabel() {
    #expect(throws: StructureDDLError.self) {
      try Builder.build(
        [.addValue(label: "new", position: nil), .renameValue(label: "new", newLabel: "newer")],
        schema: "s", name: "mood", loaded: Self.mood)
    }
    #expect(throws: StructureDDLError.self) {
      try Builder.build(
        [
          .addValue(label: "new", position: nil), .addValue(label: "next", position: .after("new")),
        ],
        schema: "s", name: "mood", loaded: Self.mood)
    }
    // A label the type has, or one the list already adds, cannot be added again
    #expect(throws: StructureDDLError.self) {
      try Builder.build(
        [.addValue(label: "sad", position: nil)], schema: "s", name: "mood", loaded: Self.mood)
    }
    #expect(throws: StructureDDLError.self) {
      try Builder.build(
        [.renameValue(label: "sad", newLabel: "blue"), .addValue(label: "blue", position: nil)],
        schema: "s", name: "mood", loaded: Self.mood)
    }
  }

  @Test("Dropping a constraint the domain does not have is refused")
  func dropOfUnknownConstraintRefused() {
    #expect(throws: StructureDDLError.self) {
      try Builder.build(
        [.dropConstraint(name: "missing")], schema: "s", name: "d", loaded: Self.domain)
    }
  }

  @Test("A CHECK without a name is left to the server: no CONSTRAINT clause; blank is refused")
  func unnamedCheck() throws {
    let added = try Builder.build(
      [.addCheck(.init(name: "", expression: "VALUE < 10"))], schema: "s", name: "d",
      loaded: Self.domain)
    #expect(added.others == ["ALTER DOMAIN \"s\".\"d\" ADD CHECK (VALUE < 10)"])

    // Two unnamed CHECKs are not "listed twice"
    let created = try Builder.build(
      [
        .createDomain(
          .init(
            baseType: "integer", notNull: false, defaultExpression: nil,
            checks: [
              .init(name: "", expression: "VALUE > 0"), .init(name: "c", expression: "VALUE < 9"),
              .init(name: "", expression: "VALUE <> 5"),
            ]))
      ], schema: "s", name: "d", loaded: nil)
    #expect(
      created.others == [
        "CREATE DOMAIN \"s\".\"d\" AS integer CHECK (VALUE > 0) "
          + "CONSTRAINT \"c\" CHECK (VALUE < 9) CHECK (VALUE <> 5)"
      ])

    #expect(throws: StructureDDLError.self) {
      try Builder.build(
        [.addCheck(.init(name: "", expression: "  "))], schema: "s", name: "d",
        loaded: Self.domain)
    }
    // A loaded constraint always has a name: an empty one is never dropped
    #expect(throws: StructureDDLError.self) {
      try Builder.build(
        [.dropConstraint(name: "")], schema: "s", name: "d", loaded: Self.domain)
    }
  }

  @Test("Every change kind builds DDL the schema change gate accepts as single DDL statements")
  func passesGateShapeCheck() throws {
    let builds: [UserTypeDDL] = [
      try Builder.build(
        [
          .addValue(label: "a", position: .before("sad")),
          .renameValue(label: "sad", newLabel: "b"),
        ],
        schema: "s", name: "mood", loaded: Self.mood),
      try Builder.build(
        [
          .setDefault(expression: "1"), .dropDefault, .setNotNull, .dropNotNull,
          .addCheck(.init(name: "c", expression: "VALUE < 10")), .dropConstraint(name: "positive"),
          .addCheck(.init(name: "", expression: "VALUE <> 3")),
        ], schema: "s", name: "d", loaded: Self.domain),
      try Builder.build(
        [
          .addAttribute(.init(name: "y", type: "text")), .dropAttribute(name: "x"),
          .alterAttributeType(name: "a\"b", type: "varchar(20)"),
          .renameAttribute(name: "a\"b", newName: "z"),
        ], schema: "s", name: "c", loaded: Self.composite),
      try Builder.build(
        [.createEnum(labels: ["a", "b"])], schema: "s", name: "e", loaded: nil),
      try Builder.build(
        [
          .createDomain(
            .init(
              baseType: "varchar(10)", notNull: true, defaultExpression: "'x'",
              checks: [
                .init(name: "c", expression: "VALUE <> ''"),
                .init(name: "", expression: "VALUE <> 'y'"),
              ]))
        ], schema: "s", name: "d2", loaded: nil),
      try Builder.build(
        [.createComposite([.init(name: "x", type: "integer"), .init(name: "y", type: "text")])],
        schema: "s", name: "c2", loaded: nil),
    ]
    for ddl in builds {
      #expect(!ddl.all.isEmpty)
      #expect(
        DatabaseConnectionManager.schemaChangeRefusal(
          ddl.all, databaseType: .postgresql, transactionOpen: false) == nil)
    }
    // Changes of another kind are refused
    #expect(throws: StructureDDLError.self) {
      try Builder.build([.setNotNull], schema: "s", name: "mood", loaded: Self.mood)
    }
  }

  // MARK: - Live (CI only)

  @Test(
    "PostgreSQL: enum ADD VALUE + RENAME VALUE round trip through the gated path",
    .requiresPostgres, .timeLimit(.minutes(1)))
  func liveEnumRoundTrip() async throws {
    let schema = "ut_\(UUID().uuidString.prefix(8).lowercased())"
    let policy = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(
      config: ConnectionConfig(
        host: TestDatabase.host, port: TestDatabase.port, database: TestDatabase.database,
        username: TestDatabase.username, password: TestDatabase.password, sslMode: .disable,
        timeoutSeconds: 30, safeMode: .silent, protectedMode: false, statementTimeoutSeconds: 45))
    do {
      _ = try await manager.executeInternal("CREATE SCHEMA \(schema)")
      _ = try await manager.executeInternal(
        "CREATE TYPE \(schema).mood AS ENUM ('sad', 'ok')")
      let version = try #require(await manager.serverVersionNum())
      let ddl = try Builder.build(
        [
          .addValue(label: "happy", position: .after("ok")),
          .renameValue(label: "sad", newLabel: "blue"),
        ], schema: schema, name: "mood", loaded: .enum(["sad", "ok"]))
      let epoch = await manager.connectionEpoch
      if version >= 120_000 {
        // ADD VALUE in a transaction; the batch never uses the new label
        _ = try await manager.executeGatedSchemaChange(
          ddl.all, policy: policy, connectionEpoch: epoch)
      } else {
        // 25001: ADD VALUE outside a transaction first
        _ = try await manager.executeGatedSequentialCommands(
          ddl.addValues, policy: policy, connectionEpoch: epoch, expectedRows: nil)
        _ = try await manager.executeGatedSchemaChange(
          ddl.others, policy: policy, connectionEpoch: epoch)
      }
      let types = try await manager.fetchUserTypes()
      let mood = types.first { $0.schema == schema && $0.name == "mood" }
      #expect(mood?.kind == .enum(["blue", "ok", "happy"]))
    } catch {
      _ = try? await manager.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
      await manager.disconnect()
      throw error
    }
    _ = try? await manager.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
    await manager.disconnect()
  }
}
