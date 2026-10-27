// ImportMatchPlannerTests.swift
// The bound match reads of an import into an existing table, per dialect, and how each file row
// is classified from the counts in every import mode.

import Foundation
import Testing

@testable import Dblore

@Suite("Import match planner")
struct ImportMatchPlannerTests {
  @Test("Rows are classified per mode from their match count, more than one is refused")
  func classificationPerMode() {
    let exists = "A row with this key already exists in the table."
    let expected: [(ImportMode, [ImportMatchPlanner.Outcome])] = [
      (.insert, [.insert, .refused(exists)]),
      (.update, [.skip, .update]),
      (.insertOrUpdate, [.insert, .update]),
      (.insertSkippingExisting, [.insert, .skip]),
    ]
    for (mode, outcomes) in expected {
      #expect(ImportMatchPlanner.outcome(matches: 0, mode: mode) == outcomes[0])
      #expect(ImportMatchPlanner.outcome(matches: 1, mode: mode) == outcomes[1])
      #expect(
        ImportMatchPlanner.outcome(matches: 2, mode: mode)
          == .refused("2 rows in the table match this key."))
    }
  }

  @Test("A NULL key is never read and never matches; a key must be mapped")
  func nullKeyNeverMatches() throws {
    let plan = try ImportMatchPlanner.plan(
      schema: nil, table: "t", keyColumns: ["id"], columns: ["id", "name"],
      rows: [["1", "a"], [nil, "b"], ["  ", "c"], ["4", "d"]],
      structure: structure([column("id", "INTEGER"), column("name", "TEXT")]),
      dialect: .sqlite)

    #expect(plan.reads.map(\.values) == [["1", "4"]])
    // A count reported for a NULL-key row is ignored; a row the read did not return is 0
    let counts = [0: 1, 1: 1, 2: 1]
    #expect(
      ImportMatchPlanner.outcomes(plan, counts: counts, mode: .update)
        == [.update, .skip, .skip, .skip])
    #expect(
      ImportMatchPlanner.outcomes(plan, counts: counts, mode: .insertOrUpdate)
        == [.update, .insert, .insert, .insert])

    #expect(throws: ImportMatchPlanner.Error.keyNotMapped("id")) {
      try ImportMatchPlanner.plan(
        schema: nil, table: "t", keyColumns: ["id"], columns: ["name"], rows: [["a"]],
        structure: structure([column("id", "INTEGER"), column("name", "TEXT")]),
        dialect: .sqlite)
    }
  }

  @Test("PostgreSQL casts every key bind to its column's type and quotes names")
  func postgresCastsKeyBinds() throws {
    let plan = try ImportMatchPlanner.plan(
      schema: "sales", table: "or\"ders", keyColumns: ["id", "co\"de", "label", "amount"],
      columns: ["amount", "id", "co\"de", "label"],
      rows: [["1.50", "1", "AB", "x"], ["2", "2", "CD", "y"]],
      structure: structure([
        column("id", "integer"), column("co\"de", "character(3)"),
        column("label", "character varying(20)"), column("amount", "numeric(10,2)"),
      ]),
      dialect: .postgresql)

    let read = try #require(plan.reads.first)
    #expect(plan.reads.count == 1)
    #expect(
      read.sql
        == #"SELECT v.pos, COUNT(*) FROM (VALUES "#
        + #"(0, CAST($1 AS integer), CAST($2 AS bpchar), CAST($3 AS character varying), "#
        + #"CAST($4 AS numeric)), "#
        + #"(1, CAST($5 AS integer), CAST($6 AS bpchar), CAST($7 AS character varying), "#
        + #"CAST($8 AS numeric))) AS v(pos, k0, k1, k2, k3) "#
        + #"JOIN "sales"."or""ders" AS t ON t."id" = v.k0 AND t."co""de" = v.k1 "#
        + #"AND t."label" = v.k2 AND t."amount" = v.k3 GROUP BY v.pos"#)
    #expect(read.values == ["1", "AB", "x", "1.50", "2", "CD", "y", "2"])
    #expect(read.expectedRows == nil)
    #expect(read.classified?.kind == .read)
  }

  @Test("SQLite and DuckDB read through VALUES with their own placeholders")
  func sqliteAndDuckDBShapes() throws {
    let rows: [[String?]] = [["a"], ["b"]]
    let sqlite = try ImportMatchPlanner.plan(
      schema: nil, table: "t", keyColumns: ["k"], columns: ["k"], rows: rows,
      structure: structure([column("k", "TEXT")]), dialect: .sqlite)
    #expect(
      sqlite.reads.map(\.sql)
        == [
          #"SELECT v.column1, COUNT(*) FROM (VALUES (0, ?1), (1, ?2)) AS v "#
            + #"JOIN "t" AS t ON t."k" = v.column2 GROUP BY v.column1"#
        ])

    let duckdb = try ImportMatchPlanner.plan(
      schema: "main", table: "t", keyColumns: ["k"], columns: ["k"], rows: rows,
      structure: structure([column("k", "DECIMAL(18,3)")]), dialect: .duckdb)
    #expect(
      duckdb.reads.map(\.sql)
        == [
          #"SELECT v.pos, COUNT(*) FROM (VALUES (0, CAST($1 AS DECIMAL(18,3))), "#
            + #"(1, CAST($2 AS DECIMAL(18,3)))) AS v(pos, k0) "#
            + #"JOIN "t" AS t ON t."k" = v.k0 GROUP BY v.pos"#
        ])
    #expect(duckdb.reads.map(\.values) == [["a", "b"]])
  }

  @Test("MySQL compares string keys in the column's collation and numeric keys as numbers")
  func mysqlKeyComparisons() throws {
    let plan = try ImportMatchPlanner.plan(
      schema: "shop", table: "items", keyColumns: ["name", "code", "id", "u", "price"],
      columns: ["name", "code", "id", "u", "price"],
      rows: [["Café", "é", " 9007199254740993 ", "7", "10.5"]],
      structure: structure(mysqlColumns), dialect: .mysql)

    let read = try #require(plan.reads.first)
    #expect(
      read.sql
        == "SELECT v.pos, COUNT(*) FROM (SELECT 0 AS pos, ? AS k0, ? AS k1, ? AS k2, ? AS k3, "
        + "? AS k4) AS v JOIN `shop`.`items` AS t ON "
        + "t.`name` = v.k0 COLLATE utf8mb4_unicode_ci "
        + "AND t.`code` = CONVERT(v.k1 USING latin1) COLLATE latin1_swedish_ci "
        + "AND t.`id` = CAST(v.k2 AS SIGNED) AND t.`u` = CAST(v.k3 AS UNSIGNED) "
        + "AND t.`price` = CAST(v.k4 AS DECIMAL(10,2)) GROUP BY v.pos")
    // 2^53 + 1 is sent as text, never through a Double
    #expect(read.values == ["Café", "é", "9007199254740993", "7", "10.5"])
    #expect(read.classified?.kind == .read)

    let union = try ImportMatchPlanner.plan(
      schema: nil, table: "items", keyColumns: ["id"], columns: ["id"],
      rows: [["1"], ["2"]], structure: structure(mysqlColumns), dialect: .mysql)
    #expect(
      union.reads.map(\.sql)
        == [
          "SELECT v.pos, COUNT(*) FROM (SELECT 0 AS pos, ? AS k0 UNION ALL SELECT 1, ?) AS v "
            + "JOIN `items` AS t ON t.`id` = CAST(v.k0 AS SIGNED) GROUP BY v.pos"
        ])
  }

  @Test("MySQL refuses unusable names for the key and unmatchable values for the row")
  func mysqlRefusals() throws {
    func plan(_ key: String, _ values: [String?]) throws -> ImportMatchPlanner.Plan {
      try ImportMatchPlanner.plan(
        schema: nil, table: "items", keyColumns: [key], columns: [key],
        rows: values.map { [$0] }, structure: structure(mysqlColumns), dialect: .mysql)
    }
    let latin1 = try plan("code", ["café", "東京"])
    #expect(latin1.reads.map(\.values) == [["café"]])
    #expect(
      ImportMatchPlanner.outcomes(latin1, counts: [:], mode: .insertOrUpdate)
        == [.insert, .refused("The code value can't be stored in character set latin1.")])

    let numbers = try plan("id", ["abc", "1.5", "-12"])
    #expect(numbers.reads.map(\.values) == [["-12"]])
    #expect(numbers.refusals[0] == "The id value is not a whole number in range.")
    #expect(numbers.refusals[1] == "The id value is not a whole number in range.")
    #expect(
      try plan("u", ["-1", "18446744073709551615"]).reads.map(\.values) == [
        ["18446744073709551615"]
      ])
    #expect(
      try plan("price", ["1.005", "123456789", "-12345678.90"]).reads.map(\.values)
        == [["-12345678.90"]])

    for (characterSet, collation) in [
      ("utf8mb4", "utf8mb4_bin; DROP TABLE x"), ("utf8mb4", nil), ("sjis", "sjis_japanese_ci"),
    ] {
      var columns = mysqlColumns
      columns[0].characterSet = characterSet
      columns[0].collation = collation
      #expect(throws: ImportMatchPlanner.Error.self) {
        try ImportMatchPlanner.plan(
          schema: nil, table: "items", keyColumns: ["name"], columns: ["name"], rows: [["a"]],
          structure: structure(columns), dialect: .mysql)
      }
    }
  }

  @Test("Reads are chunked at the bind limit")
  func chunksAtBindLimit() throws {
    let plan = try ImportMatchPlanner.plan(
      schema: nil, table: "t", keyColumns: ["a", "b"], columns: ["a", "b"],
      rows: (0..<5).map { ["a\($0)", "b\($0)"] },
      structure: structure([column("a", "text"), column("b", "text")]), dialect: .postgresql,
      bindLimit: 4)

    #expect(plan.reads.map(\.values.count) == [4, 4, 2])
    #expect(plan.reads[2].values == ["a4", "b4"])
    #expect(plan.reads[2].sql.contains("(VALUES (4, CAST($1 AS text), CAST($2 AS text)))"))
  }

  // MARK: - Fixtures

  private var mysqlColumns: [TableStructure.Column] {
    [
      column(
        "name", "varchar", columnType: "varchar(40)", characterSet: "utf8mb4",
        collation: "utf8mb4_unicode_ci"),
      column(
        "code", "varchar", columnType: "varchar(8)", characterSet: "latin1",
        collation: "latin1_swedish_ci"),
      column("id", "bigint", columnType: "bigint"),
      column("u", "int", columnType: "int unsigned"),
      column("price", "decimal", columnType: "decimal(10,2)"),
    ]
  }

  private func column(
    _ name: String, _ dataType: String, columnType: String? = nil, characterSet: String? = nil,
    collation: String? = nil
  ) -> TableStructure.Column {
    TableStructure.Column(
      ordinal: 1, name: name, dataType: dataType, isNullable: true, columnType: columnType,
      characterSet: characterSet, collation: collation)
  }

  private func structure(_ columns: [TableStructure.Column]) -> TableStructure {
    TableStructure(
      tableID: .postgresql(oid: 1), schema: "s", name: "t", columns: columns, indexes: [],
      constraints: [])
  }
}
