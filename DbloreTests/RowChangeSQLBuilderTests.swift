// RowChangeSQLBuilderTests.swift
// Bound SQL and preview text for staged inserts, deletes, and cell edits.

import Foundation
import Testing

@testable import Dblore

@Suite("Row change SQL builder")
struct RowChangeSQLBuilderTests {
  @Test("Statements run deletes, then updates, then inserts")
  func statementOrder() throws {
    let editTarget = target()
    var set = RowChangeSet(target: editTarget)
    set.stageDelete(row: RowChangeSet.RowKey(values: [.int(1)]))
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(2)]), column: "name", value: .string("b"),
      original: .string("a"))
    set.stageInsert(values: ["name": .string("c")])

    let sql = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql
    ).map(\.sql)
    #expect(sql.count == 3)
    #expect(sql[0].hasPrefix("DELETE "))
    #expect(sql[1].hasPrefix("UPDATE "))
    #expect(sql[2].hasPrefix("INSERT "))

    let lines = try RowChangeSQLBuilder.previewText(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql
    ).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.count == 3)
    #expect(lines[0].hasPrefix("DELETE "))
    #expect(lines[1].hasPrefix("UPDATE "))
    #expect(lines[2].hasPrefix("INSERT "))
    #expect(lines.allSatisfy { $0.hasSuffix(";") })
  }

  @Test("A composite primary key is AND-ed in key order with per-statement placeholders")
  func compositePrimaryKeyWhere() throws {
    let editTarget = target(primaryKeyColumns: ["order_id", "line_no"])
    var set = RowChangeSet(target: editTarget)
    set.stageDelete(row: RowChangeSet.RowKey(values: [.int(10), .int(2)]))

    let statements = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)
    #expect(statements.count == 1)
    #expect(
      statements[0].sql
        == #"DELETE FROM "t" WHERE "order_id" = $1 AND "line_no" = $2"#)
    #expect(statements[0].values == ["10", "2"])
  }

  @Test("A NULL primary-key component binds nil and the preview writes NULL")
  func nullPrimaryKeyBindsNil() throws {
    let editTarget = target(primaryKeyColumns: ["id", "sub"])
    var set = RowChangeSet(target: editTarget)
    set.stageDelete(row: RowChangeSet.RowKey(values: [.null, .string("a")]))
    let tableColumns = [
      ColumnInfo(name: "id", type: "int4"),
      ColumnInfo(name: "sub", type: "text"),
    ]

    let statements = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: tableColumns, dialect: .postgresql)
    #expect(statements.count == 1)
    #expect(statements[0].sql == #"DELETE FROM "t" WHERE "id" = $1 AND "sub" = $2"#)
    #expect(statements[0].values == [nil, "a"])
    #expect(statements[0].binds == [.null, .text("a")])
    #expect(!statements[0].sql.contains("'a'"))

    let preview = try RowChangeSQLBuilder.previewText(
      for: set, target: editTarget, columns: tableColumns, dialect: .postgresql)
    #expect(preview == #"DELETE FROM "t" WHERE "id" = NULL AND "sub" = 'a';"#)
  }

  @Test("A keyless UPDATE or DELETE throws and names the table instead of being dropped")
  func keylessChangeThrows() throws {
    let editTarget = target(primaryKeyColumns: [])
    var edit = RowChangeSet(target: editTarget)
    try edit.stageEdit(
      row: RowChangeSet.RowKey(values: []), column: "name", value: .string("b"),
      original: .string("a"))
    var delete = RowChangeSet(target: editTarget)
    delete.stageDelete(row: RowChangeSet.RowKey(values: []))
    for set in [edit, delete] {
      for dialect in [SQLDialect.mysql, .postgresql] {
        let error = #expect(throws: RowChangeError.self) {
          try RowChangeSQLBuilder.statements(
            for: set, target: editTarget, columns: columns(), dialect: dialect)
        }
        #expect(error?.message.contains(#""t""#) == true, "\(dialect)")
      }
    }
  }

  @Test("A PostgreSQL keyless row is named by tableoid, ctid and xmin, cast in bind order")
  func postgresLocatorWhere() throws {
    let editTarget = EditTarget(
      qualifiedName: #""public"."t""#, tableID: .postgresql(oid: 1), primaryKeyColumns: [],
      rowLocator: .pgLocator)
    var set = RowChangeSet(target: editTarget)
    // Two identical keyless rows: their locators tell them apart
    let first = RowChangeSet.RowKey(locator: RowLocatorValues(texts: ["16384", "(0,1)", "742"]))
    let second = RowChangeSet.RowKey(locator: RowLocatorValues(texts: ["16390", "(0,1)", "742"]))
    #expect(first != second)
    set.stageDelete(row: first)
    try set.stageEdit(row: second, column: "name", value: .string("b"), original: .string("a"))

    let statements = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)
    #expect(
      statements.map(\.sql) == [
        #"DELETE FROM "public"."t" WHERE tableoid = $1::oid AND ctid = $2::tid AND xmin = $3::xid"#,
        #"UPDATE "public"."t" SET "name" = $1 WHERE tableoid = $2::oid AND ctid = $3::tid"#
          + " AND xmin = $4::xid",
      ])
    #expect(statements[0].values == ["16384", "(0,1)", "742"])
    #expect(statements[1].values == ["b", "16390", "(0,1)", "742"])
    #expect(statements.allSatisfy { $0.expectedRows == 1 && $0.rowCheck == nil })
    #expect(
      try RowChangeSQLBuilder.previewText(
        for: set, target: editTarget, columns: columns(), dialect: .postgresql
      ).hasPrefix(
        #"DELETE FROM "public"."t" WHERE tableoid = '16384'::oid AND ctid = '(0,1)'::tid"#))
  }

  @Test("A SQLite keyless row is named by rowid and IS on its loaded typed, non-binary values")
  func sqliteLocatorWhere() throws {
    let editTarget = EditTarget(
      qualifiedName: #""main"."t""#, tableID: .sqlite(schema: "main", table: "t"),
      primaryKeyColumns: [],
      rowLocator: .sqliteRowid(alias: .underscoredRowid, matchColumns: ["b", "n", "bin"]))
    // `a` is untyped (BLOB affinity) so not a match column, `bin` holds bytes
    let row: [String: CellValue] = [
      "a": .int(1), "b": .double(2.5), "n": .null, "bin": .data(Data([1])), "name": .string("a"),
    ]
    var set = RowChangeSet(target: editTarget)
    set.stageDelete(row: RowChangeSet.RowKey(locator: RowLocatorValues(texts: ["7"], row: row)))
    try set.stageEdit(
      row: RowChangeSet.RowKey(locator: RowLocatorValues(texts: ["8"], row: row)), column: "name",
      value: .string("b"), original: .string("a"))

    let statements = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .sqlite)
    #expect(
      statements.map(\.sql) == [
        #"DELETE FROM "main"."t" WHERE _rowid_ = ?1 AND "b" IS ?2 AND "n" IS ?3"#,
        #"UPDATE "main"."t" SET "name" = ?1 WHERE _rowid_ = ?2 AND "b" IS ?3 AND "n" IS ?4"#,
      ])
    #expect(statements[0].values == ["7", "2.5", nil])
    #expect(statements[1].values == ["b", "8", "2.5", nil])
    // A locator does not fit another engine: refused, never a WHERE-less statement
    #expect(throws: RowChangeError.noRowLocator) {
      try RowChangeSQLBuilder.statements(
        for: set, target: editTarget, columns: columns(), dialect: .mysql)
    }
  }

  @Test("A single-cell UPDATE on a locator target takes the side locator, never 'no primary key'")
  func cellUpdateByLocator() throws {
    let rowData: [String: CellValue] = ["a": .int(1), "b": .double(2.5), "name": .string("x")]
    let postgres = try CellUpdateStatement.make(
      qualifiedName: #""public"."t""#, assignments: [(column: "name", value: "y")],
      primaryKeyColumns: [], rowData: rowData, updateOnly: true, dialect: .postgresql,
      rowLocator: .pgLocator, locator: RowLocatorValues(texts: ["16384", "(0,3)", "900"]))
    #expect(
      postgres.sql
        == #"UPDATE ONLY "public"."t" SET "name" = $1 WHERE tableoid = $2::oid"#
        + " AND ctid = $3::tid AND xmin = $4::xid")
    #expect(postgres.values == ["y", "16384", "(0,3)", "900"])
    #expect(postgres.rowCheck == nil)

    let sqlite = try CellUpdateStatement.make(
      qualifiedName: #""main"."t""#, assignments: [(column: "name", value: "y")],
      primaryKeyColumns: [], rowData: rowData, dialect: .sqlite,
      rowLocator: .sqliteRowid(alias: .rowid, matchColumns: ["b", "name"]),
      locator: RowLocatorValues(texts: ["5"], row: rowData))
    #expect(
      sqlite.sql
        == #"UPDATE "main"."t" SET "name" = ?1 WHERE rowid = ?2 AND "b" IS ?3 AND "name" IS ?4"#)
    #expect(sqlite.values == ["y", "5", "2.5", "x"])

    // No locator for the row: refused with its own reason
    let error = #expect(throws: DatabaseError.self) {
      try CellUpdateStatement.make(
        qualifiedName: #""public"."t""#, assignments: [(column: "name", value: "y")],
        primaryKeyColumns: [], rowData: rowData, rowLocator: .pgLocator, locator: nil)
    }
    #expect(error?.localizedDescription.contains("primary key") == false)
  }

  @Test("A column name with a quote is doubled")
  func quotedColumnDoublesEmbeddedQuote() throws {
    let editTarget = target()
    var set = RowChangeSet(target: editTarget)
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(1)]), column: "na\"me", value: .string("b"),
      original: .string("a"))

    let statements = try RowChangeSQLBuilder.statements(
      for: set,
      target: editTarget,
      columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "na\"me", type: "text")],
      dialect: .postgresql)
    #expect(statements[0].sql.contains(#""na""me""#))
  }

  @Test("ONLY is emitted for PostgreSQL when updateOnly is set, and never for SQLite")
  func updateOnlyIsPostgreSQLOnly() throws {
    let editTarget = target(updateOnly: true)
    var set = RowChangeSet(target: editTarget)
    set.stageDelete(row: RowChangeSet.RowKey(values: [.int(1)]))
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(2)]), column: "name", value: .string("b"),
      original: .string("a"))
    set.stageInsert(values: ["name": .string("c")])

    let postgres = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)
    #expect(postgres[0].sql == #"DELETE FROM ONLY "t" WHERE "id" = $1"#)
    #expect(postgres[1].sql == #"UPDATE ONLY "t" SET "name" = $1 WHERE "id" = $2"#)
    #expect(postgres[2].sql == #"INSERT INTO "t" ("name") VALUES ($1)"#)
    #expect(!postgres[2].sql.contains("ONLY"))

    let sqlite = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .sqlite)
    #expect(sqlite[0].sql == #"DELETE FROM "t" WHERE "id" = ?1"#)
    #expect(sqlite[1].sql == #"UPDATE "t" SET "name" = ?1 WHERE "id" = ?2"#)
    #expect(sqlite[2].sql == #"INSERT INTO "t" ("name") VALUES (?1)"#)
    #expect(sqlite.allSatisfy { !$0.sql.contains("ONLY") })
  }

  @Test(
    "A view target: the staged UPDATE names the view with its mapped key; DELETE and INSERT throw")
  @MainActor
  func viewTargetUpdatesOnly() throws {
    let map = ViewBaseMap(
      baseOID: 16_400, basePrimaryKey: [1], definitionVersion: "771",
      columns: ["key": 1, "name": 2],
      primaryKeyColumns: ["key"])
    let view = EditTarget(
      qualifiedName: "public.v1", tableID: .postgresql(oid: 16_500), primaryKeyColumns: ["key"],
      viewBase: map)
    let viewColumns = [
      ColumnInfo(name: "key", type: "int4"), ColumnInfo(name: "name", type: "text"),
    ]
    var edit = RowChangeSet(target: view)
    try edit.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(2)]), column: "name", value: .string("b"),
      original: .string("a"))
    #expect(
      try RowChangeSQLBuilder.statements(
        for: edit, target: view, columns: viewColumns, dialect: .postgresql
      ).map(\.sql) == [#"UPDATE public.v1 SET "name" = $1 WHERE "key" = $2"#])

    // The target a page re-read rebuilds for the staged set keeps the view
    let viewModel = NotebookViewModel()
    var state = DataViewerState(schema: "public", name: "v1", orderColumns: ["key"])
    state.changeSet = RowChangeSet(target: view)
    viewModel.dataViewer = state
    let reread = EditTarget(
      qualifiedName: view.qualifiedName, tableID: view.tableID, primaryKeyColumns: ["key"],
      viewBase: map)
    let regenerated = try #require(viewModel.keepingStagedGeneration(reread))
    #expect(regenerated.generation == view.generation)
    for target in [view, regenerated] {
      var delete = RowChangeSet(target: target)
      delete.stageDelete(row: RowChangeSet.RowKey(values: [.int(1)]))
      var insert = RowChangeSet(target: target)
      insert.stageInsert(values: ["key": .int(3), "name": .string("c")])
      for set in [delete, insert] {
        #expect(throws: RowChangeError.viewRowChange) {
          try RowChangeSQLBuilder.statements(
            for: set, target: target, columns: viewColumns, dialect: .postgresql)
        }
        #expect(throws: RowChangeError.viewRowChange) {
          try RowChangeSQLBuilder.previewText(
            for: set, target: target, columns: viewColumns, dialect: .postgresql)
        }
      }
    }
  }

  @Test("An insert can include a primary key supplied after the row was staged")
  func insertIncludesPrimaryKey() throws {
    let editTarget = target()
    var set = RowChangeSet(target: editTarget)
    let tempID = set.stageInsert(values: ["name": .string("chi")])
    set.updateInsert(tempID: tempID, column: "id", value: .int(3))

    let statements = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)
    #expect(statements.count == 1)
    #expect(statements[0].sql == #"INSERT INTO "t" ("id", "name") VALUES ($1, $2)"#)
    #expect(statements[0].values == ["3", "chi"])

    let preview = try RowChangeSQLBuilder.previewText(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)
    #expect(preview == #"INSERT INTO "t" ("id", "name") VALUES (3, 'chi');"#)
  }

  @Test("An insert with no values is DEFAULT VALUES and binds nothing")
  func emptyInsertIsDefaultValues() throws {
    let editTarget = target()
    var set = RowChangeSet(target: editTarget)
    set.stageInsert(values: [:])

    let statements = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)
    #expect(statements.count == 1)
    #expect(statements[0].sql == #"INSERT INTO "t" DEFAULT VALUES"#)
    #expect(statements[0].values.isEmpty)

    let preview = try RowChangeSQLBuilder.previewText(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)
    #expect(preview == #"INSERT INTO "t" DEFAULT VALUES;"#)
  }

  @Test("Preview inlines literals, so a string is not the bound placeholder SQL")
  func previewInlinesStringLiteral() throws {
    let editTarget = target()
    var set = RowChangeSet(target: editTarget)
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(1)]), column: "name", value: .string("o'brien"),
      original: .string("a"))

    let bound = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)
    let preview = try RowChangeSQLBuilder.previewText(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)

    #expect(bound[0].sql == #"UPDATE "t" SET "name" = $1 WHERE "id" = $2"#)
    #expect(bound[0].values == ["o'brien", "1"])
    #expect(bound[0].binds == [.text("o'brien"), .text("1")])
    #expect(!bound[0].sql.contains("o'brien"))
    #expect(preview == #"UPDATE "t" SET "name" = 'o''brien' WHERE "id" = 1;"#)
    #expect(preview != bound[0].sql)
  }

  @Test("A timestamp primary key binds its microseconds in the WHERE clause")
  func dateKeyKeepsMicroseconds() throws {
    let editTarget = target()
    let edited = Date(timeIntervalSince1970: 1_704_164_645.123_456)
    let deleted = Date(timeIntervalSince1970: 1_704_164_645.654_321)
    var set = RowChangeSet(target: editTarget)
    set.stageDelete(row: RowChangeSet.RowKey(values: [.date(deleted)]))
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.date(edited)]), column: "name", value: .string("b"),
      original: .string("a"))

    let bound = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)

    #expect(bound.count == 2)
    #expect(bound[0].values == ["2024-01-02T03:04:05.654321Z"])
    #expect(bound[1].values == ["b", "2024-01-02T03:04:05.123456Z"])
  }

  @Test("Generated columns are left out of staged UPDATE and INSERT")
  func generatedColumnsAreNotWritten() throws {
    let editTarget = EditTarget(
      qualifiedName: #""t""#, tableID: .postgresql(oid: 1), primaryKeyColumns: ["id"],
      generatedColumns: ["g"])
    let tableColumns = [
      ColumnInfo(name: "id", type: "int4"),
      ColumnInfo(name: "g", type: "int4"),
      ColumnInfo(name: "name", type: "text"),
    ]
    var set = RowChangeSet(target: editTarget)
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(1)]), column: "g", value: .int(9),
      original: .int(2))
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(2)]), column: "name", value: .string("b"),
      original: .string("a"))
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(2)]), column: "g", value: .int(9),
      original: .int(4))
    set.stageInsert(values: ["g": .int(6), "name": .string("c")])
    set.stageInsert(values: ["g": .int(8)])

    let sql = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: tableColumns, dialect: .postgresql
    ).map(\.sql)

    #expect(
      sql == [
        #"UPDATE "t" SET "name" = $1 WHERE "id" = $2"#,
        #"INSERT INTO "t" ("name") VALUES ($1)"#,
        #"INSERT INTO "t" DEFAULT VALUES"#,
      ])
  }

  @Test("A DEFAULT cell is the keyword on PostgreSQL, never a bind, and refused on SQLite")
  func serverDefaultIsTheKeyword() throws {
    let editTarget = target()
    var set = RowChangeSet(target: editTarget)
    try set.stageServerDefault(
      row: RowChangeSet.RowKey(values: [.int(1)]), column: "name", original: .string("a"))

    let statements = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)
    #expect(statements.map(\.sql) == [#"UPDATE "t" SET "name" = DEFAULT WHERE "id" = $1"#])
    #expect(statements.first?.values == ["1"])
    #expect(
      try RowChangeSQLBuilder.previewText(
        for: set, target: editTarget, columns: columns(), dialect: .postgresql)
        == #"UPDATE "t" SET "name" = DEFAULT WHERE "id" = 1;"#)

    #expect(throws: RowChangeError.serverDefaultUnsupported) {
      try RowChangeSQLBuilder.statements(
        for: set, target: editTarget, columns: columns(), dialect: .sqlite)
    }

    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(1)]), column: "name", value: .string("b"),
      original: .string("a"))
    let edited = try RowChangeSQLBuilder.statements(
      for: set, target: editTarget, columns: columns(), dialect: .postgresql)
    #expect(edited.map(\.sql) == [#"UPDATE "t" SET "name" = $1 WHERE "id" = $2"#])
    #expect(edited.first?.values == ["b", "1"])
  }

  @Test(
    "Bytes bind as bare hex through UNHEX on SQLite, DuckDB and MySQL, as \\x hex on PostgreSQL")
  func bytesBindPerDialect() throws {
    let editTarget = target()
    let bytes = CellValue.data(Data([0x00, 0x0A, 0xFF]))
    var set = RowChangeSet(target: editTarget)
    set.stageInsert(values: ["id": .int(1), "name": bytes])
    let cases: [(SQLDialect, String, String)] = [
      (.sqlite, #"INSERT INTO "t" ("id", "name") VALUES (?1, UNHEX(?2))"#, "000aff"),
      (.duckdb, #"INSERT INTO "t" ("id", "name") VALUES ($1, UNHEX($2))"#, "000aff"),
      (.mysql, #"INSERT INTO "t" (`id`, `name`) VALUES (?, UNHEX(?))"#, "000aff"),
      (.postgresql, #"INSERT INTO "t" ("id", "name") VALUES ($1, $2)"#, "\\x000aff"),
    ]
    for (dialect, sql, hex) in cases {
      let statements = try RowChangeSQLBuilder.statements(
        for: set, target: editTarget, columns: columns(), dialect: dialect)
      #expect(statements.map(\.sql) == [sql])
      #expect(statements.first?.values == ["1", hex])
    }
    // The preview shows the bytes the bind stores
    #expect(
      try RowChangeSQLBuilder.previewText(
        for: set, target: editTarget, columns: columns(), dialect: .sqlite)
        == #"INSERT INTO "t" ("id", "name") VALUES (1, X'000AFF');"#)
    // A large value: the preview stays short, the bind sends every byte
    let large = Data(repeating: 0xAB, count: 5_242_880)
    var big = RowChangeSet(target: editTarget)
    big.stageInsert(values: ["id": .int(2), "name": .data(large)])
    for dialect in [SQLDialect.sqlite, .postgresql, .duckdb, .mysql] {
      let preview = try RowChangeSQLBuilder.previewText(
        for: big, target: editTarget, columns: columns(), dialect: dialect)
      #expect(preview.count < 2_000)
      #expect(preview.contains(" ... /* 5242880 bytes */"))
      let bound = try RowChangeSQLBuilder.statements(
        for: big, target: editTarget, columns: columns(), dialect: dialect)
      let bind = try #require(bound.first?.values.last ?? nil)
      #expect(bind.utf8.count == (dialect == .postgresql ? 2 : 0) + 10_485_760)
    }
    #expect(
      try RowChangeSQLBuilder.previewText(
        for: big, target: editTarget, columns: columns(), dialect: .sqlite
      ).hasSuffix(#"ABABAB' ... /* 5242880 bytes */);"#))
    // The capped preview classifies as the same statement as a whole small value's
    var small = RowChangeSet(target: editTarget)
    small.stageInsert(values: ["id": .int(2), "name": .data(Data(count: 10))])
    for dialect in [SQLDialect.sqlite, .postgresql, .mysql, .duckdb] {
      let capped = try RowChangeSQLBuilder.previewText(
        for: big, target: editTarget, columns: columns(), dialect: dialect)
      let whole = try RowChangeSQLBuilder.previewText(
        for: small, target: editTarget, columns: columns(), dialect: dialect)
      #expect(
        SQLStatementClassifier.classify(capped, dialect: dialect).map(\.kind)
          == SQLStatementClassifier.classify(whole, dialect: dialect).map(\.kind))
    }
    #expect(
      SQLStatementClassifier.classify(
        try RowChangeSQLBuilder.previewText(
          for: big, target: editTarget, columns: columns(), dialect: .sqlite),
        dialect: .sqlite
      ).map(\.kind) == [.dml])
    // A byte key matches through UNHEX too
    #expect(
      try CellUpdateStatement.make(
        qualifiedName: #""main"."t""#, assignments: [(column: "name", value: "a")],
        primaryKeyColumns: ["id"], rowData: ["id": bytes], updateOnly: false, dialect: .sqlite
      ).sql == #"UPDATE "main"."t" SET "name" = ?1 WHERE "id" = UNHEX(?2)"#)
  }
}

private func target(
  primaryKeyColumns: [String] = ["id"], updateOnly: Bool = false
) -> EditTarget {
  EditTarget(
    qualifiedName: #""t""#, tableID: .postgresql(oid: 1), primaryKeyColumns: primaryKeyColumns,
    updateOnly: updateOnly)
}

private func columns() -> [ColumnInfo] {
  [
    ColumnInfo(name: "id", type: "int4"),
    ColumnInfo(name: "name", type: "text"),
  ]
}
