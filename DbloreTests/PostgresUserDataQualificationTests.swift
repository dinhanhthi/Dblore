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
}
