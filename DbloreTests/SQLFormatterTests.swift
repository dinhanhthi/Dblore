// SQLFormatterTests.swift
// Tests for the SQL formatter behind the editor's Format button

import Foundation
import Testing

@testable import Dblore

@Suite("SQL Formatter Tests")
struct SQLFormatterTests {

  @Test("Clauses start a line, SELECT items align, joins put ON below")
  func formatsQuery() {
    let sql = """
      SELECT a.id, a.bot, a.method, a.candelete, a.canupdate,
               COUNT(d.id) AS ndocs,
               last_run.status AS last_status, last_run.info AS last_info
        FROM autoupdate a
        LEFT JOIN document d
               ON d.bot = a.bot AND d.sourcetype = 'auto_' || a.method || '_' || a.id
        LEFT JOIN LATERAL (
            SELECT status, info FROM useraction u
            WHERE u.autoupdate = a.id ORDER BY u.create_time DESC LIMIT 1
        ) last_run ON true
        WHERE a.type = 'documents'
          -- AND a.method = 'sharepoint'
        GROUP BY a.id, a.bot, a.method, a.candelete, a.canupdate, last_run.status, last_run.info
        HAVING COUNT(d.id) > 0
        ORDER BY ndocs ASC
        LIMIT 20;
      """
    let expected = """
      SELECT a.id,
             a.bot,
             a.method,
             a.candelete,
             a.canupdate,
             COUNT(d.id) AS ndocs,
             last_run.status AS last_status,
             last_run.info AS last_info
      FROM autoupdate a
      LEFT JOIN document d
        ON d.bot = a.bot AND d.sourcetype = 'auto_' || a.method || '_' || a.id
      LEFT JOIN LATERAL (
        SELECT status,
               info
        FROM useraction u
        WHERE u.autoupdate = a.id
        ORDER BY u.create_time DESC
        LIMIT 1
      ) last_run
        ON TRUE
      WHERE a.type = 'documents'
      -- AND a.method = 'sharepoint'
      GROUP BY a.id, a.bot, a.method, a.candelete, a.canupdate, last_run.status, last_run.info
      HAVING COUNT(d.id) > 0
      ORDER BY ndocs ASC
      LIMIT 20;
      """
    #expect(SQLFormatter.format(sql) == expected)
    #expect(SQLFormatter.format(expected) == expected)
  }

  @Test("Literals, quoted identifiers and trailing comments are kept verbatim")
  func keepsLiteralsAndComments() {
    let sql = "select 'from x, y' as \"Order\", -- first\ncount(*) -- total\nfrom t /* keep */"
    #expect(
      SQLFormatter.format(sql)
        == "SELECT 'from x, y' AS \"Order\", -- first\n       count(*) -- total\nFROM t /* keep */"
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
    #expect(Array(output.unicodeScalars) == Array("SELECT 1 --\u{301}\n+ 2".unicodeScalars))
  }

  @Test("Words with non-ASCII look-alikes are not keywords")
  func ignoresNonASCIIKeywordLookalikes() {
    let output = SQLFormatter.format("select li\u{212A}e")
    #expect(Array(output.unicodeScalars) == Array("SELECT li\u{212A}e".unicodeScalars))
  }

  @Test("Newline-separated string constants stay on separate lines")
  func keepsStringContinuation() {
    #expect(SQLFormatter.format("select 'foo'\n'bar'") == "SELECT 'foo'\n'bar'")
  }

  @Test("Dollar quotes and escape strings are kept verbatim")
  func keepsDollarQuotesAndEscapeStrings() {
    let sql = "select $tag$ a,  from $tag$, e'x\\' y'"
    #expect(SQLFormatter.format(sql) == "SELECT $tag$ a,  from $tag$,\n       e'x\\' y'")
  }

  @Test("Plain strings containing a backslash are returned unchanged")
  func keepsBackslashStrings() {
    let sql = "select 'a\\', b'"
    #expect(SQLFormatter.format(sql) == sql)
  }
}
