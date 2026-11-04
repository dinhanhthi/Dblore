// CopyObjectsPlannerTests.swift
// CopyObjectsPlanner guards: a foreign-key cycle plans, an existing target name refuses, a SQLite
// target gets inline foreign keys with deferred checks and an inline CHECK, a unique constraint is
// not planned again as an index and indexes come before foreign keys, a PostgreSQL table lands in
// SQLite's main, repeated MySQL index names become distinct on PostgreSQL and FULLTEXT is skipped,
// repeated foreign-key names become distinct on MySQL and SET DEFAULT is dropped there. An index
// keeps DESC / NULLS on PostgreSQL; SQLite drops NULLS and MySQL 5.7 drops DESC, each warned.
// A CHECK or index expression that calls an unsafe function (attribute notation and SQLite's
// load_extension / readfile included) or has a subquery is skipped with a warning; an
// allowlisted one is copied. Known MySQL constraint names are renamed. Hostile
// identifiers stay quoted in the DDL, the identity restart and the source read. A MySQL string
// default with a backslash (before a combining mark too) is dropped.
// CopyObjectsDDLCheck guards: a type edit, an allowlisted CHECK and expression index, and a MySQL
// prefix length pass; a renamed column, a DROP, a statement on another table, comments,
// executable comments, dollar quotes, backslash strings (a combining mark after the backslash
// included), extra statements, CREATE TABLE AS, trailing clauses, a duplicate CREATE TABLE, an
// unplanned REFERENCES, ADD COLUMN, a multi-action ALTER, an unplanned PRAGMA, a trigger body,
// three-part names and unsafe CHECK, index key and predicate expressions (attribute notation, a
// qualified name, a table after IN), unsafe column DEFAULT / generated expressions (a call at the
// column's own level: pg_sleep, nextval, sleep, quoted or qualified), an identity's SEQUENCE NAME,
// a LIKE item and ADD ... USING INDEX are refused; clock defaults, START WITH and every target's
// unedited planned columns pass.

import Foundation
import Testing

@testable import Dblore

@Suite("CopyObjectsPlannerTests")
struct CopyObjectsPlannerTests {
  typealias Engine = StructureDDLBuilder.Engine
  private typealias Constraint = TableStructure.Constraint
  private typealias Index = TableStructure.Index

