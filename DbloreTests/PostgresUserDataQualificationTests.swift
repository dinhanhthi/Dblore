// PostgresUserDataQualificationTests.swift
// Statements the app builds on user tables run with the user's search_path, where a planted
// `=(integer,integer)` or `count` in an earlier schema would win over pg_catalog's. Each
// migrated builder's PostgreSQL output goes through `PostgresQualificationLint`; a bare
// comparison never passes, and an extension's `OPERATOR(<schema>.op)` only on a column whose
// type data the builder was given names that extension's schema.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("PostgreSQL statements on user data are pg_catalog-qualified")
struct PostgresUserDataQualificationTests {
  /// One builder output: its PostgreSQL text and the type data the builder was given for columns
  /// compared with their extension's operator
  private struct Statement {
    let name: String
    let sql: String
    var columnTypeData: [String: PostgresColumnType] = [:]
  }

  private static let dialect = SQLDialect.postgresql

  private static var dialectHelpers: [Statement] {
    let column = #""c""#
    let comparisons = SQLComparison.allCases.map {
      Statement(
        name: "comparison \($0.rawValue)",
        sql: "SELECT 1 WHERE " + dialect.comparison(column, $0, "'1'"))
    }
    let likes = [false, true].flatMap { negated in
      [false, true].flatMap { caseInsensitive in
        [nil, "'!'"].map { escape in
          Statement(
            name: "like negated \(negated) ci \(caseInsensitive) escape \(escape ?? "none")",
            sql: "SELECT 1 WHERE "
              + dialect.like(
                column: column, pattern: "'a%'", escape: escape, negated: negated,
                caseInsensitive: caseInsensitive))
        }
      }
    }
    let casts = [
      "text", "uuid", "integer", "character varying(20)", "timestamp with time zone",
      "numeric(10,2)", "mood", "public.mood", "text[]",
    ].map {
      Statement(name: "cast to \($0)", sql: "SELECT " + dialect.cast("'1'", to: $0))
    }
    return comparisons + likes + casts + [
      Statement(
        name: "in list", sql: "SELECT 1 WHERE " + dialect.inList(column, ["'1'", "'2'"])),
      Statement(
        name: "not in list",
        sql: "SELECT 1 WHERE " + dialect.inList(column, ["'1'", "'2'"], negated: true)),
      Statement(name: "function", sql: "SELECT " + dialect.function("octet_length", column)),
      Statement(name: "concatenation", sql: "SELECT " + dialect.concatenation(column, "'x'")),
      Statement(name: "NaN literal", sql: "SELECT " + dialect.literal(.double(.nan))),
      Statement(name: "-Infinity literal", sql: "SELECT " + dialect.literal(.double(-.infinity))),
    ]
  }

