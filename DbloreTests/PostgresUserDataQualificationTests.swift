// PostgresUserDataQualificationTests.swift
// Statements the app builds on user tables run with the user's search_path, where a planted
// `=(integer,integer)` or `count` in an earlier schema would win over pg_catalog's. Each
// migrated builder's PostgreSQL output goes through `PostgresQualificationLint`; a bare
// comparison passes only on a column the builder was given a denylisted extension type for.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("PostgreSQL statements on user data are pg_catalog-qualified")
struct PostgresUserDataQualificationTests {
  /// One builder output: its PostgreSQL text and the column types the builder was given for
  /// columns that keep the bare operator
  private struct Statement {
    let name: String
    let sql: String
    var extensionTypedColumns: [String: String] = [:]
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
      // A citext column keeps the bare operator, for the column it was given
      Statement(
        name: "citext comparison",
        sql: "SELECT 1 WHERE "
          + dialect.comparison(column, .equal, "'a'", operand: .init(columnType: "citext")),
        extensionTypedColumns: ["c": "citext"]),
      Statement(
        name: "citext in list",
        sql: "SELECT 1 WHERE "
          + dialect.inList(
            column, ["'a'", "'b'"], negated: true, operand: .init(columnType: "public.citext")),
        extensionTypedColumns: ["c": "public.citext"]),
    ]
  }

  private func expectQualified(_ statements: [Statement]) {
    for statement in statements {
      let found = PostgresQualificationLint.violations(
        statement.sql, extensionTypedColumns: statement.extensionTypedColumns)
      #expect(
        found.isEmpty, "\(statement.name): \(found.joined(separator: "; "))\n\(statement.sql)")
    }
  }

  @Test("SQLDialect helpers write pg_catalog-qualified PostgreSQL")
  func dialectHelpersAreQualified() {
    expectQualified(Self.dialectHelpers)
  }

  @Test("A bare comparison passes only on a column given a denylisted extension type")
  func bareComparisonNeedsExtensionType() {
    let bare = Self.dialectHelpers.filter { !$0.extensionTypedColumns.isEmpty }
    #expect(bare.count == 2)
    for statement in bare {
      let column = statement.extensionTypedColumns.keys.first ?? ""
      let unknown = PostgresQualificationLint.violations(statement.sql)
      let qualifiedType = PostgresQualificationLint.violations(
        statement.sql, extensionTypedColumns: [column: "integer"])
      let otherColumn = PostgresQualificationLint.violations(
        statement.sql, extensionTypedColumns: ["d": "citext"])
      #expect(!unknown.isEmpty, "\(statement.name) passed with no column type")
      #expect(!qualifiedType.isEmpty, "\(statement.name) passed as integer")
      #expect(!otherColumn.isEmpty, "\(statement.name) passed on another column's type")
    }
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
    state.columnTypes = ["id": "integer", "name": "citext"]
    let extensionTyped = ["name": "citext"]
    expectQualified([
      Statement(name: "page", sql: state.pageSQL, extensionTypedColumns: extensionTyped),
      Statement(name: "count", sql: state.countSQL, extensionTypedColumns: extensionTyped),
    ])
    #expect(state.countSQL.hasSuffix(#""name" = 'a'"#))
  }

  @Test("Copy Objects' PostgreSQL source count, page read and keyset read are qualified")
  func copyObjectsSourceReadsAreQualified() throws {
    let read = try CopyObjectsRunTests.postgresRead(
      [
        ("id", "integer"), ("code", "text"), ("data", "bytea"), ("tags", "text[]"),
        ("at", "timestamp with time zone"),
      ], key: ["id", "code"], target: .sqlite(libraryVersion: SQLiteLibraryVersion.current))
    let citext = try CopyObjectsRunTests.postgresRead(
      [("name", "citext")], key: ["name"], target: .postgresql)
    let mixed = try CopyObjectsRunTests.postgresRead(
      [("id", "integer"), ("name", "citext")], key: ["id", "name"], target: .postgresql)
    // The citext key keeps the bare > and =, for the column it was given
    let extensionTyped = ["name": "citext"]
    let statements = [
      Statement(name: "copy count", sql: read.countSQL),
      Statement(name: "copy first read", sql: read.select(after: nil, offset: 0).sql),
      Statement(name: "copy keyset read", sql: read.select(after: ["1", "a"], offset: 0).sql),
      Statement(
        name: "copy citext keyset read", sql: citext.select(after: ["a"], offset: 0).sql,
        extensionTypedColumns: extensionTyped),
      Statement(
        name: "copy citext chain read", sql: mixed.select(after: ["1", "a"], offset: 0).sql,
        extensionTypedColumns: extensionTyped),
    ]
    for statement in statements {
      #expect(throws: Never.self) {
        try ReadOnlyQueryGuard.check(statement.sql, dialect: Self.dialect)
      }
      // The source table is named with its schema, `public` too
      #expect(statement.sql.contains(#" FROM "public"."t""#), "\(statement.name)")
    }
    expectQualified(statements)
    // The chain's bare > on "name" passes only through the citext column type
    #expect(PostgresQualificationLint.violations(statements[4].sql).count == 1)
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
    func column(_ name: String, _ type: String) -> TableStructure.Column {
      TableStructure.Column(ordinal: 1, name: name, dataType: type, isNullable: true)
    }
    let structure = TableStructure(
      tableID: .postgresql(oid: 1), schema: "public", name: "t",
      columns: [
        column("id", "integer"), column("code", "text"), column("name", "citext"),
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
    // The citext key keeps the bare =, for the column it was given
    let extensionTyped = ["name": "citext"]
    expectQualified(
      plan.reads.map {
        Statement(name: "import match read", sql: $0.sql, extensionTypedColumns: extensionTyped)
      } + [
        Statement(
          name: "import keyed update", sql: update.sql, extensionTypedColumns: extensionTyped)
      ])
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
    // The batch 11 read and update: an unqualified COUNT and text cast, bare = on every key
    let bareRead =
      #"SELECT v.pos, COUNT(*) FROM (VALUES (0, CAST($1 AS integer), CAST($2 AS text), "#
      + #"CAST($3 AS citext))) AS v(pos, k0, k1, k2) JOIN "public"."t" AS t "#
      + #"ON t."id" = v.k0 AND t."code" = v.k1 AND t."name" = v.k2 GROUP BY v.pos"#
    let bareUpdate =
      #"UPDATE "public"."t" SET "note" = $1 WHERE "id" = CAST($2 AS integer) "#
      + #"AND "code" = CAST($3 AS text) AND "name" = CAST($4 AS citext)"#
    #expect(
      PostgresQualificationLint.violations(bareRead, extensionTypedColumns: extensionTyped).count
        == 4)
    #expect(
      PostgresQualificationLint.violations(bareUpdate, extensionTypedColumns: extensionTyped)
        .count == 3)
  }
}