  private static let mysql = Engine.mysql(
    MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36))
  private static let sqlite = Engine.sqlite(libraryVersion: 3_045_000)

  private static func table(
    _ name: String, schema: String = "public", columns: [(String, String)],
    constraints: [Constraint] = [], indexes: [Index] = []
  ) -> CopyObjectsPlanner.SourceTable {
    CopyObjectsPlanner.SourceTable(
      structure: TableStructure(
        tableID: .sqlite(schema: schema, table: name), schema: schema, name: name,
        columns: columns.enumerated().map { offset, column in
          TableStructure.Column(
            ordinal: offset + 1, name: column.0, dataType: column.1, isNullable: true)
        },
        indexes: indexes, constraints: constraints))
  }

  private static func primaryKey(_ columns: String...) -> Constraint {
    Constraint(name: nil, kind: .primaryKey, columns: columns)
  }

  private static func foreignKey(
    _ name: String?, _ column: String, schema: String = "public", to table: String
  ) -> Constraint {
    Constraint(
      name: name,
      kind: .foreignKey(
        TableStructure.ForeignKeyReference(
          schema: schema, table: table, columns: ["id"], onUpdate: .noAction,
          onDelete: .noAction)),
      columns: [column])
  }

  private static func index(
    _ name: String, _ columns: [String], unique: Bool = false, method: String? = nil,
    order: [Index.KeyOrder] = []
  ) -> Index {
    Index(
      name: name, keys: columns.map { .column($0) }, isUnique: unique, isPrimary: false,
      method: method, isPartial: false, predicate: nil, sortOrder: order)
  }

  /// a.b_id -> b and b.a_id -> a
  private static func cycle(schema: String = "public") -> [CopyObjectsPlanner.SourceTable] {
    [
      table(
        "a", schema: schema, columns: [("id", "integer"), ("b_id", "integer")],
        constraints: [primaryKey("id"), foreignKey("a_b", "b_id", schema: schema, to: "b")]),
      table(
        "b", schema: schema, columns: [("id", "integer"), ("a_id", "integer")],
        constraints: [primaryKey("id"), foreignKey("b_a", "a_id", schema: schema, to: "a")]),
    ]
  }

  // MARK: - Planner

  @Test("Two tables with a foreign-key cycle plan without error, foreign keys after the rows")
  func foreignKeyCycle() throws {
    let plan = try CopyObjectsPlanner.plan(
      Self.cycle(), source: .postgresql, target: .postgresql, targetSchema: "copy",
      existingNames: [])
    #expect(plan.preludeStatements.count == 2)
    #expect(!plan.preludeStatements.contains { $0.contains("FOREIGN KEY") })
    #expect(
      plan.foreignKeyStatements == [
        #"ALTER TABLE "copy"."a" ADD CONSTRAINT "a_b" FOREIGN KEY ("b_id") REFERENCES "copy"."b" ("id")"#,
        #"ALTER TABLE "copy"."b" ADD CONSTRAINT "b_a" FOREIGN KEY ("a_id") REFERENCES "copy"."a" ("id")"#,
      ])
  }

  @Test("A table name the target schema already has refuses the plan")
  func existingName() {
    // SQLite names compare without case
    #expect(throws: CopyObjectsPlanError.targetTableExists("b")) {
      try CopyObjectsPlanner.plan(
        Self.cycle(), source: .postgresql, target: Self.sqlite, targetSchema: "main",
        existingNames: ["B"])
    }
  }

  @Test("SQLite target: deferred checks, inline foreign keys and an inline table-level CHECK")
  func sqliteInline() throws {
    var tables = Self.cycle(schema: "main")
    tables[0].structure.constraints.append(
      Constraint(name: "positive", kind: .check("\"id\" > 0"), columns: []))
    tables[0].structure.indexes.append(Self.index("a_b_id", ["b_id"]))
    let plan = try CopyObjectsPlanner.plan(
      tables, source: Self.sqlite, target: Self.sqlite, targetSchema: "main", existingNames: [])
    #expect(plan.preludeStatements.first == "PRAGMA defer_foreign_keys = ON")
    #expect(plan.foreignKeyStatements.isEmpty)
    #expect(plan.indexStatements == [#"CREATE INDEX "main"."a_b_id" ON "a" ("b_id")"#])
    #expect(
      plan.tables[0].createStatement == #"""
        CREATE TABLE "main"."a" (
          "id" INTEGER NOT NULL,
          "b_id" integer,
          PRIMARY KEY ("id"),
          CONSTRAINT "a_b" FOREIGN KEY ("b_id") REFERENCES "b" ("id"),
          CONSTRAINT "positive" CHECK ("id" > 0)
        )
        """#)
    let checked = try CopyObjectsDDLCheck.check(plan.editableDDL, plan: plan)
    #expect(checked.prelude.map(\.createsTable) == [nil, "a", "b"])
    #expect(checked.postRows == plan.indexStatements)
  }

  @Test("A UNIQUE constraint is not planned again as an index; indexes come before foreign keys")
  func uniqueAndForeignKey() throws {
    let users = Self.table(
      "users", schema: "app", columns: [("id", "int")], constraints: [Self.primaryKey("id")])
    let orders = Self.table(
      "orders", schema: "app", columns: [("id", "int"), ("user_id", "int"), ("code", "int")],
      constraints: [
        Self.primaryKey("id"),
        Constraint(name: "code", kind: .unique, columns: ["code"]),
        Self.foreignKey("fk_user", "user_id", schema: "app", to: "users"),
      ],
      indexes: [Self.index("code", ["code"], unique: true), Self.index("fk_user", ["user_id"])])
    let plan = try CopyObjectsPlanner.plan(
      [orders, users], source: Self.mysql, target: .postgresql, targetSchema: "public",
      existingNames: [])
    #expect(plan.tables[0].draft.constraints.contains { $0.kind == .unique })
    #expect(
      plan.postRowStatements == [
        #"CREATE INDEX "fk_user" ON "public"."orders" ("user_id")"#,
        #"ALTER TABLE "public"."orders" ADD CONSTRAINT "fk_user" FOREIGN KEY ("user_id") REFERENCES "public"."users" ("id")"#,
      ])
    // The same tables planned for a MySQL target pass the check unedited
    let mysqlPlan = try CopyObjectsPlanner.plan(
      [orders, users], source: Self.mysql, target: Self.mysql, targetSchema: "copy",
      existingNames: [])
    let checked = try CopyObjectsDDLCheck.check(mysqlPlan.editableDDL, plan: mysqlPlan)
    #expect(checked.prelude.map(\.createsTable) == ["orders", "users"])
    #expect(checked.postRows == mysqlPlan.postRowStatements)
    #expect(checked.postRows.count == 2)
  }

  @Test("A PostgreSQL table with a foreign key lands in SQLite's main with an inline reference")
  func postgresToSQLite() throws {
    let plan = try CopyObjectsPlanner.plan(
      Self.cycle(), source: .postgresql, target: Self.sqlite, targetSchema: "main",
      existingNames: [])
    let child = try #require(plan.tables.first)
    #expect(child.draft.schema == "main")
    let reference = try #require(
      child.draft.constraints.compactMap { constraint -> TableStructure.ForeignKeyReference? in
        if case .foreignKey(let reference) = constraint.kind { reference } else { nil }
      }.first)
    #expect(reference.schema == "main")
    #expect(child.createStatement.hasPrefix(#"CREATE TABLE "main"."a" ("#))
    #expect(child.createStatement.contains(#"REFERENCES "b" ("id")"#))
  }

  @Test("Repeated MySQL index names become distinct on PostgreSQL; FULLTEXT is skipped")
  func repeatedIndexNames() throws {
    let tables = ["a", "b"].map { name in
      Self.table(
        name, schema: "shop", columns: [("id", "int"), ("user_id", "int"), ("email", "text")],
        constraints: [
          Self.primaryKey("id"), Constraint(name: "email", kind: .unique, columns: ["email"]),
        ],
        indexes: [
          Self.index("user_id", ["user_id"]), Self.index("email", ["email"], unique: true),
          Self.index("body", ["email"], method: "FULLTEXT"),
        ])
    }
    let plan = try CopyObjectsPlanner.plan(
      tables, source: Self.mysql, target: .postgresql, targetSchema: "public", existingNames: [])
    let uniqueNames = plan.tables.flatMap { table in
      table.draft.constraints.compactMap { $0.kind == .unique ? $0.name : nil }
    }
    let indexNames = plan.indexStatements.compactMap { statement in
      statement.split(separator: "\"").dropFirst().first.map(String.init)
    }
    let names = uniqueNames + indexNames
    #expect(names.count == 4)
    #expect(Set(names).count == 4)
    #expect(plan.indexStatements.allSatisfy { !$0.contains("body") })
    #expect(plan.warnings.contains { $0.contains("\"body\"") && $0.contains("FULLTEXT") })
  }

  @Test("Index order: PostgreSQL keeps DESC NULLS LAST; SQLite drops NULLS, MySQL 5.7 DESC")
  func indexOrder() throws {
    let tables = [
      Self.table(
        "events", columns: [("id", "integer"), ("at", "timestamp")],
        constraints: [Self.primaryKey("id")],
        indexes: [
          Self.index(
            "events_at", ["at", "id"],
            order: [.init(descending: true, nullsFirst: false), .init(descending: false)])
        ])
    ]
    let plan = { (target: Engine, schema: String) in
      try CopyObjectsPlanner.plan(
        tables, source: .postgresql, target: target, targetSchema: schema, existingNames: [])
    }
    let postgres = try plan(.postgresql, "copy")
    #expect(
      postgres.indexStatements == [
        #"CREATE INDEX "events_at" ON "copy"."events" ("at" DESC NULLS LAST, "id")"#
      ])
    #expect(postgres.warnings.isEmpty)
    #expect(
      try CopyObjectsDDLCheck.check(postgres.editableDDL, plan: postgres).postRows
        == postgres.indexStatements)
    let sqlite = try plan(Self.sqlite, "main")
    #expect(
      sqlite.indexStatements == [#"CREATE INDEX "main"."events_at" ON "events" ("at" DESC, "id")"#])
    #expect(sqlite.warnings.count == 1)
    #expect(sqlite.warnings.contains { $0.contains("\"events_at\"") && $0.contains("NULLS") })
    #expect(
      try CopyObjectsDDLCheck.check(sqlite.editableDDL, plan: sqlite).postRows
        == sqlite.indexStatements)
    let mysql57 = try plan(
      .mysql(MySQLServerInfo(flavor: .mysql, major: 5, minor: 7, patch: 44)), "shop")
    #expect(mysql57.indexStatements == ["CREATE INDEX `events_at` ON `shop`.`events` (`at`, `id`)"])
    #expect(mysql57.warnings.contains { $0.contains("\"events_at\"") && $0.contains("DESC") })
    // MySQL 8 keeps DESC
    #expect(try plan(Self.mysql, "shop").indexStatements[0].contains("`at` DESC, `id`"))
  }

  @Test("MySQL target: repeated foreign-key names become distinct and SET DEFAULT is dropped")
  func mysqlForeignKeyNames() throws {
    let owner = Self.table("p", columns: [("id", "integer")], constraints: [Self.primaryKey("id")])
    let children = ["a", "b"].map { name in
      Self.table(
        name, columns: [("id", "integer"), ("p_id", "integer")],
        constraints: [
          Self.primaryKey("id"),
          Constraint(
            name: "owner_fk",
            kind: .foreignKey(
              TableStructure.ForeignKeyReference(
                schema: "public", table: "p", columns: ["id"], onUpdate: .cascade,
                onDelete: .setDefault)),
            columns: ["p_id"]),
        ])
    }
    let plan = try CopyObjectsPlanner.plan(
      [owner] + children, source: .postgresql, target: Self.mysql, targetSchema: "shop",
      existingNames: [])
    #expect(plan.foreignKeyStatements.count == 2)
    #expect(plan.foreignKeyStatements[0].contains("CONSTRAINT `owner_fk`"))
    #expect(plan.foreignKeyStatements[1].contains("CONSTRAINT `b_owner_fk`"))
    #expect(plan.foreignKeyStatements.allSatisfy { !$0.contains("SET DEFAULT") })
    #expect(plan.foreignKeyStatements.allSatisfy { $0.contains("ON UPDATE CASCADE") })
    #expect(plan.warnings.filter { $0.contains("SET DEFAULT") }.count == 2)
  }

  // MARK: - DDL check

  private static func editablePlan() throws -> CopyObjectsPlan {
    let users = table(
      "users", columns: [("id", "integer"), ("name", "text")],
      constraints: [primaryKey("id")], indexes: [index("users_name", ["name"])])
    return try CopyObjectsPlanner.plan(
      [users] + cycle(), source: .postgresql, target: .postgresql, targetSchema: "public",
      existingNames: [])
  }

  @Test("A type edit inside a planned CREATE TABLE passes")
  func typeEditPasses() throws {
    let plan = try Self.editablePlan()
    let edited = plan.editableDDL.replacingOccurrences(
      of: #""name" text"#, with: #""name" character varying(80) NOT NULL"#)
    #expect(edited != plan.editableDDL)
    let checked = try CopyObjectsDDLCheck.check(edited, plan: plan)
    #expect(checked.prelude.map(\.createsTable) == ["users", "a", "b"])
    #expect(checked.prelude[0].sql.contains("character varying(80)"))
    #expect(checked.postRows == plan.postRowStatements)
  }

  @Test(
    "A renamed column, a DROP or a statement on another table is refused",
    arguments: [
      (#""name" text"#, #""full_name" text"#),
      (#"CREATE INDEX "users_name" ON "public"."users" ("name")"#, #"DROP TABLE "public"."a""#),
      (#"ON "public"."users" ("name")"#, #"ON "public"."accounts" ("name")"#),
    ])
  func refused(find: String, replace: String) throws {
    let plan = try Self.editablePlan()
    let edited = plan.editableDDL.replacingOccurrences(of: find, with: replace)
    #expect(edited != plan.editableDDL)
    #expect(throws: CopyObjectsDDLCheck.Refusal.self) {
      try CopyObjectsDDLCheck.check(edited, plan: plan)
    }
  }

  // MARK: - Unsafe expressions

  private static func users(
    check: String? = nil, indexKey: Index.Key? = nil
  ) -> CopyObjectsPlanner.SourceTable {
    var constraints = [primaryKey("id")]
    if let check {
      constraints.append(Constraint(name: "guarded", kind: .check(check), columns: []))
    }
    var indexes: [Index] = []
    if let indexKey {
      indexes.append(
        Index(
          name: "by_key", keys: [indexKey], isUnique: false, isPrimary: false, method: nil,
          isPartial: false, predicate: nil))
    }
    return table(
      "users", columns: [("id", "integer"), ("name", "text"), ("status", "text")],
      constraints: constraints, indexes: indexes)
  }

  @Test(
    "A CHECK that calls an unsafe function or has a subquery is skipped with a warning",
    arguments: [
      "pg_read_file('/etc/passwd') <> ''",
      "lo_export(16385, '/tmp/out') > 0",
      "dblink_exec('host=evil', 'DROP TABLE x') <> ''",
      #""pg_read_file"('/etc/passwd') <> ''"#,
      "pg_catalog.lower(name) <> ''",
      "(name)::text <> evil(1)",
      "id IN (SELECT 1)",
      "length(name) > (WITH x AS (SELECT 1) SELECT 2)",
      // Attribute notation calls the function: (name).length is length(name)
      "(name).length > 0",
      "name.pg_sleep IS NULL",
      #""name"."pg_sleep" IS NULL"#,
    ])
  func unsafeCheckSkipped(check: String) throws {
    let plan = try CopyObjectsPlanner.plan(
      [Self.users(check: check)], source: .postgresql, target: .postgresql,
      targetSchema: "public", existingNames: [])
    #expect(!plan.tables[0].createStatement.contains("CHECK"))
    #expect(plan.warnings.contains { $0.contains(#""guarded" is skipped"#) })
  }

  @Test(
    "An allowlisted CHECK is copied",
    arguments: [
      "length(name) > 0",
      "((status)::text = ANY ((ARRAY['a'::character varying, 'b'::character varying])::text[]))",
      "CAST(id AS numeric(10,2)) > 0 AND upper(btrim(name)) <> ''",
      "id > 1.5 AND id < .5",
    ])
  func allowlistedCheckCopied(check: String) throws {
    let plan = try CopyObjectsPlanner.plan(
      [Self.users(check: check)], source: .postgresql, target: .postgresql,
      targetSchema: "public", existingNames: [])
    #expect(plan.tables[0].createStatement.contains("CHECK (\(check))"))
    #expect(plan.warnings.isEmpty, "\(plan.warnings)")
  }

  @Test(
    "SQLite: a CHECK or index expression that loads code, reads a file or a table is skipped",
    arguments: ["load_extension('/tmp/x') IS NULL", "readfile('/etc/passwd') <> ''", "id IN users"])
  func sqliteUnsafeExpressionsSkipped(expression: String) throws {
    for source in [Self.users(check: expression), Self.users(indexKey: .expression(expression))] {
      let plan = try CopyObjectsPlanner.plan(
        [source], source: Self.sqlite, target: Self.sqlite, targetSchema: "main",
        existingNames: [])
      #expect(!plan.tables[0].createStatement.contains("CHECK"))
      #expect(plan.indexStatements.isEmpty)
      #expect(plan.warnings.contains { $0.contains("is skipped") }, "\(plan.warnings)")
    }
  }

  @Test("An index expression that calls an unsafe function is skipped; lower(name) is copied")
  func indexExpressions() throws {
    let unsafe = try CopyObjectsPlanner.plan(
      [Self.users(indexKey: .expression("pg_read_file(name)"))], source: .postgresql,
      target: .postgresql, targetSchema: "public", existingNames: [])
    #expect(unsafe.indexStatements.isEmpty)
    #expect(unsafe.warnings.contains { $0.contains(#""by_key" is skipped"#) })
    let attribute = try CopyObjectsPlanner.plan(
      [Self.users(indexKey: .expression("(name).pg_read_file"))], source: .postgresql,
      target: .postgresql, targetSchema: "public", existingNames: [])
    #expect(attribute.indexStatements.isEmpty)
    #expect(attribute.warnings.contains { $0.contains(#""by_key" is skipped"#) })
    let safe = try CopyObjectsPlanner.plan(
      [Self.users(indexKey: .expression("lower(name)"))], source: .postgresql,
      target: .postgresql, targetSchema: "public", existingNames: [])
    #expect(
      safe.indexStatements == [#"CREATE INDEX "by_key" ON "public"."users" ((lower(name)))"#])
  }

  @Test("MySQL target: a foreign-key name the target database already has is renamed")
  func knownConstraintNames() throws {
    let plan = try CopyObjectsPlanner.plan(
      Self.cycle(), source: .postgresql, target: Self.mysql, targetSchema: "shop",
      existingNames: ["b_a"], existingConstraintNames: ["A_B"])
    #expect(plan.foreignKeyStatements[0].contains("CONSTRAINT `a_a_b`"))
    // A table name is not a constraint name
    #expect(plan.foreignKeyStatements[1].contains("CONSTRAINT `b_a`"))
  }

  @Test("Hostile identifiers stay quoted in the DDL, the identity restart and the source read")
  func hostileIdentifiers() throws {
    let name = #"t"x`;'"#
    let column = #"c"`;'"#
    var hostile = Self.table(
      name, columns: [(column, "integer"), ("v", "text")], constraints: [Self.primaryKey(column)])
    hostile.structure.columns[0].defaultExpression = "nextval('s'::regclass)"
    let plan = try CopyObjectsPlanner.plan(
      [hostile], source: .postgresql, target: .postgresql, targetSchema: "public",
      existingNames: [])
    #expect(plan.tables[0].createStatement.hasPrefix(#"CREATE TABLE "public"."t""x`;'" ("#))
    #expect(plan.tables[0].createStatement.contains(#""c""`;'" integer GENERATED"#))
    // The unedited DDL is one statement per table and passes the check
    let checked = try CopyObjectsDDLCheck.check(plan.editableDDL, plan: plan)
    #expect(checked.prelude.map(\.createsTable) == [name])
    #expect(
      try plan.identityRestartStatements() == [
        #"SELECT setval(pg_get_serial_sequence('"public"."t""x`;''"', 'c"`;'''), "#
          + #"GREATEST(COALESCE(MAX("c""`;'"), 0), 0) + 1, false) FROM "public"."t""x`;'""#
      ])
    // The source read of the same table on MySQL
    var mysqlSource = hostile
    mysqlSource.structure.schema = "shop"
    mysqlSource.structure.columns[0].defaultExpression = nil
    let mysqlPlan = try CopyObjectsPlanner.plan(
      [mysqlSource], source: Self.mysql, target: Self.sqlite, targetSchema: "main",
      existingNames: [])
    let read = try CopyObjectsTableRead(
      mysqlPlan.tables[0], source: Self.mysql, target: Self.sqlite)
    #expect(
      read.select(after: ["7"], offset: 0).sql
        == #"SELECT CONCAT('v', CAST(`c"``;'` AS CHAR)), CONCAT('v', CAST(`v` AS CHAR)), "#
        + #"CONCAT('v', CAST(`c"``;'` AS CHAR)) FROM `shop`.`t"x``;'` "#
        + #"WHERE `c"``;'` > CAST(? AS DECIMAL(65,0)) ORDER BY `c"``;'` LIMIT 500"#)
  }

  @Test("PostgreSQL: the run's prelude pins search_path first, as one session statement")
  func postgresPreludePinsSearchPath() throws {
    let plan = try Self.usersPlan(target: .postgresql)
    let checked = try CopyObjectsDDLCheck.check(plan.editableDDL, plan: plan)
    let prelude = CopyObjectsRun.transactionalPrelude(target: .postgresql, checked: checked)
    #expect(prelude.first == "SET LOCAL search_path = pg_catalog, pg_temp")
    #expect(prelude.count == 2)
    let classified = SQLStatementClassifier.classify(prelude[0], dialect: .postgresql)
    #expect(classified.count == 1)
    // SQLite keeps its PRAGMA first; MySQL gets no framing statement
    let sqlitePlan = try Self.usersPlan(target: Self.sqlite)
    let sqliteChecked = try CopyObjectsDDLCheck.check(sqlitePlan.editableDDL, plan: sqlitePlan)
    #expect(
      CopyObjectsRun.transactionalPrelude(target: Self.sqlite, checked: sqliteChecked).first
        == CopyObjectsPlan.sqliteDeferForeignKeys)
  }

  @Test(
    "A MySQL string default with a backslash is dropped, a combining mark after it included",
    arguments: [#"'a\\b'"#, "'a\\\u{301}b'"])
  func mysqlBackslashDefaultDropped(_ literal: String) throws {
    var source = Self.table("t", schema: "shop", columns: [("v", "varchar")])
    source.structure.columns[0].columnType = "varchar(10)"
    source.structure.columns[0].defaultExpression = literal
    let plan = try CopyObjectsPlanner.plan(
      [source], source: Self.mysql, target: .postgresql, targetSchema: "public",
      existingNames: [])
    #expect(!plan.editableDDL.contains("DEFAULT"), "\(plan.editableDDL)")
    #expect(plan.warnings.contains { $0.contains("is not copied") }, "\(plan.warnings)")
  }

  // MARK: - DDL check refusals

  /// users (with an index on name), on `target`
  private static func usersPlan(target: Engine = .postgresql) throws -> CopyObjectsPlan {
    let schema =
      switch target {
      case .mysql: "shop"
      case .sqlite: "main"
      default: "public"
      }
    return try CopyObjectsPlanner.plan(
      [Self.users(indexKey: .column("name"))], source: .postgresql, target: target,
      targetSchema: schema, existingNames: [])
  }

  /// How a test edits the planned DDL
  enum Edit: Sendable, CustomTestStringConvertible {
    /// Replace text inside the first CREATE TABLE only
    case create(String, String)
    /// Replace text in the whole DDL
    case replace(String, String)
    /// Add a statement at the end
    case append(String)

    var testDescription: String {
      switch self {
      case .create(let find, let replace), .replace(let find, let replace):
        "\(find) -> \(replace)"
      case .append(let statement): statement
      }
    }

    func apply(to plan: CopyObjectsPlan) -> String {
      let ddl = plan.editableDDL
      switch self {
      case .create(let find, let replace):
        let create = plan.tables[0].createStatement
        return ddl.replacingOccurrences(
          of: create, with: create.replacingOccurrences(of: find, with: replace))
      case .replace(let find, let replace):
        return ddl.replacingOccurrences(of: find, with: replace)
      case .append(let statement):
        return ddl + "\n\n" + statement + ";"
      }
    }
  }

  static let postgresRefusals: [Edit] = [
    .create(#""name" text"#, "\"name\" text -- note\n"),
    .create(#""name" text"#, #""name" text /* note */"#),
    .append(#"ALTER TABLE "public"."users" ADD CONSTRAINT "d" CHECK ($$x$$ <> '')"#),
    .append(#"ALTER TABLE "public"."users" ADD CONSTRAINT "d" CHECK (name <> 'a\b')"#),
    .append("SELECT 1"),
    .append(#"DELETE FROM "public"."users""#),
    .replace(
      #"CREATE TABLE "public"."users" ("#,
      #"CREATE TABLE "public"."users" AS SELECT 1 AS id, ("#),
    .create("\n)", "\n) INHERITS (\"other\")"),
    .append(#"CREATE TABLE "public"."users" ("id" integer, "name" text, "status" text)"#),
    .append(
      #"ALTER TABLE "public"."users" ADD CONSTRAINT "f" FOREIGN KEY ("id") REFERENCES "public"."other" ("id")"#
    ),
    .append(#"ALTER TABLE "public"."users" ADD COLUMN "x" integer"#),
    .append(
      #"ALTER TABLE "public"."users" ADD CONSTRAINT "u" UNIQUE ("name"), ADD CONSTRAINT "v" UNIQUE ("id")"#
    ),
    .replace(#"ON "public"."users""#, #"ON "db"."public"."users""#),
    // Unsafe expressions
    .create(#""name" text"#, #""name" text CHECK (pg_read_file('/etc/passwd') <> '')"#),
    .create(#""name" text"#, #""name" text, CONSTRAINT "c" CHECK ("pg_read_file"('/x') <> '')"#),
    .append(
      #"ALTER TABLE "public"."users" ADD CONSTRAINT "c" CHECK (lo_export(1, '/tmp/x') > 0)"#),
    .append(#"ALTER TABLE "public"."users" ADD CONSTRAINT "c" CHECK ("id" IN (SELECT 1))"#),
    .replace(#"("name");"#, #"(pg_read_file("name"));"#),
    .replace(#"("name");"#, #"("name") WHERE dblink_exec('x') = '';"#),
    .replace(#"("name");"#, #"((pg_catalog.lower("name")));"#),
    // Attribute notation and qualified names call functions
    .create(#""name" text"#, #""name" text CHECK (("name").length > 0)"#),
    .append(#"ALTER TABLE "public"."users" ADD CONSTRAINT "c" CHECK (name.pg_sleep IS NULL)"#),
    .replace(#"("name");"#, #"((("name").pg_read_file));"#),
    .replace(#"("name");"#, #"("name") WHERE "name"."pg_sleep" IS NULL;"#),
    // Column expressions and identity options
    .create(#""name" text"#, #""name" text GENERATED ALWAYS AS (pg_read_file('/x')) STORED"#),
    .create(#""name" text"#, #""name" text DEFAULT (pg_read_file('/x'))"#),
    .create(#""name" text"#, #""name" float8 DEFAULT ('1'::float8).pg_sleep"#),
    .create(#""name" text"#, #""name" bigint GENERATED BY DEFAULT AS IDENTITY (SEQUENCE NAME s)"#),
    .create(
      #""name" text"#, #""name" bigint GENERATED BY DEFAULT AS IDENTITY (SEQUENCE NAME x.s)"#),
    .create(
      #""name" text"#,
      #""name" bigint GENERATED BY DEFAULT AS IDENTITY (START WITH (SELECT 1))"#),
    // A call at a column's or constraint's own level: a DEFAULT runs on every later INSERT
    .create(#""name" text"#, #""name" text DEFAULT pg_sleep(1)"#),
    .create(#""name" text"#, #""name" bigint DEFAULT nextval('s')"#),
    .create(#""name" text"#, #""name" text DEFAULT 'a' || pg_sleep(1)"#),
    .create(#""name" text"#, #""name" text DEFAULT '1'::text || pg_sleep(1)"#),
    .create(#""name" text"#, #""name" text DEFAULT '1'::int AND pg_sleep(1)"#),
    .create(#""name" text"#, #""name" text DEFAULT "pg_sleep"(1)"#),
    .create(#""name" text"#, #""name" timestamptz DEFAULT pg_catalog.now()"#),
    .create(#""name" text"#, #""name" text, CONSTRAINT "c" UNIQUE pg_sleep (1)"#),
    .append(#"ALTER TABLE "public"."users" ADD CONSTRAINT "u" UNIQUE USING INDEX "users_name""#),
  ]

  @Test(
    "The DDL check refuses edits that do more than build the planned tables",
    arguments: postgresRefusals)
  func postgresRefused(_ edit: Edit) throws {
    let plan = try Self.usersPlan()
    let edited = edit.apply(to: plan)
    #expect(edited != plan.editableDDL, "\(plan.editableDDL)")
    #expect(throws: CopyObjectsDDLCheck.Refusal.self) {
      try CopyObjectsDDLCheck.check(edited, plan: plan)
    }
  }

  static let mysqlRefusals: [Edit] = [
    .create("`status` LONGTEXT", "`status` LONGTEXT /*! , `x` int */"),
    .create("`status` LONGTEXT", "`status` LONGTEXT /*M! , `x` int */"),
    .create("`status` LONGTEXT", "`status` LONGTEXT # note\n"),
    .append(#"ALTER TABLE `shop`.`users` ADD CONSTRAINT `c` CHECK (`name` <> 'a\'')"#),
    .append("ALTER TABLE `shop`.`users` ADD CONSTRAINT `c` CHECK (load_file('/etc/passwd') <> '')"),
    .append("ALTER TABLE `shop`.`users` ADD UNIQUE KEY `k` ((sleep(5)))"),
    // A CHECK is no key: no prefix length there
    .append("ALTER TABLE `shop`.`users` ADD CONSTRAINT `c` CHECK (sleep(5))"),
    .create("`status` LONGTEXT", "`status` LONGTEXT, KEY `k` ((sleep(5)))"),
    // A call at a column's own level
    .create("`status` LONGTEXT", "`status` DATETIME(6) DEFAULT sleep(1)"),
    .create("`status` LONGTEXT", "`status` DATETIME(6) ON UPDATE sleep(1)"),
    .create("`status` LONGTEXT", "`status` INT DEFAULT `sleep`(1)"),
    // MariaDB sequence calls take no parentheses
    .create("`status` LONGTEXT", "`status` INT DEFAULT NEXT VALUE FOR s"),
    .create("`status` LONGTEXT", "`status` INT DEFAULT (NEXT VALUE FOR s)"),
    .create("`status` LONGTEXT", "`status` INT DEFAULT PREVIOUS VALUE FOR s"),
    .create("`status` LONGTEXT", "`status` INT DEFAULT s.nextval"),
    .append("ALTER TABLE `shop`.`users` ADD CONSTRAINT `c` CHECK (NEXT VALUE FOR s > 0)"),
    // A backslash before a combining mark is one Character but still a backslash
    .append("ALTER TABLE `shop`.`users` ADD CONSTRAINT `c` CHECK (`name` <> 'a\\\u{301}')"),
  ]

  @Test(
    "MySQL: executable comments, backslash strings and unsafe expressions are refused",
    arguments: mysqlRefusals)
  func mysqlRefused(_ edit: Edit) throws {
    let plan = try Self.usersPlan(target: Self.mysql)
    let edited = edit.apply(to: plan)
    #expect(edited != plan.editableDDL, "\(plan.editableDDL)")
    #expect(throws: CopyObjectsDDLCheck.Refusal.self) {
      try CopyObjectsDDLCheck.check(edited, plan: plan)
    }
  }

  static let sqliteRefusals: [Edit] = [
    .replace("PRAGMA defer_foreign_keys = ON", "PRAGMA writable_schema = ON"),
    .replace("PRAGMA defer_foreign_keys = ON", "PRAGMA defer_foreign_keys = OFF"),
    .append(#"CREATE TRIGGER "t" AFTER INSERT ON "users" BEGIN DELETE FROM "users"; END"#),
    // Expressions that load code, read a file or read a table
    .create("\n)", ",\n  CONSTRAINT \"c\" CHECK (load_extension('/tmp/x') IS NULL)\n)"),
    .create("\n)", ",\n  CHECK (readfile('/etc/passwd') <> '')\n)"),
    .create("\n)", ",\n  CHECK (\"id\" IN \"users\")\n)"),
    .append(#"CREATE INDEX "main"."x" ON "users" ((load_extension('/tmp/x')))"#),
    .append(#"CREATE INDEX "main"."x" ON "users" (readfile("name"))"#),
  ]

  @Test("SQLite: another PRAGMA or a trigger body is refused", arguments: sqliteRefusals)
  func sqliteRefused(_ edit: Edit) throws {
    let plan = try Self.usersPlan(target: Self.sqlite)
    let edited = edit.apply(to: plan)
    #expect(edited != plan.editableDDL, "\(plan.editableDDL)")
    #expect(throws: CopyObjectsDDLCheck.Refusal.self) {
      try CopyObjectsDDLCheck.check(edited, plan: plan)
    }
  }

  @Test("An allowlisted CHECK, an expression index and a MySQL prefix length pass the check")
  func safeEditsPass() throws {
    let plan = try Self.usersPlan()
    for edit in [
      Edit.create(#""name" text"#, #""name" text CHECK (length("name") > 0)"#),
      .append(
        #"ALTER TABLE "public"."users" ADD CONSTRAINT "c" CHECK (CAST("id" AS numeric(10,2)) > 0)"#
      ),
      .replace(#"("name");"#, #"(lower("name")) WHERE "status" IN ('a', 'b');"#),
      .create(#""name" text"#, #""name" text CHECK ("id" > 1.5)"#),
      .create(#""name" text"#, #""name" numeric(10,2) DEFAULT 1.5"#),
      .create(
        #""name" text"#, #""name" bigint GENERATED BY DEFAULT AS IDENTITY (START 5 INCREMENT 1)"#),
      .create(
        #""name" text"#,
        #""name" bigint GENERATED BY DEFAULT AS IDENTITY (START WITH 100 INCREMENT BY 2)"#),
      .create(#""name" text"#, #""name" timestamptz DEFAULT now()"#),
      .create(
        #""name" text"#,
        #""name" timestamp(6) with time zone DEFAULT CURRENT_TIMESTAMP(6)"#),
      .create(#""name" text"#, #""name" text DEFAULT 'x' NOT NULL"#),
      .create(#""name" text"#, #""name" numeric(10,2) DEFAULT '1.5'::numeric(10,2)"#),
      .create(
        #""name" text"#, #""name" character varying(5) DEFAULT 'x'::character varying(5)"#),
    ] {
      let edited = edit.apply(to: plan)
      #expect(edited != plan.editableDDL, "\(edit.testDescription)")
      #expect(throws: Never.self, "\(edit.testDescription)") {
        try CopyObjectsDDLCheck.check(edited, plan: plan)
      }
    }
    // An index method passes unedited: before the keys on PostgreSQL, after them on MySQL
    for target in [Engine.postgresql, Self.mysql] {
      let source = Self.table(
        "by_method", columns: [("id", "integer"), ("name", "varchar(40)")],
        constraints: [Self.primaryKey("id")],
        indexes: [Self.index("by_name", ["name"], method: "btree")])
      let schema = target == .postgresql ? "public" : "shop"
      let withMethod = try CopyObjectsPlanner.plan(
        [source], source: target, target: target, targetSchema: schema, existingNames: [])
      #expect(withMethod.indexStatements.first?.contains("USING btree") == true)
      #expect(throws: Never.self, "\(withMethod.editableDDL)") {
        try CopyObjectsDDLCheck.check(withMethod.editableDDL, plan: withMethod)
      }
    }
    let mysqlPlan = try Self.usersPlan(target: Self.mysql)
    let prefixed = Edit.replace("(`name`);", "(`name`(20));").apply(to: mysqlPlan)
    #expect(prefixed != mysqlPlan.editableDDL, "\(mysqlPlan.editableDDL)")
    #expect(throws: Never.self) { try CopyObjectsDDLCheck.check(prefixed, plan: mysqlPlan) }
    for edit in [
      Edit.create(
        "`status` LONGTEXT",
        "`status` DATETIME(6) DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)"),
      .create("`status` LONGTEXT", "`status` DATETIME DEFAULT now()"),
      .create("`status` LONGTEXT", "`status` ENUM('a','b') DEFAULT 'a'"),
      .create("`status` LONGTEXT", "`status` INT(11) UNSIGNED DEFAULT 0"),
    ] {
      let edited = edit.apply(to: mysqlPlan)
      #expect(edited != mysqlPlan.editableDDL, "\(edit.testDescription)")
      #expect(throws: Never.self, "\(edit.testDescription)") {
        try CopyObjectsDDLCheck.check(edited, plan: mysqlPlan)
      }
    }
  }

  @Test("A column list that copies another table with LIKE is refused")
  func likeItemRefused() throws {
    let source = Self.table("liked", columns: [("like", "text")])
    let plan = try CopyObjectsPlanner.plan(
      [source], source: .postgresql, target: .postgresql, targetSchema: "public",
      existingNames: [])
    let edited = Edit.create(#""like" text"#, #"LIKE "public"."secret""#).apply(to: plan)
    #expect(edited != plan.editableDDL, "\(plan.editableDDL)")
    #expect(throws: CopyObjectsDDLCheck.Refusal.self) {
      try CopyObjectsDDLCheck.check(edited, plan: plan)
    }
  }

  @Test("Unedited plans with identities, an ENUM and literal defaults pass on every target")
  func plannedColumnsPass() throws {
    var postgres = Self.table(
      "pg_items",
      columns: [
        ("id", "integer"), ("name", "character varying(80)"), ("price", "numeric(10,2)"),
        ("at", "timestamp(6) with time zone"), ("parent_id", "integer"),
      ],
      constraints: [
        Self.primaryKey("id"), Self.foreignKey("pg_parent", "parent_id", to: "pg_items"),
      ])
    postgres.structure.columns[0].defaultExpression = "nextval('pg_items_id_seq'::regclass)"
    postgres.structure.columns[1].defaultExpression = "'x'::character varying"
    postgres.structure.columns[2].defaultExpression = "'1.50'::numeric(10,2)"
    var mysql = Self.table(
      "my_items", schema: "shop",
      columns: [("id", "int"), ("kind", "enum"), ("price", "decimal"), ("at", "datetime")],
      constraints: [Self.primaryKey("id")])
    mysql.structure.columns[0].columnType = "int(11) unsigned"
    mysql.structure.columns[0].identity = .autoIncrement
    mysql.structure.columns[1].columnType = "enum('a','b')"
    mysql.structure.columns[1].defaultExpression = "a"
    mysql.structure.columns[2].columnType = "decimal(10,2)"
    mysql.structure.columns[2].defaultExpression = "1.50"
    mysql.structure.columns[3].columnType = "datetime(6)"
    let cases: [(CopyObjectsPlanner.SourceTable, Engine)] = [
      (postgres, .postgresql), (mysql, Self.mysql),
    ]
    for (source, sourceEngine) in cases {
      for target in [Engine.postgresql, Self.mysql, Self.sqlite] {
        let schema =
          switch target {
          case .mysql: "shop"
          case .sqlite: "main"
          default: "public"
          }
        let plan = try CopyObjectsPlanner.plan(
          [source], source: sourceEngine, target: target, targetSchema: schema,
          existingNames: [])
        #expect(throws: Never.self, "\(plan.editableDDL)") {
          try CopyObjectsDDLCheck.check(plan.editableDDL, plan: plan)
        }
      }
    }
  }
}
