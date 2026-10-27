// TableFilterTests.swift
// A TableFilter becomes one WHERE clause: identifiers quoted, values inlined as escaped
// literals, incomplete rows skipped, rows joined left to right without parentheses.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Table Filter Tests")
struct TableFilterTests {
  private func condition(
    _ column: String, _ op: FilterOperator, _ value: String = "",
    _ connector: FilterConnector = .and
  ) -> FilterCondition {
    FilterCondition(column: column, op: op, value: value, connector: connector)
  }

  private func clause(
    _ conditions: [FilterCondition], _ dialect: DatabaseType = .postgresql
  )
    -> String?
  {
    TableFilter(conditions: conditions).whereClause(dialect: dialect.dialect)
  }

  @Test(
    "Every operator on PostgreSQL",
    arguments: [
      (FilterOperator.equals, #""c" = 'v'"#),
      (.notEquals, #""c" <> 'v'"#),
      (.like, #""c"::text LIKE 'v'"#),
      (.notLike, #""c"::text NOT LIKE 'v'"#),
      (.ilike, #""c"::text ILIKE 'v'"#),
      (.notIlike, #""c"::text NOT ILIKE 'v'"#),
      (.lessThan, #""c" < 'v'"#),
      (.lessThanOrEqual, #""c" <= 'v'"#),
      (.greaterThan, #""c" > 'v'"#),
      (.greaterThanOrEqual, #""c" >= 'v'"#),
      (.in, #""c" IN ('v')"#),
      (.isNull, #""c" IS NULL"#),
      (.isNotNull, #""c" IS NOT NULL"#),
    ])
  func postgresOperators(op: FilterOperator, expected: String) {
    #expect(clause([condition("c", op, "v")]) == expected)
  }

  @Test(
    "Every operator on SQLite (ilike lowers both sides, no cast)",
    arguments: [
      (FilterOperator.equals, #""c" = 'v'"#),
      (.notEquals, #""c" <> 'v'"#),
      (.like, #""c" LIKE 'v'"#),
      (.notLike, #""c" NOT LIKE 'v'"#),
      (.ilike, #"LOWER("c") LIKE LOWER('v')"#),
      (.notIlike, #""c" NOT LIKE 'v'"#),
      (.lessThan, #""c" < 'v'"#),
      (.lessThanOrEqual, #""c" <= 'v'"#),
      (.greaterThan, #""c" > 'v'"#),
      (.greaterThanOrEqual, #""c" >= 'v'"#),
      (.in, #""c" IN ('v')"#),
      (.isNull, #""c" IS NULL"#),
      (.isNotNull, #""c" IS NOT NULL"#),
    ])
  func sqliteOperators(op: FilterOperator, expected: String) {
    #expect(clause([condition("c", op, "v")], .sqlite) == expected)
  }

  /// The same form as Find a Value in Every Table, so opening a match finds the row whatever
  /// the column's collation (a `_bin` collation makes MySQL's `LIKE` case-sensitive).
  @Test("ilike on MySQL lowers both sides of LIKE")
  func mysqlCaseInsensitiveLike() {
    #expect(
      clause([condition("c", .ilike, "v")], .mysql) == "LOWER(CAST(`c` AS CHAR)) LIKE LOWER('v')")
  }

  @Test("Quotes in the value and the column are escaped")
  func quoteEscaping() {
    #expect(clause([condition("c", .equals, "o'brien")]) == #""c" = 'o''brien'"#)
    #expect(clause([condition(#"we"ird"#, .equals, "x")]) == #""we""ird" = 'x'"#)
  }

  @Test("in splits on commas, trims and drops empty items")
  func inSplitting() {
    #expect(clause([condition("c", .in, " a, b ,, c'd ")]) == #""c" IN ('a', 'b', 'c''d')"#)
    #expect(clause([condition("c", .in, " , ,")]) == nil)
  }

  @Test("Null checks ignore the value")
  func nullChecksIgnoreValue() {
    #expect(clause([condition("c", .isNull, "ignored")]) == #""c" IS NULL"#)
    #expect(!FilterOperator.isNull.needsValue)
    #expect(FilterOperator.equals.needsValue)
  }

  @Test("Incomplete rows are skipped")
  func incompleteRows() {
    let rows = [
      condition("", .equals, "x"), condition("a", .equals, ""), condition("b", .isNull),
    ]
    #expect(clause(rows) == #""b" IS NULL"#)
    #expect(clause(Array(rows.prefix(2))) == nil)
  }

  @Test("AND/OR join left to right and the first row's connector is ignored")
  func joining() {
    let rows = [
      condition("a", .equals, "1", .or),
      condition("b", .equals, "2", .and),
      condition("c", .equals, "3", .or),
    ]
    #expect(clause(rows) == #""a" = '1' AND "b" = '2' OR "c" = '3'"#)
  }

  @Test("The first complete row ignores its connector even after skipped rows")
  func firstCompleteRowConnector() {
    let rows = [condition("", .equals, "x"), condition("a", .equals, "1", .or)]
    #expect(clause(rows) == #""a" = '1'"#)
  }

  @Test("A qualifier prefixes every column with the quoted alias")
  func qualifiedColumns() {
    let rows = [condition("c", .equals, "v"), condition("d", .ilike, "w")]
    #expect(
      TableFilter(conditions: rows).whereClause(dialect: .postgresql, qualifier: #"o"x"#)
        == #""o""x"."c" = 'v' AND "o""x"."d"::text ILIKE 'w'"#)
    #expect(
      TableFilter(conditions: rows).whereClause(dialect: .mysql, qualifier: "o")
        == "`o`.`c` = 'v' AND LOWER(CAST(`o`.`d` AS CHAR)) LIKE LOWER('w')")
  }

  @Test("No qualifier keeps the unqualified clause", arguments: [DatabaseType.postgresql, .mysql])
  func nilQualifierUnchanged(dialect: DatabaseType) {
    let filter = TableFilter(conditions: [
      condition("c", .equals, "v"), condition("d", .ilike, "w", .or),
    ])
    let expected =
      dialect == .postgresql
      ? #""c" = 'v' OR "d"::text ILIKE 'w'"#
      : "`c` = 'v' OR LOWER(CAST(`d` AS CHAR)) LIKE LOWER('w')"
    #expect(filter.whereClause(dialect: dialect.dialect, qualifier: nil) == expected)
  }

  @Test("Empty filter has no clause")
  func emptyFilter() {
    #expect(TableFilter(conditions: []).isEmpty)
    #expect(clause([]) == nil)
  }
}
