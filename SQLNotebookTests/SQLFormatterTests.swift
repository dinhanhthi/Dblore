// SQLFormatterTests.swift
// Tests for the SQL formatter behind the editor's Format button

import Foundation
import Testing

@testable import SQLNotebook

@Suite("SQL Formatter Tests")
struct SQLFormatterTests {

  @Test("Clauses go on their own line with indented contents")
  func formatsClauses() {
    let sql =
      "select id, name from users where status = 'active' and age > 18 order by id limit 10;"
    #expect(
      SQLFormatter.format(sql)
        == "SELECT\n  id,\n  name\nFROM\n  users\nWHERE\n  status = 'active'\n  AND age > 18\nORDER BY\n  id\nLIMIT\n  10;"
    )
  }

  @Test("Joins break inside FROM")
  func formatsJoins() {
    let sql = "select * from users u left join orders o on o.user_id = u.id join x on true"
    #expect(
      SQLFormatter.format(sql)
        == "SELECT\n  *\nFROM\n  users u\n  LEFT JOIN orders o ON o.user_id = u.id\n  JOIN x ON TRUE"
    )
  }

  @Test("Literals, quoted identifiers and comments are kept verbatim")
  func keepsLiteralsAndComments() {
    let sql = "select 'from x, y' as \"Order\", count(*) -- total\nfrom t /* keep */"
    #expect(
      SQLFormatter.format(sql)
        == "SELECT\n  'from x, y' AS \"Order\",\n  count(*) -- total\nFROM\n  t /* keep */"
    )
  }

  @Test("Subqueries are indented")
  func formatsSubqueries() {
    let sql = "select * from t where id in (select uid from o)"
    #expect(
      SQLFormatter.format(sql)
        == "SELECT\n  *\nFROM\n  t\nWHERE\n  id IN (\n    SELECT\n      uid\n    FROM\n      o\n  )"
    )
  }

  @Test("Statements are separated by a blank line")
  func separatesStatements() {
    #expect(SQLFormatter.format("select 1; select 2;") == "SELECT\n  1;\n\nSELECT\n  2;")
  }

  @Test("AND of BETWEEN stays inline")
  func keepsBetweenAnd() {
    let sql = "select * from t where a between 1 and 5 and b = 2"
    #expect(
      SQLFormatter.format(sql)
        == "SELECT\n  *\nFROM\n  t\nWHERE\n  a BETWEEN 1 AND 5\n  AND b = 2"
    )
  }

  @Test("Function calls, casts and operators keep their spacing")
  func keepsInlineSpacing() {
    let sql = "select coalesce(a,b)::text, x>=1, left(name, 3) from t"
    #expect(
      SQLFormatter.format(sql)
        == "SELECT\n  coalesce(a, b)::text,\n  x>=1,\n  LEFT(name, 3)\nFROM\n  t"
    )
  }

  @Test("Clause words inside parentheses stay inline")
  func keepsParenthesizedClausesInline() {
    let sql = "select row_number() over (partition by a order by b) from t"
    #expect(
      SQLFormatter.format(sql)
        == "SELECT\n  row_number() OVER (PARTITION BY a ORDER BY b)\nFROM\n  t"
    )
  }

  @Test("Formatting is idempotent")
  func isIdempotent() {
    let sql =
      "-- report\nwith c as (select a, b from t where x between 1 and 2) select * from c left join d on d.a = c.a; update t set a = 1, b = 'x' where id = 3;"
    let once = SQLFormatter.format(sql)
    #expect(SQLFormatter.format(once) == once)
  }

  @Test("A line comment ending in a combining mark still ends the line")
  func keepsLineCommentWithCombiningMark() {
    let output = SQLFormatter.format("select 1 --\u{301}\n+ 2")
    #expect(Array(output.unicodeScalars) == Array("SELECT\n  1 --\u{301}\n  + 2".unicodeScalars))
  }

  @Test("Words with non-ASCII look-alikes are not keywords")
  func ignoresNonASCIIKeywordLookalikes() {
    let output = SQLFormatter.format("select li\u{212A}e")
    #expect(Array(output.unicodeScalars) == Array("SELECT\n  li\u{212A}e".unicodeScalars))
  }

  @Test("Newline-separated string constants stay on separate lines")
  func keepsStringContinuation() {
    #expect(SQLFormatter.format("select 'foo'\n'bar'") == "SELECT\n  'foo'\n  'bar'")
  }

  @Test("Dollar quotes and escape strings are kept verbatim")
  func keepsDollarQuotesAndEscapeStrings() {
    let sql = "select $tag$ a,  from $tag$, e'x\\' y'"
    #expect(SQLFormatter.format(sql) == "SELECT\n  $tag$ a,  from $tag$,\n  e'x\\' y'")
  }

  @Test("Plain strings containing a backslash are returned unchanged")
  func keepsBackslashStrings() {
    let sql = "select 'a\\', b'"
    #expect(SQLFormatter.format(sql) == sql)
  }

  @Test("Blank input is returned unchanged")
  func keepsBlankInput() {
    #expect(SQLFormatter.format("  \n") == "  \n")
  }
}