  private func expectQualified(_ statements: [Statement]) {
    for statement in statements {
      let found = PostgresQualificationLint.violations(
        statement.sql, columnTypeData: statement.columnTypeData)
      #expect(
        found.isEmpty, "\(statement.name): \(found.joined(separator: "; "))\n\(statement.sql)")
    }
  }

  @Test("SQLDialect helpers write pg_catalog-qualified PostgreSQL")
  func dialectHelpersAreQualified() {
    expectQualified(Self.dialectHelpers)
  }

  @Test("A bare comparison is a violation on every column, an extension type's too")
  func bareComparisonIsViolation() {
    let bare = [
      #"SELECT 1 WHERE "c" = 'a'"#, #"SELECT 1 WHERE ("c" <> 'a' AND "c" <> 'b')"#,
      #"SELECT 1 WHERE "c" > $1"#,
    ]
    let typeData: [[String: PostgresColumnType]] = [
      [:], ["c": Self.citext], ["c": Self.citextDomain],
    ]
    for sql in bare {
      for data in typeData {
        let found = PostgresQualificationLint.violations(sql, columnTypeData: data)
        #expect(!found.isEmpty, "\(sql) passed with \(data)")
      }
    }
  }

  /// citext owned by its extension in `public`
  private static let citext = PostgresColumnType(
    oid: 16_400, operand: .bare, castName: "public.citext", compareCast: nil,
    operatorSchema: "public")
  /// A domain over citext: compared cast to citext
  private static let citextDomain = PostgresColumnType(
    oid: 16_401, operand: .bare, castName: "public.cit_dom", compareCast: "public.citext",
    operatorSchema: "public")

  @Test("An extension's operator passes only after its column, with that column's schema")
  func extensionOperatorNeedsTypeData() {
    let column = #""c""#
    let statements = [
      Statement(
        name: "citext comparison",
        sql: "SELECT 1 WHERE " + Self.dialect.comparison(column, .equal, "'a'", type: Self.citext),
        columnTypeData: ["c": Self.citext]),
      Statement(
        name: "domain in list",
        sql: "SELECT 1 WHERE "
          + Self.dialect.inList(
            #""o"."c""#, ["'a'", "'b'"], negated: true, type: Self.citextDomain),
        columnTypeData: ["c": Self.citextDomain]),
    ]
    expectQualified(statements)
    // `evil.citext`: no extension owns it, so its data carries the qualified operand
    let evil = PostgresColumnType(
      oid: 16_402, operand: .qualified, castName: "evil.citext", compareCast: nil,
      operatorSchema: nil)
    let otherSchema = PostgresColumnType(
      oid: 16_400, operand: .bare, castName: "public.citext", compareCast: nil,
      operatorSchema: "evil")
    // No data, another column's, a qualified operand, another schema, the other cast form
    let wrongData: [[[String: PostgresColumnType]]] = [
      [[:], ["d": Self.citext], ["c": evil], ["c": otherSchema], ["c": Self.citextDomain]],
      [[:], ["d": Self.citextDomain], ["c": evil], ["c": otherSchema], ["c": Self.citext]],
    ]
    for (statement, wrong) in zip(statements, wrongData) {
      for data in wrong {
        let found = PostgresQualificationLint.violations(statement.sql, columnTypeData: data)
        #expect(!found.isEmpty, "\(statement.name) passed with \(data)")
      }
    }
    // A planted schema's operator on a citext column
    let planted = #"SELECT 1 WHERE "c" OPERATOR(evil.=) 'a'"#
    #expect(
      !PostgresQualificationLint.violations(planted, columnTypeData: ["c": Self.citext]).isEmpty)
  }

  @Test("TableFilter's PostgreSQL where clause is qualified")
  func tableFilterIsQualified() {
    let conditions: [FilterCondition] = [
      .init(column: "id", op: .equals, value: "1"),
      .init(column: "id", op: .greaterThanOrEqual, value: "1"),
      .init(column: "id", op: .in, value: "1, 2"),
      .init(column: "name", op: .like, value: "a%"),
      .init(column: "name", op: .notIlike, value: "a!%", likeEscape: "!"),
    ]
    let filters = conditions.map { condition in
      Statement(
        name: "filter \(condition.op.rawValue)",
        sql: "SELECT * FROM \"public\".\"t\" WHERE "
          + (TableFilter(conditions: [condition]).whereClause(dialect: Self.dialect) ?? ""))
    }
    expectQualified(filters)
  }

  @Test("A cell UPDATE keys its row with pg_catalog's =")
  func cellUpdateIsQualified() throws {
    let statement = try CellUpdateStatement.make(
      qualifiedName: "public.t",
      assignments: [(column: "a", value: "1"), (column: "b", value: nil)],
      primaryKeyColumns: ["id", "line"], rowData: ["id": .int(1), "line": .string("x")],
      updateOnly: true)
    expectQualified([Statement(name: "cell update", sql: statement.sql)])
    // The SET clause's assignments pass; a bare = in the WHERE or a SET value does not
    let bareKey = #"UPDATE public.t SET "a" = $1 WHERE "id" = $2"#
    let bareValue = #"UPDATE public.t SET "a" = "b" = $1 WHERE "id" OPERATOR(pg_catalog.=) $2"#
    #expect(PostgresQualificationLint.violations(bareKey).count == 1)
    #expect(PostgresQualificationLint.violations(bareValue).count == 1)
  }

  @Test("A keyless row's UPDATE and lazy cell read name it with pg_catalog's = and types")
  func rowLocatorIsQualified() throws {
    let locator = RowLocatorValues(texts: ["16384", "(0,2)", "700"])
    let update = try CellUpdateStatement.make(
      qualifiedName: #""public"."t""#, assignments: [(column: "a", value: "1")],
      primaryKeyColumns: [], rowData: ["a": .int(0)], updateOnly: true, dialect: .postgresql,
      rowLocator: .pgLocator, locator: locator)
    let source = LazyCellSource(
      relation: #""public"."t""#, keyColumns: [], dialect: .postgresql, rowLocator: .pgLocator
    ) { _, _ in QueryResult(columns: [], rows: [], rowCount: 0, executionTime: 0) }
    let read = try LazyCellLoader.statement(
      LazyCell(row: RowChangeSet.RowKey(locator: locator), column: "a"), source: source)
    expectQualified([
      Statement(name: "locator update", sql: update.sql),
      Statement(name: "locator lazy read", sql: read.sql),
    ])
  }

  @Test("Staged DELETE, UPDATE and INSERT name their rows with pg_catalog's =, bound and previewed")
  func rowChangesAreQualified() throws {
    let columns = [
      ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "line", type: "text"),
      ColumnInfo(name: "name", type: "text"), ColumnInfo(name: "body", type: "bytea"),
    ]
    let keyed = EditTarget(
      qualifiedName: #""public"."t""#, tableID: .postgresql(oid: 1),
      primaryKeyColumns: ["id", "line"], updateOnly: true)
    var set = RowChangeSet(target: keyed)
    set.stageDelete(row: RowChangeSet.RowKey(values: [.int(1), .string("a")]))
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(2), .string("b")]), column: "name",
      value: .string("x"), original: .string("y"))
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(2), .string("b")]), column: "body",
      value: .data(Data([0x01, 0xFF])), original: .null)
    try set.stageServerDefault(
      row: RowChangeSet.RowKey(values: [.int(3), .string("c")]), column: "name",
      original: .string("z"))
    set.stageInsert(values: ["id": .int(4), "line": .string("d"), "name": .string("w")])
    set.stageInsert(values: [:])

    let locator = EditTarget(
      qualifiedName: #""public"."t""#, tableID: .postgresql(oid: 1), primaryKeyColumns: [],
      rowLocator: .pgLocator)
    var keyless = RowChangeSet(target: locator)
    keyless.stageDelete(
      row: RowChangeSet.RowKey(locator: RowLocatorValues(texts: ["16384", "(0,1)", "742"])))
    try keyless.stageEdit(
      row: RowChangeSet.RowKey(locator: RowLocatorValues(texts: ["16384", "(0,2)", "743"])),
      column: "name", value: .string("x"), original: .string("y"))

    var statements: [Statement] = []
    for (name, changes, target) in [("keyed", set, keyed), ("locator", keyless, locator)] {
      let bound = try RowChangeSQLBuilder.statements(
        for: changes, target: target, columns: columns, dialect: Self.dialect)
      let preview = try RowChangeSQLBuilder.previewText(
        for: changes, target: target, columns: columns, dialect: Self.dialect)
      statements += bound.enumerated().map {
        Statement(name: "\(name) bound \($0.offset)", sql: $0.element.sql)
      }
      statements += preview.split(separator: "\n").enumerated().map {
        Statement(name: "\(name) preview \($0.offset)", sql: String($0.element))
      }
    }
    // Keyed: 1 DELETE, 2 UPDATEs, 2 INSERTs; locator: 1 DELETE, 1 UPDATE; each bound and previewed
    #expect(statements.count == 14)
    #expect(statements.filter { $0.sql.contains("OPERATOR(pg_catalog.=)") }.count == 10)
    expectQualified(statements)
  }

  @Test("The Rewind capture, the keyed lazy cell read and the dump read are qualified")
  func rowReadsAreQualified() throws {
    let target = EditTarget(
      qualifiedName: #""public"."t""#, tableID: .postgresql(oid: 1),
      primaryKeyColumns: ["id", "line"], updateOnly: true)
    let capture = try RewindCaptureSQL.selectStatement(
      target: target,
      columns: [
        RewindColumn(name: "id", typeName: "int4"), RewindColumn(name: "line", typeName: "text"),
        RewindColumn(name: "body", typeName: "bytea"),
      ],
      keyValues: [.int(1), .string("a")], engine: .postgresql)
    let source = LazyCellSource(
      relation: #""public"."t""#, keyColumns: ["id", "line"], dialect: .postgresql
    ) { _, _ in QueryResult(columns: [], rows: [], rowCount: 0, executionTime: 0) }
    let lazyRead = try LazyCellLoader.statement(
      LazyCell(row: RowChangeSet.RowKey(values: [.int(1), .string("a")]), column: "body"),
      source: source)
    let dump = try SQLDumpDataRenderer.selectStatement(
      SQLDumpDDL.TableInsert(
        schema: "public", name: "t", target: #""public"."t""#,
        columns: ["n", "b"].enumerated().map {
          TableStructure.Column(
            ordinal: $0.offset + 1, name: $0.element, dataType: "text", isNullable: true,
            defaultExpression: nil, identity: nil, generated: nil, comment: nil, columnType: nil,
            extra: nil, characterSet: nil, collation: nil)
        },
        overridingSystemValue: false, hasData: true),
      engine: .postgresql)
    #expect(capture.sql.contains("OPERATOR(pg_catalog.||)"))
    #expect(lazyRead.sql.components(separatedBy: "OPERATOR(pg_catalog.=)").count == 3)
    expectQualified([
      Statement(name: "rewind capture", sql: capture.sql),
      Statement(name: "keyed lazy read", sql: lazyRead.sql),
      Statement(name: "dump read", sql: dump),
    ])
    // The batch 11 capture text: a bare ||, an unqualified text cast and a bare = key
    let bare = #"SELECT 'v' || "id"::text FROM ONLY public.t WHERE "id" = $1 FOR UPDATE"#
    #expect(PostgresQualificationLint.violations(bare).count == 3)
  }

  @Test("Rewind undo UPDATE, DELETE and INSERT key and check rows with pg_catalog's =")
  func rewindUndoIsQualified() throws {
    let entry = RewindEntry(
      id: 1, connectionKey: "k", schema: "public", table: "t", qualifiedName: "public.t",
      engine: .postgresql, created: Date(timeIntervalSince1970: 0), state: .committed,
      editKind: .staged, statementCount: 1,
      columns: [
        RewindColumn(name: "id", typeName: "int4"), RewindColumn(name: "line", typeName: "text"),
        RewindColumn(name: "name", typeName: "citext"), RewindColumn(name: "doc", typeName: "json"),
      ],
      notCaptured: false, notRewindableReason: nil)
    let rows = [
      RewindRow(
        operation: .update, primaryKey: ["id": "1", "line": "a"],
        before: ["id": "1", "line": "a", "name": "x", "doc": nil],
        after: ["id": "1", "line": "a", "name": "X", "doc": "{}"]),
      RewindRow(
        operation: .delete, primaryKey: ["id": "2", "line": "b"],
        before: ["id": "2", "line": "b", "name": "y", "doc": nil], after: nil),
      RewindRow(
        operation: .insert, primaryKey: ["id": "3", "line": "c"], before: nil,
        after: ["id": "3", "line": "c", "name": "z", "doc": nil]),
    ]
    let plan = try RewindPlanner.plan(
      [(entry, rows)],
      tables: [
        RewindTableName(schema: "public", table: "t"): RewindTable(
          columns: ["id", "line", "name", "doc"], primaryKey: ["id", "line"],
          identityAlwaysColumns: ["id"])
      ],
      engine: .postgresql)
    // Newest row first: the DELETE undoing the INSERT, the INSERT, the UPDATE
    #expect(plan.statements.map { $0.sql.prefix(6) } == ["DELETE", "INSERT", "UPDATE"])
    // Keys of the DELETE and the UPDATE; the citext and json checks compare text forms
    #expect(
      plan.statements.map { $0.sql.components(separatedBy: "OPERATOR(").count - 1 } == [3, 0, 4])
    // A NULL image is checked as `IS NULL` on the text form, with no bind
    #expect(plan.statements[0].sql.contains(#""doc"::pg_catalog.text IS NULL"#))
    #expect(plan.statements[0].values == ["3", "c", "z"])
    expectQualified(
      plan.statements.enumerated().map {
        Statement(name: "undo bound \($0.offset)", sql: $0.element.sql)
      }
        + plan.previews.enumerated().map {
          Statement(name: "undo preview \($0.offset)", sql: $0.element)
        })
    // The batch 11 undo UPDATE: a bare = key, an unqualified text cast and DISTINCT FROM
    let bare =
      #"UPDATE "public"."t" SET "name" = $1 WHERE "id" = $2"#
      + #" AND "name"::text COLLATE "C" IS NOT DISTINCT FROM $3"#
    #expect(PostgresQualificationLint.violations(bare).count == 3)
  }

  @Test("A foreign-key lookup and its jump filter match with pg_catalog's =")
  func foreignKeyLookupIsQualified() throws {
    let key = ForeignKey(
      constraintName: "link_parent", sourceSchema: "main", sourceTable: "link",
      sourceColumns: ["parent_b", "parent_a"], targetSchema: "main", targetTable: "parent",
      targetColumns: ["b", "a"])
    let values: [String: CellValue] = ["parent_b": .data(Data([0x01])), "parent_a": .string("x")]
    let lookup = try #require(
      ForeignKeyLookup.lookupSQL(for: key, values: values, dialect: Self.dialect))
    let jump = try #require(
      ForeignKeyLookup.jumpFilter(for: key, values: values, dialect: Self.dialect))
    var viewer = DataViewerState(schema: "main", name: "parent", orderColumns: ["b"])
    viewer.filter = jump
    #expect(lookup.sql.components(separatedBy: "OPERATOR(pg_catalog.=)").count == 3)
    expectQualified([
      Statement(name: "fk lookup", sql: lookup.sql),
      Statement(name: "fk jump page", sql: viewer.pageSQL),
      Statement(name: "fk jump count", sql: viewer.countSQL),
    ])
    // The batch 11 lookup: a bare = per key column
    let bare = #"SELECT * FROM "main"."parent" WHERE "b" = :fk1 AND "a" = :fk2 LIMIT 2"#
    #expect(PostgresQualificationLint.violations(bare).count == 2)
  }

  @Test("Find a Value in Every Table casts, compares and matches with pg_catalog's")
  func crossTableSearchIsQualified() throws {
    let columns: [CrossTableSearchQueryBuilder.Column] = [
      .init(name: "id", type: "integer", isPrimaryKey: true),
      .init(name: "name", type: "citext"), .init(name: "note", type: "text"),
    ]
    let statements = try CrossTableSearchQueryBuilder.Mode.allCases.map { mode in
      let statement = try #require(
        try CrossTableSearchQueryBuilder.statement(
          schema: "public", table: "t", columns: columns, value: "a", mode: mode,
          dialect: Self.dialect))
      // Every searched column is compared as text, the citext one too
      #expect(statement.sql.components(separatedBy: "::pg_catalog.text ").count == 7)
      return Statement(name: "cross-table search \(mode.rawValue)", sql: statement.sql)
    }
    expectQualified(statements)
    // The batch 11 search: an unqualified text cast with a bare = or ILIKE
    let bare =
      #"SELECT "id", CASE WHEN CAST("id" AS text) = :v THEN 1"#
      + #" WHEN CAST("note" AS text) ILIKE :v ESCAPE '!' THEN 2 END FROM "public"."t""#
      + #" WHERE CAST("id" AS text) = :v LIMIT 50"#
    #expect(PostgresQualificationLint.violations(bare).count == 6)
  }

  @Test("A staged delete's cascade counts match keys with pg_catalog's = and count")
  func cascadeCountsAreQualified() throws {
    func key(
      _ name: String, _ child: String, _ sources: [String], _ parent: String,
      _ targets: [String], _ onDelete: ForeignKeyAction
    ) -> ForeignKey {
      ForeignKey(
        constraintName: name, sourceSchema: "public", sourceTable: child, sourceColumns: sources,
        targetSchema: "public", targetTable: parent, targetColumns: targets, onDelete: onDelete)
    }
    let keys = [
      key("orders_user_fk", "orders", ["user_id"], "users", ["id"], .cascade),
      // A composite key on cascaded rows, a key on a non-key column of the deleted rows
      key("lines_order_fk", "lines", ["o_id", "o_user"], "orders", ["id", "user_id"], .cascade),
      key("profiles_email_fk", "profiles", ["email"], "users", ["email"], .setNull),
      // A self-reference blocker, a RESTRICT key on a table a cascade also reaches (diamond)
      key("users_referrer_fk", "users", ["referrer_id"], "users", ["id"], .noAction),
      key("inv_order_fk", "invoices", ["order_id"], "orders", ["id"], .restrict),
      key("inv_user_fk", "invoices", ["user_id"], "users", ["id"], .cascade),
    ]
    let impact = CascadeImpactPlanner.impact(
      deletingFrom: "public", table: "users", keyColumns: ["id"], keys: [[.int(1)], [.int(2)]],
      foreignKeys: keys, dialect: Self.dialect)
    guard case .plan(let plan) = impact else {
      Issue.record("expected a plan, got \(impact)")
      return
    }
    // Every count, the blockers with their exclusions and the left-out rows they may block
    #expect(plan.steps.count == 8)
    #expect(plan.steps.allSatisfy { $0.sql.hasPrefix("SELECT pg_catalog.count(*) FROM ") })
    #expect(plan.steps.contains { $0.sql.contains(#"AND NOT COALESCE(("#) })
    #expect(
      plan.steps.contains {
        $0.sql.contains(#"("o_id", "o_user") OPERATOR(pg_catalog.=) ANY (SELECT "id", "user_id""#)
      })
    for step in plan.steps {
      #expect(throws: Never.self) { try ReadOnlyQueryGuard.check(step.sql, dialect: Self.dialect) }
    }
    expectQualified(
      plan.steps.enumerated().map {
        Statement(
          name: "cascade count \($0.offset) \($0.element.constraintName)", sql: $0.element.sql)
      })
    // The batch 11 counts: an unqualified COUNT, a bare IN list and a bare IN subquery
    let bare =
      #"SELECT COUNT(*) FROM "public"."lines" WHERE ("o_id", "o_user") IN "#
      + #"(SELECT "id", "user_id" FROM "public"."orders" WHERE "user_id" IN (:k1, :k2))"#
    #expect(PostgresQualificationLint.violations(bare).count == 3)
  }

  @Test("The data viewer's PostgreSQL page and count are qualified")
  func dataViewerIsQualified() {
    var state = DataViewerState(schema: "public", name: "t", orderColumns: ["id"])
    state.page = 2
    state.rowLocator = .pgLocator
    state.lazyColumns = [
      .init(name: "id", type: "integer", isPrimaryKey: true, isPrefixed: false),
      .init(name: "blob", type: "bytea", isPrimaryKey: false, isPrefixed: true),
    ]
    state.filter = TableFilter(conditions: [
      .init(column: "id", op: .greaterThan, value: "1"),
      .init(column: "name", op: .equals, value: "a"),
    ])
    state.columnTypeData = ["name": Self.citext]
    let typeData = ["name": Self.citext]
    expectQualified([
      Statement(name: "page", sql: state.pageSQL, columnTypeData: typeData),
      Statement(name: "count", sql: state.countSQL, columnTypeData: typeData),
    ])
    #expect(state.countSQL.hasSuffix(#""name" OPERATOR(public.=) 'a'"#))
  }

  @Test("Copy Objects' PostgreSQL source count, page read and keyset read are qualified")
  func copyObjectsSourceReadsAreQualified() throws {
    let read = try CopyObjectsRunTests.postgresRead(
      [
        ("id", "integer"), ("code", "text"), ("data", "bytea"), ("tags", "text[]"),
        ("at", "timestamp with time zone"),
      ], key: ["id", "code"], target: .sqlite(libraryVersion: SQLiteLibraryVersion.current))
    let citext = try CopyObjectsRunTests.postgresRead(
      [("name", "citext")], key: ["name"], target: .postgresql, types: ["name": Self.citext])
    let mixed = try CopyObjectsRunTests.postgresRead(
      [("id", "integer"), ("name", "citext")], key: ["id", "name"], target: .postgresql,
      types: ["name": Self.citext])
    let domain = try CopyObjectsRunTests.postgresRead(
      [("id", "integer"), ("name", "cit_dom")], key: ["id", "name"], target: .postgresql,
      types: ["name": Self.citextDomain])
    // The citext key compares with its extension's > and =, for the column it was given; the
    // domain over citext casts both sides to citext first
    let typeData = ["name": Self.citext]
    let statements = [
      Statement(name: "copy count", sql: read.countSQL),
      Statement(name: "copy first read", sql: read.select(after: nil, offset: 0).sql),
      Statement(name: "copy keyset read", sql: read.select(after: ["1", "a"], offset: 0).sql),
      Statement(
        name: "copy citext keyset read", sql: citext.select(after: ["a"], offset: 0).sql,
        columnTypeData: typeData),
      Statement(
        name: "copy citext chain read", sql: mixed.select(after: ["1", "a"], offset: 0).sql,
        columnTypeData: typeData),
      Statement(
        name: "copy domain chain read", sql: domain.select(after: ["1", "a"], offset: 0).sql,
        columnTypeData: ["name": Self.citextDomain]),
    ]
    for statement in statements {
      #expect(throws: Never.self) {
        try ReadOnlyQueryGuard.check(statement.sql, dialect: Self.dialect)
      }
      // The source table is named with its schema, `public` too
      #expect(statement.sql.contains(#" FROM "public"."t""#), "\(statement.name)")
    }
    expectQualified(statements)
    // The chains' extension operators on "name" pass only through that column's type data
    #expect(!PostgresQualificationLint.violations(statements[4].sql).isEmpty)
    #expect(!PostgresQualificationLint.violations(statements[5].sql).isEmpty)
    // The batch 11 reads: an unqualified COUNT, bare || and text casts, a bare row comparison
    let bareCount = #"SELECT COUNT(*) FROM "public"."t""#
    let bareRead =
      #"SELECT 'v' || "id"::text, 'v' || encode("data", 'hex') FROM "public"."t" "#
      + #"WHERE ("id", "code") > ($1, $2) ORDER BY "id", "code" LIMIT 500"#
    #expect(PostgresQualificationLint.violations(bareCount).count == 1)
    #expect(PostgresQualificationLint.violations(bareRead).count == 5)
  }

  @Test("A keyed import names its schema and casts, counts and compares keys qualified")
  func keyedImportIsQualified() throws {
    func column(
      _ name: String, _ type: String, _ data: PostgresColumnType? = nil
    ) -> TableStructure.Column {
      TableStructure.Column(
        ordinal: 1, name: name, dataType: type, isNullable: true, postgresType: data)
    }
    let structure = TableStructure(
      tableID: .postgresql(oid: 1), schema: "public", name: "t",
      columns: [
        column("id", "integer"), column("code", "text"), column("name", "citext", Self.citext),
        column("note", "character varying(20)"),
      ],
      indexes: [], constraints: [])
    let keyNames = ["id", "code", "name"]
    let names = keyNames + ["note"]
    let row: [String?] = ["1", "A", "Ada", "x"]
    let plan = try ImportMatchPlanner.plan(
      schema: "public", table: "t", keyColumns: keyNames, columns: names, rows: [row, row],
      structure: structure, dialect: Self.dialect)
    let keys = try keyNames.map { name in
      try ImportMatchPlanner.KeyColumn(
        try #require(structure.columns.first { $0.name == name }), dialect: Self.dialect)
    }
    let update = try ImportSQLBuilder.updateStatement(
      schema: "public", table: "t",
      columns: names.map { .init(name: $0, kind: $0 == "id" ? .integer : .text) }, row: row,
      keys: keys, dialect: Self.dialect)
    // The citext key compares with its extension's operator, for the column it was given
    let typeData = ["name": Self.citext]
    expectQualified(
      plan.reads.map {
        Statement(name: "import match read", sql: $0.sql, columnTypeData: typeData)
      } + [Statement(name: "import keyed update", sql: update.sql, columnTypeData: typeData)])
    // The table is named with its schema, `public` too: a bare "t" would resolve through the
    // user's search_path, where a same-named table or view could come first
    let columns = names.map { ImportSQLBuilder.Column(name: $0, kind: .text) }
    let create = try ImportSQLBuilder.createTable(
      schema: "public", table: "t", columns: columns, dialect: Self.dialect)
    let inserts = try ImportSQLBuilder.insertStatements(
      schema: "public", table: "t", columns: columns, rows: [row], dialect: Self.dialect)
    let summary = try ImportSQLBuilder.summaryText(
      createTable: create, schema: "public", table: "t", columns: names, rowCount: 1,
      dialect: Self.dialect)
    let matchSummary = try ImportSQLBuilder.matchSummaryText(
      schema: "public", table: "t", columns: names, update: update,
      counts: .init(inserts: 1, updates: 1, skips: 0, refused: 0), dialect: Self.dialect)
    #expect(plan.reads.allSatisfy { $0.sql.contains(#" JOIN "public"."t" AS t ON "#) })
    #expect(update.sql.hasPrefix(#"UPDATE "public"."t" SET "#))
    #expect(create.sql.hasPrefix(#"CREATE TABLE "public"."t" ("#))
    #expect(inserts.map { $0.sql.hasPrefix(#"INSERT INTO "public"."t" ("#) } == [true])
    #expect(
      summary.hasPrefix(#"CREATE TABLE "public"."t" ("#)
        && summary.contains(#"INSERT INTO "public"."t" ("#))
    #expect(
      matchSummary.contains(#"INSERT INTO "public"."t" ("#)
        && matchSummary.contains(#"UPDATE "public"."t" SET "#))
    // The batch 11 read and update: an unqualified COUNT and text cast, bare = on every key,
    // the citext key's too
    let bareRead =
      #"SELECT v.pos, COUNT(*) FROM (VALUES (0, CAST($1 AS integer), CAST($2 AS text), "#
      + #"CAST($3 AS citext))) AS v(pos, k0, k1, k2) JOIN "public"."t" AS t "#
      + #"ON t."id" = v.k0 AND t."code" = v.k1 AND t."name" = v.k2 GROUP BY v.pos"#
    let bareUpdate =
      #"UPDATE "public"."t" SET "note" = $1 WHERE "id" = CAST($2 AS integer) "#
      + #"AND "code" = CAST($3 AS text) AND "name" = CAST($4 AS citext)"#
    #expect(
      PostgresQualificationLint.violations(bareRead, columnTypeData: typeData).count == 5)
    #expect(
      PostgresQualificationLint.violations(bareUpdate, columnTypeData: typeData).count == 4)
  }

  @Test("A look-alike evil.citext column compares with pg_catalog's operators everywhere")
  func lookAlikeExtensionTypeIsQualified() throws {
    // A domain over text in `evil` named like the extension type: no extension owns it, so its
    // type data carries the qualified operand and no operator schema
    let evil = PostgresColumnType(
      oid: 16_402, operand: .qualified, castName: "evil.citext", compareCast: nil,
      operatorSchema: nil)
    let typeData = ["name": evil]
    let filter = TableFilter(conditions: [
      .init(column: "name", op: .equals, value: "a"),
      .init(column: "name", op: .in, value: "a, b"),
      .init(column: "name", op: .greaterThan, value: "a"),
    ]).whereClause(dialect: Self.dialect, columnTypeData: typeData)
    let column = TableStructure.Column(
      ordinal: 1, name: "name", dataType: "citext", isNullable: false, postgresType: evil)
    let note = TableStructure.Column(
      ordinal: 2, name: "note", dataType: "text", isNullable: true, postgresType: nil)
    let structure = TableStructure(
      tableID: .postgresql(oid: 1), schema: "public", name: "t", columns: [column, note],
      indexes: [], constraints: [])
    let plan = try ImportMatchPlanner.plan(
      schema: "public", table: "t", keyColumns: ["name"], columns: ["name", "note"],
      rows: [["Ada", "x"]], structure: structure, dialect: Self.dialect)
    let update = try ImportSQLBuilder.updateStatement(
      schema: "public", table: "t",
      columns: [.init(name: "name", kind: .text), .init(name: "note", kind: .text)],
      row: ["Ada", "x"], keys: [try ImportMatchPlanner.KeyColumn(column, dialect: Self.dialect)],
      dialect: Self.dialect)
    // Copy Objects knows no comparison that follows its order: read by position, no keyset
    let copy = try CopyObjectsRunTests.postgresRead(
      [("id", "integer"), ("name", "citext")], key: ["id", "name"], target: .postgresql,
      types: typeData)
    #expect(copy.readsByPosition)
    let copyPage = copy.select(after: nil, offset: 500).sql
    #expect(!copyPage.contains("WHERE"))
    let statements =
      [
        Statement(
          name: "filter", sql: #"SELECT * FROM "public"."t" WHERE "# + (filter ?? ""),
          columnTypeData: typeData),
        Statement(name: "import keyed update", sql: update.sql, columnTypeData: typeData),
        Statement(name: "copy count", sql: copy.countSQL, columnTypeData: typeData),
        Statement(name: "copy page", sql: copyPage, columnTypeData: typeData),
      ]
      + plan.reads.map {
        Statement(name: "import match read", sql: $0.sql, columnTypeData: typeData)
      }
    expectQualified(statements)
    for statement in statements {
      let operators = statement.sql.components(separatedBy: "OPERATOR(").count
      let catalog = statement.sql.components(separatedBy: "OPERATOR(pg_catalog.").count
      #expect(operators == catalog, "\(statement.name): \(statement.sql)")
    }
    #expect(filter?.contains(#""name" OPERATOR(pg_catalog.>) 'a'"#) == true)
    #expect(plan.reads.allSatisfy { $0.sql.contains(#"t."name" OPERATOR(pg_catalog.=) v.k0"#) })
    #expect(update.sql.contains(#""name" OPERATOR(pg_catalog.=) "#))
  }
}
